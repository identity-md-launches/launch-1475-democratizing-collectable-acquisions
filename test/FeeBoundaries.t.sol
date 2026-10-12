// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {DCAHook} from "src/DCAHook.sol";

/// @dev The fee oracle uses wallet changes and PoolManager events, independently of the hook's
/// reported gross/fee/conversion amounts. Both currency orderings run this entire suite.
abstract contract FeeBoundaryChecks is HookFixture {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    uint256 internal constant MAX_SIGNED_DELTA = uint256(uint128(type(int128).max));

    struct WalletState {
        uint256 pairBalance;
        uint256 tokenBalance;
        uint256 pairClaims;
        uint256 entitlement;
    }

    function test_allSwapModesAtWeiRoundingBoundaries() public {
        uint256[12] memory amounts = [uint256(1), 2, 18, 19, 20, 21, 37, 38, 39, 40, 59, 60];
        for (uint256 mode; mode < 4; ++mode) {
            for (uint256 i; i < amounts.length; ++i) {
                _checkWalletFee(mode < 2, mode % 2 == 0, amounts[i]);
            }
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_walletFeeIsFivePercentOfActualGross(bool buy, bool exactInput, uint96 raw) public {
        _checkWalletFee(buy, exactInput, bound(uint256(raw), 1, 5000 ether));
    }

    function _checkWalletFee(bool buy, bool exactInput, uint256 amount) internal {
        WalletState memory beforeState = WalletState(
            pair.balanceOf(address(this)),
            token.balanceOf(address(this)),
            manager.balanceOf(address(hook), uint160(FWA)),
            CREATOR.balance + manager.balanceOf(address(hook), 0)
        );
        vm.recordLogs();
        BalanceDelta userDelta = router.swap(key, _params(buy, exactInput, amount), amount * 4 + 100, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory reported = _outcome(logs, userDelta);
        int256 walletPairDelta = int256(pair.balanceOf(address(this))) - int256(beforeState.pairBalance);
        int256 walletTokenDelta = int256(token.balanceOf(address(this))) - int256(beforeState.tokenBalance);
        int256 actualFee = int256(reported.rawPair) - walletPairDelta;
        assertGe(actualFee, 0, "hook must not subsidize a swap with other creators' claims");
        uint256 fee = uint256(actualFee);
        uint256 gross = buy ? uint256(-walletPairDelta) : uint256(int256(reported.rawPair));

        // Integer-floor specification: fee <= 5% of gross, with less than one wei of dust.
        assertLe(fee * 20, gross, "overcharged");
        assertLt(gross, (fee + 1) * 20, "undercharged");
        assertEq(walletTokenDelta, int256(reported.rawToken), "DCA must never pay the fee");
        assertEq(walletPairDelta, int256(_pairDelta(userDelta)));
        assertEq(walletTokenDelta, int256(_tokenDelta(userDelta)));
        assertEq(reported.gross, gross, "honest gross event");
        assertEq(reported.fee, fee, "honest fee event");
        assertEq(reported.buy, buy);
        {
            int256 input = buy ? walletPairDelta : walletTokenDelta;
            int256 output = buy ? walletTokenDelta : walletPairDelta;
            if (exactInput) assertEq(input, -int256(amount), "exact input including fee");
            else assertEq(output, int256(amount), "exact output after fee");
            assertLe(input, 0);
            assertGe(output, 0);
            if (output > 0) assertLt(input, 0, "no free output at a rounding boundary");
        }

        (uint256 pairSold, uint256 ethEarned) = _conversionFromManager(logs);
        assertEq(beforeState.pairClaims + fee, pairSold + manager.balanceOf(address(hook), uint160(FWA)));
        assertEq(beforeState.entitlement + ethEarned, CREATOR.balance + manager.balanceOf(address(hook), 0));
        assertEq(reported.spent, pairSold);
        assertEq(reported.ethOut, ethEarned);
        assertEq(pair.balanceOf(CREATOR), 0, "creator gets ETH, not FWA");
        assertEq(token.balanceOf(CREATOR), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(pair.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(pair.balanceOf(address(router)), 0);
        _assertSettled();
    }

    function _conversionFromManager(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 spent, uint256 earned)
    {
        uint256 conversions;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_TOPIC
                    || logs[i].topics[1] != PoolId.unwrap(market.toId())
            ) continue;
            (int128 nativeDelta, int128 pairDelta,,,,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertGe(nativeDelta, 0);
            assertLe(pairDelta, 0);
            spent += uint256(-int256(pairDelta));
            earned += uint256(int256(nativeDelta));
            ++conversions;
        }
        assertLe(conversions, 1, "bounded conversion work");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_beforeSwapCannotConsumeTheWholeInput(uint128 raw) public {
        uint256 amount = bound(uint256(raw), 1, MAX_SIGNED_DELTA);
        SwapParams memory params = _params(true, true, amount);
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 overrideFee) =
            hook.beforeSwap(address(this), key, params, hex"010203");
        int128 fee = delta.getSpecifiedDelta();
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(overrideFee, 0, "no LP fee override");
        assertEq(delta.getUnspecifiedDelta(), 0);
        assertGe(fee, 0);
        assertLt(uint256(int256(fee)), amount, "NoOp/full-input substitution");
        assertLe(uint256(int256(fee)) * 20, amount);
        assertLt(amount, (uint256(int256(fee)) + 1) * 20);
    }

    function test_largestGrossedUpExactOutputAndFirstInvalidNeighbor() public {
        uint256 largestNet = MAX_SIGNED_DELTA - MAX_SIGNED_DELTA / 20;
        SwapParams memory params = _params(false, false, largestNet);
        vm.prank(address(manager));
        (, BeforeSwapDelta delta,) = hook.beforeSwap(address(this), key, params, "");
        uint256 fee = uint256(int256(delta.getSpecifiedDelta()));
        assertEq(largestNet + fee, MAX_SIGNED_DELTA);
        assertLe(fee * 20, largestNet + fee);
        assertLt(largestNet + fee, (fee + 1) * 20);
        params.amountSpecified = int256(largestNet + 1);
        vm.prank(address(manager));
        vm.expectRevert(DCAHook.InvalidSwapAmount.selector);
        hook.beforeSwap(address(this), key, params, "");
        _assertSettled();
    }

    function test_dcaSpecifiedDoesNotChangeRequestedAmountAtSignedBoundary() public {
        for (uint256 mode; mode < 2; ++mode) {
            SwapParams memory params = _params(mode == 0, mode != 0, MAX_SIGNED_DELTA);
            vm.prank(address(manager));
            (bytes4 selector, BeforeSwapDelta delta, uint24 overrideFee) =
                hook.beforeSwap(address(this), key, params, "");
            assertEq(selector, IHooks.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(overrideFee, 0);
        }
    }
}

/// forge-config: default.fuzz.runs = 1000
contract FeeBoundariesToken0Test is FeeBoundaryChecks {
    function setUp() public {
        _deploy(true, true, true);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract FeeBoundariesPair0Test is FeeBoundaryChecks {
    function setUp() public {
        _deploy(true, true, false);
    }
}
