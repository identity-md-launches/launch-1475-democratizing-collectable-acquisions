// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {DCAHook} from "src/DCAHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

contract LifecycleRejectEth {
    receive() external payable {
        revert("recipient unavailable");
    }
}

/// @dev Targets real PoolManager operations. The hook and manager are never storage-mocked.
/// Pair fees are measured from trader balances and raw launch-pool deltas; conversion amounts
/// come from the unhooked conversion pools' own Swap events, not DCAHook's accounting events.
contract ClaimLifecycleHandler is HookFixture {
    using StateLibrary for IPoolManager;

    address[3] public traders;
    PoolKey[2] private markets;
    uint256[2] public marketLiquidity;
    uint256 public activeMarket;
    uint256 public feesCharged;
    uint256 public pairDonated;
    uint256 public pairConverted;
    uint256 public ethEarned;
    uint256 public ethDonated;
    uint256 public successfulTrades;
    bytes private rejectCode;

    constructor() {
        _deploy(true, true, false);
        rejectCode = address(new LifecycleRejectEth()).code;
        markets[0] = market;
        marketLiquidity[0] = MARKET_LIQUIDITY;
        PoolKey memory alternative = market;
        alternative.fee = 500;
        manager.initialize(alternative, Q96);
        router.modifyLiquidity{value: MARKET_LIQUIDITY}(
            alternative, _liquidity(MARKET_LIQUIDITY), MARKET_LIQUIDITY, MARKET_LIQUIDITY
        );
        markets[1] = alternative;
        marketLiquidity[1] = MARKET_LIQUIDITY;
        for (uint256 i; i < traders.length; ++i) {
            address trader = makeAddr(string.concat("claim lifecycle trader ", vm.toString(i)));
            traders[i] = trader;
            token.transfer(trader, 1_000_000 ether);
            pair.transfer(trader, 1_000_000 ether);
            vm.deal(trader, 1000 ether);
            vm.startPrank(trader);
            token.approve(address(router), type(uint256).max);
            pair.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function trade(uint8 actorSeed, bool buy, bool exactInput, uint96 raw, bool nativeUnavailable) external {
        _tradeAs(
            traders[actorSeed % 3], buy, exactInput, bound(uint256(raw), 1, 100 ether), nativeUnavailable
        );
    }

    function _tradeAs(address trader, bool buy, bool exactInput, uint256 amount, bool nativeUnavailable)
        private
    {
        uint256 pairBefore = pair.balanceOf(trader);
        uint256 tokenBefore = token.balanceOf(trader);
        vm.recordLogs();
        vm.prank(trader);
        BalanceDelta delta;
        if (nativeUnavailable) {
            delta = router.drainAndSwap(key, _params(buy, exactInput, amount), amount * 4 + 100, 0);
        } else {
            delta = router.swap(key, _params(buy, exactInput, amount), amount * 4 + 100, 0);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _accountTrade(trader, buy, pairBefore, tokenBefore, delta, logs);
        _recordConversions(logs);
        ++successfulTrades;
    }

    function _accountTrade(
        address trader,
        bool buy,
        uint256 pairBefore,
        uint256 tokenBefore,
        BalanceDelta delta,
        Vm.Log[] memory logs
    ) private {
        Outcome memory o = _outcome(logs, delta);
        int256 paidPair = int256(pairBefore) - int256(pair.balanceOf(trader));
        int256 fee = int256(o.rawPair) + paidPair;
        assertGe(fee, 0);
        uint256 gross = buy ? uint256(paidPair) : uint256(int256(o.rawPair));
        assertLe(uint256(fee) * 20, gross);
        assertLt(gross, (uint256(fee) + 1) * 20);
        assertEq(int256(token.balanceOf(trader)) - int256(tokenBefore), int256(o.rawToken));
        assertEq(int256(_pairDelta(delta)), -paidPair);
        feesCharged += uint256(fee);
    }

    function _recordConversions(Vm.Log[] memory logs) private {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_TOPIC
                    || logs[i].topics[1] != PoolId.unwrap(market.toId())
            ) continue;
            (int128 ethDelta, int128 pairDelta,,,,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertGe(ethDelta, 0);
            assertLe(pairDelta, 0);
            pairConverted += uint256(-int256(pairDelta));
            ethEarned += uint256(int256(ethDelta));
        }
    }

    function configure(uint8 marketSeed, uint16 rawBps, bool defer) external {
        activeMarket = marketSeed % 2;
        market = markets[activeMarket];
        (uint160 price,,,) = manager.getSlot0(market.toId());
        _configure(uint16(bound(rawBps, 1, 1000)), defer ? price : price + price / 5);
    }

    function resizeConversionLiquidity(uint8 mode) external {
        uint256 target = mode % 3 == 0 ? 0 : (mode % 3 == 1 ? MARKET_LIQUIDITY / 2 : MARKET_LIQUIDITY);
        _resizeMarket(target);
    }

    function _resizeMarket(uint256 target) private {
        uint256 current = marketLiquidity[activeMarket];
        ModifyLiquidityParams memory params = _liquidity(0);
        params.liquidityDelta = int256(target) - int256(current);
        // Poking an empty position is invalid in v4; test the exact refusal on repeated removal.
        if (current == 0 && target == 0) {
            vm.expectRevert(Position.CannotUpdateEmptyPosition.selector);
            router.modifyLiquidity(market, params, 0, 0);
            return;
        }
        uint256 budget0;
        uint256 budget1;
        if (target > current) {
            (uint160 price,,,) = manager.getSlot0(market.toId());
            uint160 lower = TickMath.getSqrtPriceAtTick(params.tickLower);
            uint160 upper = TickMath.getSqrtPriceAtTick(params.tickUpper);
            uint160 clamped = price < lower ? lower : (price > upper ? upper : price);
            uint128 added = uint128(target - current);
            budget0 = SqrtPriceMath.getAmount0Delta(clamped, upper, added, true);
            budget1 = SqrtPriceMath.getAmount1Delta(lower, clamped, added, true);
        }
        router.modifyLiquidity{value: budget0}(market, params, budget0, budget1);
        marketLiquidity[activeMarket] = target;
    }

    function donateClaims(uint8 actorSeed, bool native, uint96 raw) external {
        uint256 amount = bound(uint256(raw), 1, 2 ether);
        vm.prank(traders[actorSeed % 3]);
        if (native) {
            router.mintClaims{value: amount}(Currency.wrap(address(0)), amount, address(hook));
            ethDonated += amount;
        } else {
            router.mintClaims(Currency.wrap(FWA), amount, address(hook));
            pairDonated += amount;
        }
    }

    function recipientAcceptsEth(bool accepts) external {
        vm.etch(CREATOR, accepts ? bytes("") : rejectCode);
    }

    function redeem(uint8 actorSeed) external {
        address caller = traders[actorSeed % 3];
        uint256 callerBefore = caller.balance;
        uint256 entitlement = CREATOR.balance + manager.balanceOf(address(hook), 0);
        vm.prank(caller);
        hook.redeemEth();
        assertEq(CREATOR.balance + manager.balanceOf(address(hook), 0), entitlement);
        assertEq(caller.balance, callerBefore, "permissionless caller cannot take creator fees");
        uint256 paid = CREATOR.balance;
        uint256 pending = manager.balanceOf(address(hook), 0);
        vm.prank(caller);
        hook.redeemEth();
        assertEq(CREATOR.balance, paid, "redemption replay paid twice");
        assertEq(manager.balanceOf(address(hook), 0), pending);
    }

    function rejectUnauthorizedConfiguration(uint8 actorSeed) external {
        uint16 bps = hook.maxPriceMoveBps();
        uint160 ceiling = hook.maxConversionSqrtPriceX96();
        vm.prank(traders[actorSeed % 3]);
        vm.expectRevert(DCAHook.OnlyOwner.selector);
        hook.setConversionPool(market, 1, Q96);
        assertEq(hook.maxPriceMoveBps(), bps);
        assertEq(hook.maxConversionSqrtPriceX96(), ceiling);
    }

    function assertClaimsConserved() external view {
        assertEq(feesCharged + pairDonated, pairConverted + manager.balanceOf(address(hook), uint160(FWA)));
        assertEq(ethEarned + ethDonated, CREATOR.balance + manager.balanceOf(address(hook), 0));
        assertGe(pair.balanceOf(address(manager)), manager.balanceOf(address(hook), uint160(FWA)));
        assertGe(address(manager).balance, manager.balanceOf(address(hook), 0));
    }

    function assertSupplyAndSettlement() external view {
        uint256 tokenSum = token.balanceOf(address(this)) + token.balanceOf(address(manager));
        uint256 pairSum = pair.balanceOf(address(this)) + pair.balanceOf(address(manager));
        for (uint256 i; i < traders.length; ++i) {
            tokenSum += token.balanceOf(traders[i]);
            pairSum += pair.balanceOf(traders[i]);
        }
        assertEq(tokenSum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), tokenSum);
        assertEq(pairSum, pair.totalSupply());
        assertEq(pair.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(pair.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(hook.RECIPIENT(), CREATOR);
        assertEq(hook.FEE_BPS(), 500);
        assertEq(hook.owner(), CREATOR);
        assertEq(PoolId.unwrap(hook.launchPoolId()), PoolId.unwrap(key.toId()));
        assertTrue(hook.initialized());
        _assertSettled();
    }

    /// @dev End-of-campaign liveness: after restoring recipient, liquidity and limits, the next
    /// trade must flush every claim accumulated within this handler's bounded 64-call campaign.
    function finishAndCheckRecovery() external {
        vm.etch(CREATOR, "");
        _resizeMarket(MARKET_LIQUIDITY);
        (uint160 price,,,) = manager.getSlot0(market.toId());
        _configure(1000, price * 2);
        _tradeAs(traders[0], true, true, 100 ether, false);
        hook.redeemEth();
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 0, "pair claims cannot be recovered");
        assertEq(manager.balanceOf(address(hook), 0), 0, "ETH claims cannot be recovered");
    }
}
