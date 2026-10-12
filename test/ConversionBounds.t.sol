// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolTestRouter} from "./helpers/PoolTestRouter.sol";
import {RevertingConversionHook, GasBurningConversionHook} from "./mocks/ConversionHooks.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {DCAHook} from "../src/DCAHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice The conversion's price bound is anchored to an earlier block, fee-free swaps sell
/// nothing, the backlog sold per swap is capped, and an unusable market never blocks trading.
contract ConversionBoundsTest is HookFixture {
    using StateLibrary for IPoolManager;

    uint256 internal constant SQRT_1_1 = 1_048_808_848; // sqrt(1.1) * 1e9, rounded down

    function setUp() public {
        _deploy(true, true, true);
    }

    /// @dev Builds a FWA backlog with the ceiling at spot, then raises it, leaving the anchor fresh.
    function _buildBacklog() internal returns (uint256 backlog) {
        _configure(1000, Q96);
        for (uint256 i; i < 4; ++i) {
            _trade(true, true, 100_000 ether);
            _trade(false, true, 100_000 ether);
        }
        backlog = manager.balanceOf(address(hook), uint160(FWA));
        assertGt(backlog, 30_000 ether);
        _configure(1000, Q96 * 2);
    }

    function test_feeFreeSwapSellsNoBacklog() public {
        uint256 backlog = _buildBacklog();
        (uint160 before,,,) = manager.getSlot0(market.toId());
        for (uint256 i; i < 8; ++i) {
            Outcome memory o = _trade(false, true, 1);
            assertEq(o.fee, 0);
            assertEq(o.spent, 0);
        }
        (uint160 afterPrice,,,) = manager.getSlot0(market.toId());
        assertEq(afterPrice, before, "dust swaps never touch the market");
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), backlog);
        assertEq(CREATOR.balance, 0);
        _assertSettled();
    }

    function test_backlogSoldPerSwapIsCappedToMultipleOfNewFee() public {
        uint256 backlog = _buildBacklog();
        Outcome memory o = _trade(true, true, 100 ether);
        _assertAccounting(o, backlog, 0);
        assertEq(o.spent, o.fee * (hook.BACKLOG_MULTIPLE() + 1));
        assertEq(o.pending, backlog - o.fee * hook.BACKLOG_MULTIPLE());
    }

    function test_oneBlockOfConversionsStaysWithinTheBoundFromTheAnchor() public {
        _buildBacklog();
        (uint160 start,,,) = manager.getSlot0(market.toId());
        uint256 sold;
        for (uint256 i; i < 8; ++i) {
            Outcome memory o = _trade(i % 2 == 0, true, 20_000 ether);
            sold += o.spent;
        }
        assertGt(sold, 0);
        (uint160 end,,,) = manager.getSlot0(market.toId());
        assertLe(uint256(end), uint256(start) * SQRT_1_1 / 1e9, "same-block moves share one anchor");
        assertGt(manager.balanceOf(address(hook), uint160(FWA)), 0, "the rest waits");
        // The next block promotes the observed price, so the backlog keeps draining.
        vm.roll(block.number + 1);
        Outcome memory later = _trade(true, true, 20_000 ether);
        assertGt(later.spent, 0);
        (uint160 next,,,) = manager.getSlot0(market.toId());
        assertGt(next, end);
        assertLe(uint256(next), uint256(end) * SQRT_1_1 / 1e9);
    }

    function test_sameBlockPriceMoveAboveTheBoundDefersConversion() public {
        uint256 backlog = _buildBacklog();
        // An attacker pushes FWA/ETH 12% above the anchor, then trades on the launch pool.
        router.swap(
            market, SwapParams(false, -500_000 ether, uint160(Q96 * 1_058_300_524 / 1e9)), 500_000 ether, 0
        );
        Outcome memory o = _trade(true, true, 10_000 ether);
        assertEq(o.spent, 0, "deferred: spot is beyond the bound from the anchor");
        assertEq(o.pending, backlog + o.fee);
        _assertAccounting(o, backlog, 0);
    }

    function test_attackerCannotProfitFromSandwichingTheFeeConversion() public {
        _configure(1000, Q96);
        _trade(true, true, 100_000 ether);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 5_000 ether);
        _configure(1000, Q96 * 2);
        uint256 fwaBefore = pair.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        // 1. Push the market just under the ceiling. 2. Trigger launch swaps, fee-free and
        // fee-bearing. 3. Buy the FWA back with the ETH gained.
        router.swap(market, SwapParams(false, -500_000 ether, uint160(Q96 * 18 / 10)), 500_000 ether, 0);
        uint256 ethGained = address(this).balance - ethBefore;
        _trade(false, true, 1);
        _trade(true, true, 100 ether);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 5_005 ether, "nothing sold into the spike");
        router.swap{value: ethGained}(
            market, SwapParams(true, -int256(ethGained), TickMath.MIN_SQRT_PRICE + 1), ethGained, 0
        );
        assertLe(pair.balanceOf(address(this)), fwaBefore, "no FWA profit");
        assertLe(address(this).balance, ethBefore, "no ETH profit");
        assertEq(CREATOR.balance, 0);
        _assertSettled();
    }

    /// @dev The reviewer's cross-block variant: push the market under the ceiling, make a dust
    /// fee-bearing buy so the spike is the last observation, hold one block, then trigger a large
    /// fee-bearing swap. The anchor may rise by one bound step, not to the manipulated spot.
    function test_anchorHeldAcrossABlockBoundaryRisesByAtMostOneStep() public {
        _configure(1000, Q96);
        _trade(true, true, 100_000 ether);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 5_000 ether);
        _configure(1000, Q96 * 2);
        uint256 fwaBefore = pair.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        // Block N: spike to 1.8x the anchor (sqrt), then a 20 wei buy whose 1 wei fee is deferred.
        router.swap(market, SwapParams(false, -500_000 ether, uint160(Q96 * 18 / 10)), 500_000 ether, 0);
        uint256 ethGained = address(this).balance - ethBefore;
        Outcome memory dust = _trade(true, true, 20);
        assertEq(dust.fee, 1);
        assertEq(dust.spent, 0);
        assertEq(hook.observedSqrtPriceX96(), uint160(Q96 * 18 / 10));
        // Block N+1: a real fee cannot sell the backlog into the held spike.
        vm.roll(block.number + 1);
        uint256 dcaBefore = token.balanceOf(address(this));
        Outcome memory o = _trade(true, true, 25_000 ether);
        assertEq(uint256(hook.anchorSqrtPriceX96()), uint256(Q96) * SQRT_1_1 / 1e9, "one step above Q96");
        assertEq(o.spent, 0, "spot is beyond the bound from the ratcheted anchor");
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 5_000 ether + 1 + o.fee);
        assertEq(CREATOR.balance, 0, "nothing sold cheaply");
        router.swap{value: ethGained}(
            market, SwapParams(true, -int256(ethGained), TickMath.MIN_SQRT_PRICE + 1), ethGained, 0
        );
        _trade(false, true, token.balanceOf(address(this)) - dcaBefore);
        assertLt(pair.balanceOf(address(this)), fwaBefore, "the attacker paid two fees for nothing");
        assertLe(address(this).balance, ethBefore);
        _assertSettled();
    }

    function test_anchorFollowsAGenuineRiseOneStepPerBlockAndThenSellsAgain() public {
        _buildBacklog();
        vm.roll(block.number + 1);
        _trade(true, true, 1_000 ether);
        assertEq(hook.anchorSqrtPriceX96(), Q96);
        uint256 backlog = manager.balanceOf(address(hook), uint160(FWA));
        // FWA genuinely gets cheaper in ETH: sqrt price rises about 1.3x (price 1.69x), below the
        // ceiling. Each block with a fee-bearing swap moves the anchor by at most one step.
        router.swap(market, SwapParams(false, -500_000 ether, uint160(Q96 * 13 / 10)), 500_000 ether, 0);
        uint160 spot = uint160(Q96 * 13 / 10);
        // The move is observed by the next sale attempt; the anchor itself still trails at Q96.
        vm.roll(block.number + 1);
        Outcome memory first = _trade(true, true, 1_000 ether);
        assertEq(hook.anchorSqrtPriceX96(), Q96);
        assertEq(hook.observedSqrtPriceX96(), spot);
        assertEq(first.spent, 0, "the bound from Q96 is below spot");
        uint256 expected = Q96;
        uint256 blocks;
        while (expected * SQRT_1_1 / 1e9 <= spot) {
            vm.roll(block.number + 1);
            Outcome memory o = _trade(blocks % 2 == 0, true, 1_000 ether);
            expected = expected * SQRT_1_1 / 1e9;
            assertEq(hook.anchorSqrtPriceX96(), expected, "one step per block");
            // Sales resume only once the bound from the new anchor reaches above spot.
            if (expected * SQRT_1_1 / 1e9 <= spot) assertEq(o.spent, 0, "anchor still trails spot");
            else assertGt(o.spent, 0, "within one step of spot");
            ++blocks;
        }
        assertEq(blocks, 5, "sqrt(1.1)^5 < 1.3 < sqrt(1.1)^6");
        vm.roll(block.number + 1);
        Outcome memory later = _trade(true, true, 1_000 ether);
        assertEq(hook.anchorSqrtPriceX96(), spot, "caught up: the observed spot is within a step");
        assertGt(later.spent, 0, "conversion resumes at the genuine price");
        assertGt(CREATOR.balance, 0);
        assertLt(manager.balanceOf(address(hook), uint160(FWA)), backlog + 7 * 50 ether);
        _assertSettled();
    }

    function test_anchorFollowsAFallingMarketAtOnce() public {
        _buildBacklog();
        assertEq(hook.anchorSqrtPriceX96(), 0);
        vm.roll(block.number + 1);
        _trade(true, true, 1_000 ether);
        assertEq(hook.anchorSqrtPriceX96(), Q96);
        // FWA gets dearer in ETH: sqrt price falls to about 0.7x. The next block adopts it in full.
        router.swap{value: 100_000 ether}(
            market, SwapParams(true, -100_000 ether, uint160(Q96 * 7 / 10)), 100_000 ether, 0
        );
        (uint160 lowered,,,) = manager.getSlot0(market.toId());
        assertLt(lowered, Q96 * 75 / 100);
        Outcome memory same = _trade(true, true, 1_000 ether);
        assertGt(same.spent, 0, "a lower spot is the base straight away");
        assertEq(hook.observedSqrtPriceX96(), lowered, "the pre-sale spot is what the next block promotes");
        vm.roll(block.number + 1);
        _trade(false, true, 1_000 ether);
        assertEq(hook.anchorSqrtPriceX96(), lowered, "a fall is never ratcheted");
        _assertSettled();
    }

    function test_backRunOfConfigurationCannotSeedTheFirstAnchor() public {
        _configure(1000, Q96);
        _trade(true, true, 100_000 ether);
        uint256 backlog = manager.balanceOf(address(hook), uint160(FWA));
        vm.prank(CREATOR);
        hook.setConversionPool(market, 1000, Q96 * 2);
        // Same block as the owner's setter: spike the market and make a fee-bearing dust buy.
        router.swap(market, SwapParams(false, -500_000 ether, uint160(Q96 * 18 / 10)), 500_000 ether, 0);
        Outcome memory dust = _trade(true, true, 20);
        assertEq(dust.spent, 0);
        assertEq(hook.observedSqrtPriceX96(), Q96, "the configuration block records no spot");
        vm.roll(block.number + 1);
        Outcome memory o = _trade(true, true, 10_000 ether);
        assertEq(hook.anchorSqrtPriceX96(), Q96, "the first anchor is the configured price");
        assertEq(o.spent, 0);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), backlog + 1 + o.fee);
        assertEq(CREATOR.balance, 0);
        _assertSettled();
    }

    function test_configurationInTheSameBlockDefersUntilTheNextBlock() public {
        vm.prank(CREATOR);
        hook.setConversionPool(market, 1000, Q96 * 2);
        assertEq(hook.anchorSqrtPriceX96(), 0);
        Outcome memory same = _trade(true, true, 100 ether);
        assertEq(same.spent, 0);
        vm.roll(block.number + 1);
        Outcome memory next = _trade(true, true, 100 ether);
        assertEq(hook.anchorSqrtPriceX96(), Q96);
        assertEq(next.spent, next.fee + same.fee);
    }

    function test_revertingMarketDefersToClaimsInsteadOfBlockingTrading() public {
        _useMarket(_atFlags(address(new RevertingConversionHook()).code, HookFlags.BEFORE_SWAP));
        Outcome memory o = _trade(true, true, 100 ether);
        _assertAccounting(o, 0, 0);
        assertEq(o.spent, 0);
        assertEq(o.pending, o.fee);
        // Repointing to a working market converts the backlog again.
        _configure(1000, Q96 * 2);
        Outcome memory next = _trade(false, true, 100 ether);
        assertEq(next.spent, next.fee + o.fee);
        assertGt(CREATOR.balance, 0);
    }

    function test_gasExhaustingMarketIsBoundedAndDefersToClaims() public {
        _useMarket(_atFlags(address(new GasBurningConversionHook()).code, HookFlags.BEFORE_SWAP));
        uint256 gasBefore = gasleft();
        Outcome memory o = _trade(true, true, 100 ether);
        uint256 used = gasBefore - gasleft();
        assertLt(used, hook.CONVERSION_GAS() + 1_500_000, "market work is bounded by the stipend");
        _assertAccounting(o, 0, 0);
        assertEq(o.spent, 0);
        assertEq(o.pending, o.fee);
    }

    function test_redeemPairIsOwnerOnlyAndKeepsClaimsWhenFwaRefusesTheRecipient() public {
        _configure(1000, Q96);
        Outcome memory o = _trade(true, true, 100 ether);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), o.fee);
        vm.prank(makeAddr("not the owner"));
        vm.expectRevert(DCAHook.OnlyOwner.selector);
        hook.redeemPair();
        // The recipient is not exempt from FWA's guard: the take reverts and the claims stay.
        vm.prank(CREATOR);
        vm.expectRevert();
        hook.redeemPair();
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), o.fee);
        pair.setDistributor(CREATOR, true);
        vm.prank(CREATOR);
        hook.redeemPair();
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 0);
        assertEq(pair.balanceOf(CREATOR), o.fee);
        assertEq(pair.balanceOf(address(hook)), 0);
        vm.prank(CREATOR);
        vm.expectRevert(DCAHook.NothingToRedeem.selector);
        hook.redeemPair();
        _assertSettled();
    }

    function test_routerThatIsNotAnFwaDistributorCannotTradeTheLaunchPool() public {
        PoolTestRouter plain = new PoolTestRouter(manager);
        token.approve(address(plain), type(uint256).max);
        pair.approve(address(plain), type(uint256).max);
        // Buy: FWA must reach the manager from a non-exempt router.
        vm.expectRevert();
        plain.swap(key, _params(true, true, 100 ether), 100 ether, 0);
        // Sell: the manager must pay FWA out to a non-exempt router.
        vm.expectRevert();
        plain.swap(key, _params(false, true, 100 ether), 100 ether, 0);
        // The manager edge only opens with a transient allowance, which FWA's own hook grants.
        pair.setDistributor(address(router), false);
        vm.expectRevert();
        router.swap(key, _params(true, true, 100 ether), 100 ether, 0);
        pair.setDistributor(address(router), true);
        _trade(true, true, 100 ether);
        _assertSettled();
    }

    function _useMarket(address conversionHook) internal {
        PoolKey memory hooked = market;
        hooked.hooks = IHooks(conversionHook);
        manager.initialize(hooked, Q96);
        router.modifyLiquidity{value: MARKET_LIQUIDITY}(
            hooked, _liquidity(MARKET_LIQUIDITY), MARKET_LIQUIDITY, MARKET_LIQUIDITY
        );
        vm.prank(CREATOR);
        hook.setConversionPool(hooked, 1000, Q96 * 2);
        vm.roll(block.number + 1);
    }

    function _atFlags(bytes memory runtime, uint160 flags) internal returns (address at) {
        at = address((uint160(makeAddr("bounded conversion hook")) & ~HookFlags.ALL) | flags);
        vm.etch(at, runtime);
    }
}
