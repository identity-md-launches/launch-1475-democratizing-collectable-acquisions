// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {RejectEth} from "./HookSecurity.t.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice Random sequences combine trades, conversion limits, ETH shortages, recipient failures,
/// and redemptions. Ghost totals are built from actual pool deltas and conversion events.
contract HookInvariantTest is HookFixture {
    using StateLibrary for IPoolManager;
    uint256 public totalFees;
    uint256 public totalPairSold;
    uint256 public totalEthEarned;
    uint256 public tradeCount;
    bytes private rejectCode;

    function setUp() public {
        _deploy(true, true, true);
        rejectCode = address(new RejectEth()).code;
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = this.actTrade.selector;
        selectors[1] = this.actLimits.selector;
        selectors[2] = this.actRecipient.selector;
        selectors[3] = this.actRedeem.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    function actTrade(bool buy, bool exactInput, bool nativeUnavailable, uint96 raw) external {
        uint256 amount = bound(uint256(raw), 1e12, 500 ether);
        uint256 claimsBefore = manager.balanceOf(address(hook), uint160(FWA));
        uint256 ethBefore = CREATOR.balance + manager.balanceOf(address(hook), 0);
        Outcome memory o;
        if (nativeUnavailable) {
            vm.recordLogs();
            BalanceDelta delta =
                router.drainAndSwap(key, _params(buy, exactInput, amount), amount * 4 + 100, 0);
            o = _outcome(vm.getRecordedLogs(), delta);
        } else {
            o = _trade(buy, exactInput, amount);
        }
        _assertAccounting(o, claimsBefore, ethBefore);
        totalFees += o.fee;
        totalPairSold += o.spent;
        totalEthEarned += o.ethOut;
        ++tradeCount;
    }

    function actLimits(bool defer, bool narrow) external {
        (uint160 price,,,) = manager.getSlot0(market.toId());
        _configure(narrow ? 1 : 1000, defer ? price : price + price / 5);
    }

    function actRecipient(bool reject) external {
        vm.etch(CREATOR, reject ? rejectCode : bytes(""));
    }

    function actRedeem() external {
        hook.redeemEth();
    }

    function invariant_allFeesAreSoldOrHeldAsPairClaims() public view {
        assertEq(totalFees, totalPairSold + manager.balanceOf(address(hook), uint160(FWA)));
        assertEq(pair.balanceOf(address(hook)), 0);
    }

    function invariant_allEthIsPaidToCreatorOrHeldAsEthClaims() public view {
        assertEq(totalEthEarned, CREATOR.balance + manager.balanceOf(address(hook), 0));
        assertEq(address(hook).balance, 0);
    }

    function invariant_noOpenDeltasAndFixedTokenSupply() public view {
        _assertSettled();
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(pair.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(address(manager)), token.totalSupply());
        assertEq(pair.balanceOf(address(this)) + pair.balanceOf(address(manager)), pair.totalSupply());
    }
}
