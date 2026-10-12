// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {HookDeployer} from "./helpers/HookDeployer.sol";
import {DCAHook} from "src/DCAHook.sol";
import {DCAToken} from "src/DCAToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract HookFailurePathsTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deploy(true, true, true);
    }

    function test_bothSwapCallbacksRejectUninitializedHook() public {
        DCAToken freshToken = new DCAToken();
        DCAHook fresh = DCAHook(
            HookDeployer.deploy(
                abi.encodePacked(
                    type(DCAHook).creationCode,
                    abi.encode(manager, address(freshToken), address(this), CREATOR)
                )
            )
        );
        PoolKey memory freshKey = key;
        freshKey.currency0 = Currency.wrap(address(freshToken) < FWA ? address(freshToken) : FWA);
        freshKey.currency1 = Currency.wrap(address(freshToken) < FWA ? FWA : address(freshToken));
        freshKey.hooks = IHooks(address(fresh));
        SwapParams memory params = _params(true, true, 1 ether);
        vm.startPrank(address(manager));
        vm.expectRevert(DCAHook.PoolNotInitialized.selector);
        fresh.beforeSwap(address(this), freshKey, params, "");
        vm.expectRevert(DCAHook.PoolNotInitialized.selector);
        fresh.afterSwap(address(this), freshKey, params, BalanceDelta.wrap(0), "");
        vm.stopPrank();
        assertFalse(fresh.initialized());
    }

    function test_bothSwapCallbacksAuthenticateEveryPoolKeyField() public {
        SwapParams memory params = _params(true, true, 1 ether);
        for (uint256 i; i < 5; ++i) {
            PoolKey memory wrong = key;
            if (i == 0) wrong.currency0 = Currency.wrap(address(0));
            if (i == 1) wrong.currency1 = Currency.wrap(address(token));
            if (i == 2) wrong.fee = 3000;
            if (i == 3) wrong.tickSpacing = 120;
            if (i == 4) wrong.hooks = IHooks(address(0));
            vm.startPrank(address(manager));
            vm.expectRevert(DCAHook.InvalidPool.selector);
            hook.beforeSwap(address(this), wrong, params, "");
            vm.expectRevert(DCAHook.InvalidPool.selector);
            hook.afterSwap(address(this), wrong, params, BalanceDelta.wrap(0), "");
            vm.stopPrank();
        }
        _assertSettled();
    }

    function test_bothSwapCallbacksRejectZeroAndSignedRangeNeighbors() public {
        int256 max = int256(type(int128).max);
        int256[5] memory amounts = [int256(0), max + 1, -max - 1, type(int256).min, type(int256).max];
        SwapParams memory params = _params(true, true, 1);
        for (uint256 i; i < amounts.length; ++i) {
            params.amountSpecified = amounts[i];
            vm.startPrank(address(manager));
            vm.expectRevert(DCAHook.InvalidSwapAmount.selector);
            hook.beforeSwap(address(this), key, params, "");
            vm.expectRevert(DCAHook.InvalidSwapAmount.selector);
            hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
            vm.stopPrank();
        }
    }

    function test_afterSwapRejectsReversedPairDeltasAndOverflowingGross() public {
        // Pair is currency1 here. These synthetic deltas isolate validation before fund movement.
        SwapParams memory buy = _params(true, false, 1);
        SwapParams memory sell = _params(false, true, 1);
        vm.startPrank(address(manager));
        vm.expectRevert(DCAHook.InvalidSwapAmount.selector);
        hook.afterSwap(address(this), key, buy, toBalanceDelta(1, 1), "");
        vm.expectRevert(DCAHook.InvalidSwapAmount.selector);
        hook.afterSwap(address(this), key, sell, toBalanceDelta(-1, -1), "");
        vm.expectRevert(DCAHook.InvalidSwapAmount.selector);
        hook.afterSwap(address(this), key, buy, toBalanceDelta(1, -type(int128).max), "");
        vm.stopPrank();
        _assertSettled();
    }

    function test_partialSpecifiedFillReturnsExactErrorAndPreservesOldClaims() public {
        _seedClaims();
        for (uint256 mode; mode < 2; ++mode) {
            bytes32 beforeState = _financialState();
            SwapParams memory params = _params(mode == 0, mode == 0, 1000 ether);
            params.sqrtPriceLimitX96 = params.zeroForOne ? Q96 - 1 : Q96 + 1;
            vm.expectRevert(_wrapped(IHooks.afterSwap.selector, DCAHook.PartialFillNotSupported.selector));
            router.swap(key, params, 10_000 ether, 0);
            assertEq(_financialState(), beforeState, "failed partial swap changed funds or either pool");
            _assertSettled();
        }
    }

    function test_lateSlippageRevertRestoresClaimsBothPoolsAndPayout() public {
        _seedClaims();
        _configure(1000, Q96 * 2);
        bytes32 beforeState = _financialState();
        SwapParams memory params = _params(true, true, 100 ether);
        vm.expectRevert("slippage");
        router.swap(key, params, 100 ether, type(uint128).max);
        assertEq(_financialState(), beforeState, "claims burned and ETH paid must roll back too");
        _assertSettled();
        Outcome memory success = _trade(true, true, 100 ether);
        assertGt(success.spent, success.fee, "prior pair claims remain spendable");
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertGt(CREATOR.balance, 0);
    }

    function test_inputSettlementFailureRollsBackConversionAndCreatorPayment() public {
        _seedClaims();
        _configure(1000, Q96 * 2);
        bytes32 beforeState = _financialState();
        SwapParams memory params = _params(true, true, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(router), uint256(1), 100 ether
            )
        );
        router.swap(key, params, 1, 0);
        assertEq(_financialState(), beforeState);
        _assertSettled();
        _trade(true, true, 100 ether);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_configurationRejectsMalformedHooksFeesAndSpacingWithoutLosingClaims() public {
        _seedClaims();
        bytes32 fundsBefore = _financialState();
        bytes32 configBefore = _configuration();
        for (uint256 i; i < 6; ++i) {
            PoolKey memory invalid = market;
            if (i == 0) invalid.tickSpacing = -1;
            if (i == 1) invalid.tickSpacing = TickMath.MAX_TICK_SPACING + 1;
            if (i == 2) invalid.fee = 0x800001; // not the dynamic-fee flag
            if (i == 3) invalid.hooks = IHooks(address(uint160(1 << 3))); // return-delta without beforeSwap
            if (i == 4) invalid.hooks = IHooks(address(uint160(1 << 7))); // valid flags, absent code
            if (i == 5) invalid.fee = 0x800000; // dynamic fee requires a hook
            vm.prank(CREATOR);
            vm.expectRevert(DCAHook.InvalidConversionPool.selector);
            hook.setConversionPool(invalid, 100, Q96 * 2);
            assertEq(_financialState(), fundsBefore);
            assertEq(_configuration(), configBefore);
        }
    }

    function _seedClaims() internal {
        // Actual fully funded claims, with both currencies pending before the failing operation.
        router.mintClaims(Currency.wrap(FWA), 7 ether, address(hook));
        router.mintClaims{value: 3 ether}(Currency.wrap(address(0)), 3 ether, address(hook));
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 7 ether);
        assertEq(manager.balanceOf(address(hook), 0), 3 ether);
    }

    function _financialState() internal view returns (bytes32) {
        bytes32 wallets = keccak256(
            abi.encode(
                pair.balanceOf(address(this)),
                token.balanceOf(address(this)),
                pair.balanceOf(address(router)),
                token.balanceOf(address(router)),
                pair.balanceOf(address(manager)),
                token.balanceOf(address(manager)),
                address(manager).balance,
                CREATOR.balance,
                address(router).balance
            )
        );
        return keccak256(
            abi.encode(
                wallets,
                manager.balanceOf(address(hook), uint160(FWA)),
                manager.balanceOf(address(hook), 0),
                _poolState(key),
                _poolState(market)
            )
        );
    }

    function _poolState(PoolKey memory pool) internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(pool.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(pool.toId());
        return keccak256(
            abi.encode(price, tick, protocolFee, lpFee, growth0, growth1, manager.getLiquidity(pool.toId()))
        );
    }

    function _configuration() internal view returns (bytes32) {
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks hooks) = hook.conversionPool();
        return keccak256(
            abi.encode(
                c0,
                c1,
                fee,
                spacing,
                hooks,
                hook.maxPriceMoveBps(),
                hook.maxConversionSqrtPriceX96(),
                hook.conversionConfigured(),
                hook.launchPoolId(),
                hook.initialized()
            )
        );
    }

    function _wrapped(bytes4 callback, bytes4 errorSelector) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(errorSelector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
