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
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.configure.selector;
        selectors[2] = handler.resizeConversionLiquidity.selector;
        selectors[3] = handler.donateClaims.selector;
        selectors[4] = handler.recipientAcceptsEth.selector;
        selectors[5] = handler.redeem.selector;
        selectors[6] = handler.rejectUnauthorizedConfiguration.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_allCreatorFeesAndDonationsAreAccountedFor() public view {
        handler.assertClaimsConserved();
    }

    function invariant_fixedSupplyNoCustodyLeakAndNoUnsettledDelta() public view {
        handler.assertSupplyAndSettlement();
    }

    function afterInvariant() public {
        handler.finishAndCheckRecovery();
        handler.assertClaimsConserved();
        handler.assertSupplyAndSettlement();
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
}
