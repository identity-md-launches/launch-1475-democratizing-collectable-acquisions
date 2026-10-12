// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DCAHook} from "../src/DCAHook.sol";

contract SwapFeeTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deploy(true, true, true);
    }

    function test_buyExactInput() public {
        _checkTrade(true, true, 100 ether);
    }

    function test_buyExactOutput() public {
        _checkTrade(true, false, 100 ether);
    }

    function test_sellExactInput() public {
        _checkTrade(false, true, 100 ether);
    }

    function test_sellExactOutput() public {
        _checkTrade(false, false, 100 ether);
    }

    function _checkTrade(bool buy, bool exactInput, uint256 amount) internal {
        uint256 pairBefore = pair.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 creatorBefore = CREATOR.balance + manager.balanceOf(address(hook), 0);
        uint256 claimsBefore = manager.balanceOf(address(hook), uint160(FWA));
        Outcome memory o = _trade(buy, exactInput, amount);
        _assertAccounting(o, claimsBefore, creatorBefore);
        assertEq(int256(pair.balanceOf(address(this))), int256(pairBefore) + _pairDelta(o.userDelta));
        assertEq(int256(token.balanceOf(address(this))), int256(tokenBefore) + _tokenDelta(o.userDelta));
        int128 input = buy ? _pairDelta(o.userDelta) : _tokenDelta(o.userDelta);
        int128 output = buy ? _tokenDelta(o.userDelta) : _pairDelta(o.userDelta);
        assertLt(input, 0);
        assertGt(output, 0);
        if (exactInput) assertEq(-int256(input), int256(amount));
        else assertEq(int256(output), int256(amount));
        assertGt(o.ethOut, 0);
        assertEq(o.pending, 0, "deep market sells the full fee");
    }

    function testFuzz_feeAndConservation(bool buy, bool exactInput, uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1e12, 10_000 ether);
        _checkTrade(buy, exactInput, amount);
    }

    function test_bothDirectionsAndExactnessWithFwaAsCurrency0() public {
        _deploy(true, true, false);
        _checkTrade(true, true, 100 ether);
        _checkTrade(true, false, 100 ether);
        _checkTrade(false, true, 100 ether);
        _checkTrade(false, false, 100 ether);
    }

    function test_conversionHitsRelativeBoundAndNextSwapSellsRemainder() public {
        _configure(1, Q96 * 2);
        uint256 beforeEth = CREATOR.balance;
        Outcome memory first = _trade(true, true, 1000 ether);
        _assertAccounting(first, 0, beforeEth);
        assertGt(first.spent, 0);
        assertGt(first.pending, 0);
        assertLt(first.spent, first.fee);
        (uint160 atLimit,,,) = manager.getSlot0(market.toId());
        assertLe(uint256(atLimit) * 1e9 / Q96, 1_000_049_998);
        _configure(1000, Q96 * 2);
        beforeEth = CREATOR.balance;
        Outcome memory second = _trade(false, true, 100 ether);
        _assertAccounting(second, first.pending, beforeEth);
        assertEq(second.pending, 0);
        assertEq(second.spent, first.pending + second.fee);
    }

    function test_absoluteCeilingDefersFeeThenOwnerCanRestoreConversion() public {
        _configure(1000, Q96);
        uint256 beforeEth = CREATOR.balance;
        Outcome memory first = _trade(false, true, 100 ether);
        _assertAccounting(first, 0, beforeEth);
        assertEq(first.ethOut, 0);
        assertEq(first.pending, first.fee);
        _configure(1000, Q96 * 2);
        Outcome memory second = _trade(true, false, 50 ether);
        _assertAccounting(second, first.pending, beforeEth);
        assertEq(second.pending, 0);
    }

    function test_conversionStopsAtAbsoluteBoundWithinRelativeBound() public {
        uint160 ceiling = Q96 + Q96 / 100_000;
        _configure(1000, ceiling);
        Outcome memory o = _trade(true, true, 1000 ether);
        assertGt(o.pending, 0);
        (uint160 price,,,) = manager.getSlot0(market.toId());
        assertEq(price, ceiling);
    }

    function test_noConversionLiquidityRetainsFeeClaims() public {
        _deploy(false, true, true);
        uint256 beforeEth = CREATOR.balance;
        Outcome memory o = _trade(true, true, 100 ether);
        _assertAccounting(o, 0, beforeEth);
        assertEq(o.ethOut, 0);
        assertEq(o.spent, 0);
        assertEq(o.pending, 5 ether);
    }

    function test_freshManagerSeededWithTokensOnlyUsesEthClaims() public {
        _deploy(false, true, true);
        assertEq(address(manager).balance, 0);
        vm.recordLogs();
        BalanceDelta delta = router.seedAndSwap{value: MARKET_LIQUIDITY}(
            key,
            _params(true, true, 100 ether),
            market,
            _liquidity(MARKET_LIQUIDITY),
            MARKET_LIQUIDITY + 100 ether,
            MARKET_LIQUIDITY + 100 ether
        );
        Outcome memory o = _outcome(vm.getRecordedLogs(), delta);
        assertEq(router.nativeBalanceAtSwap(), 0, "no native ETH during callback");
        assertEq(CREATOR.balance, 0);
        assertGt(o.ethOut, 0);
        assertEq(manager.balanceOf(address(hook), 0), o.ethOut);
        _assertAccounting(o, 0, 0);
        hook.redeemEth();
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(CREATOR.balance, o.ethOut);
        _assertSettled();
    }

    function test_nativeClaimsOnAllSwapModesWhenNativeIsTemporarilyUnavailable() public {
        for (uint256 mode; mode < 4; ++mode) {
            uint256 claimsBefore = manager.balanceOf(address(hook), 0);
            vm.recordLogs();
            BalanceDelta delta =
                router.drainAndSwap(key, _params(mode < 2, mode % 2 == 0, 100 ether), 400 ether, 0);
            Outcome memory o = _outcome(vm.getRecordedLogs(), delta);
            assertGt(o.ethOut, 0);
            assertEq(manager.balanceOf(address(hook), 0), claimsBefore + o.ethOut);
            assertEq(router.nativeBalanceAtSwap(), 0);
            _assertSettled();
        }
        uint256 total = manager.balanceOf(address(hook), 0);
        vm.prank(makeAddr("permissionless redeemer"));
        hook.redeemEth();
        assertEq(CREATOR.balance, total);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_partialNativeBalancePaysAvailableAndClaimsRest() public {
        vm.recordLogs();
        BalanceDelta delta = router.drainAndSwap(key, _params(true, true, 100 ether), 100 ether, 1 ether);
        Outcome memory o = _outcome(vm.getRecordedLogs(), delta);
        assertGt(o.ethOut, 1 ether);
        assertEq(CREATOR.balance, 1 ether);
        assertEq(manager.balanceOf(address(hook), 0), o.ethOut - 1 ether);
        _assertAccounting(o, 0, 0);
        hook.redeemEth();
        assertEq(CREATOR.balance, o.ethOut);
    }

    function test_laterSwapAutomaticallyPaysEarlierEthClaims() public {
        router.drainAndSwap(key, _params(true, true, 100 ether), 100 ether, 0);
        uint256 claims = manager.balanceOf(address(hook), 0);
        assertGt(claims, 0);
        Outcome memory o = _trade(false, true, 100 ether);
        assertEq(CREATOR.balance, claims + o.ethOut);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_swapWithoutConfiguredMarketRevertsAtomically() public {
        _deploy(true, false, true);
        uint256 beforePair = pair.balanceOf(address(this));
        vm.expectRevert();
        router.swap(key, _params(true, true, 100 ether), 100 ether, 0);
        assertEq(pair.balanceOf(address(this)), beforePair);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 0);
        _configure(1000, Q96 * 2);
        _checkTrade(true, true, 100 ether);
    }

    function test_partialPairSpecifiedSwapsRevertWithoutFee() public {
        for (uint256 mode; mode < 2; ++mode) {
            SwapParams memory p = _params(mode == 0, mode == 0, 1000 ether);
            p.sqrtPriceLimitX96 = p.zeroForOne ? Q96 - 1 : Q96 + 1;
            uint256 beforePair = pair.balanceOf(address(this));
            uint256 beforeToken = token.balanceOf(address(this));
            vm.expectRevert();
            router.swap(key, p, 10_000 ether, 0);
            assertEq(pair.balanceOf(address(this)), beforePair);
            assertEq(token.balanceOf(address(this)), beforeToken);
            assertEq(CREATOR.balance, 0);
            _assertSettled();
        }
    }

    function test_partialDcaSpecifiedTradeChargesOnlyActualFwa() public {
        SwapParams memory p = _params(false, true, 1000 ether);
        p.sqrtPriceLimitX96 = p.zeroForOne ? Q96 - Q96 / 100_000 : Q96 + Q96 / 100_000;
        vm.recordLogs();
        BalanceDelta delta = router.swap(key, p, 1000 ether, 0);
        Outcome memory o = _outcome(vm.getRecordedLogs(), delta);
        assertLt(-int256(_tokenDelta(delta)), 1000 ether);
        _assertAccounting(o, 0, 0);
    }

    function test_userSlippageFailureRollsBackFeeAndPoolState() public {
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        uint256 beforePair = pair.balanceOf(address(this));
        vm.expectRevert("slippage");
        router.swap(key, _params(true, true, 100 ether), 100 ether, 1_000_000 ether);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, beforePrice);
        assertEq(pair.balanceOf(address(this)), beforePair);
        assertEq(CREATOR.balance, 0);
        _assertSettled();
    }

    function test_liquidityCanBeRemovedBeforeConversionIsConfiguredAndPaysNoHookFee() public {
        _deploy(false, false, true);
        ModifyLiquidityParams memory removal = _liquidity(MAIN_LIQUIDITY);
        removal.liquidityDelta = -removal.liquidityDelta;
        BalanceDelta returned = router.modifyLiquidity(key, removal, 0, 0);
        assertGt(returned.amount0(), 0);
        assertGt(returned.amount1(), 0);
        assertEq(CREATOR.balance, 0);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function test_tinySwapRoundsFeeDown() public {
        Outcome memory o = _trade(true, true, 19);
        assertEq(o.fee, 0);
        assertEq(o.ethOut, 0);
        _assertAccounting(o, 0, 0);
    }
}
