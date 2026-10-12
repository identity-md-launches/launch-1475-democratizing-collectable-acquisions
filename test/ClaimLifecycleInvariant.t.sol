// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ClaimLifecycleHandler} from "./helpers/ClaimLifecycleHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract ClaimLifecycleInvariantTest is Test {
    ClaimLifecycleHandler internal handler;

    function setUp() public {
        handler = new ClaimLifecycleHandler();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.configure.selector;
        selectors[2] = handler.resizeConversionLiquidity.selector;
        selectors[3] = handler.donateClaims.selector;
        selectors[4] = handler.recipientAcceptsEth.selector;
        selectors[5] = handler.redeem.selector;
        selectors[6] = handler.rejectUnauthorizedConfiguration.selector;
        selectors[7] = handler.moveMarket.selector;
        selectors[8] = handler.roll.selector;
        selectors[9] = handler.redeemPair.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_allCreatorFeesAndDonationsAreAccountedFor() public view {
        handler.assertClaimsConserved();
    }

    function invariant_fixedSupplyNoCustodyLeakAndNoUnsettledDelta() public view {
        handler.assertSupplyAndSettlement();
    }

    /// @dev The anchor the hook reports is the one the handler saw it promote: it only moves inside
    /// a trade, the first value after a configuration is the configured price, each later promotion
    /// lifts it by at most one bound step, and it changes at most once per block.
    function invariant_anchorFollowsTheRatchetModel() public view {
        handler.assertAnchorModel();
    }

    function afterInvariant() public {
        handler.finishAndCheckRecovery();
        handler.assertClaimsConserved();
        handler.assertSupplyAndSettlement();
        handler.assertAnchorModel();
    }

    function test_sequenceEmptyMarketSwitchRejectedPayoutAndRecovery() public {
        handler.resizeConversionLiquidity(0);
        handler.resizeConversionLiquidity(0);
        handler.trade(0, true, true, 100 ether, false);
        handler.donateClaims(1, false, 2 ether);
        handler.configure(1, 1, false);
        handler.recipientAcceptsEth(false);
        handler.trade(2, false, false, 100 ether, true);
        handler.donateClaims(0, true, 1 ether);
        handler.redeem(1);
        handler.rejectUnauthorizedConfiguration(2);
        handler.assertClaimsConserved();
        handler.assertSupplyAndSettlement();
        assertEq(handler.successfulTrades(), 2, "scenario must exercise real trades");
        afterInvariant();
    }

    /// @dev A manipulator moves the market above the bound in one block, a trade in the next block
    /// must defer (its anchor predates the move), and the block after that sells from the anchor
    /// promoted one step towards the move. The owner's exit then clears what was deferred, paying
    /// FWA to the recipient only.
    function test_sequenceMultiBlockManipulationDefersThenRecoversAndOwnerExits() public {
        handler.trade(0, true, true, 100 ether, false);
        assertEq(handler.hookSales(), 1);
        assertEq(handler.anchorPromotions(), 1, "the first trade promotes the configured price");
        // 6,000 FWA into a 100,000-deep market lifts sqrt price about 6%: over one step (4.88%),
        // under the bound from one step up (10%).
        handler.moveMarket(1, true, 6_000 ether);
        handler.roll(1);
        handler.trade(2, true, true, 100 ether, false);
        assertEq(handler.deferredSales(), 1, "stale anchor below the moved spot must defer");
        assertEq(handler.anchorPromotions(), 1, "the anchor predates the move");
        handler.roll(1);
        handler.trade(0, false, false, 100 ether, false);
        assertEq(handler.anchorPromotions(), 2, "one capped promotion");
        assertEq(handler.hookSales(), 2, "one step towards the move already clears spot");
        handler.moveMarket(2, false, 5 ether);
        handler.trade(1, true, true, 100 ether, false);
        assertEq(handler.hookSales(), 3, "a lowered spot only tightens the bound");
        handler.configure(0, 1, true);
        handler.trade(0, true, true, 100 ether, false);
        handler.redeemPair(false);
        handler.redeemPair(true);
        handler.redeemPair(true);
        handler.assertClaimsConserved();
        handler.assertSupplyAndSettlement();
        assertGt(handler.pairRedeemed(), 0);
        afterInvariant();
    }
}
