// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {ReentrantConversionHook, NegativeOutputConversionHook} from "./mocks/ConversionHooks.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {DCAHook} from "../src/DCAHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract ConversionSecurityTest is HookFixture {
    function setUp() public {
        _deploy(true, true, true);
    }

    function test_externalConversionHookCannotReenterLaunchSwapOrRedeem() public {
        ReentrantConversionHook template = new ReentrantConversionHook(manager, hook);
        address conversionHook = _atFlags(address(template).code, HookFlags.BEFORE_SWAP);
        ReentrantConversionHook(conversionHook).setLaunchKey(key);
        _useMarket(conversionHook);
        Outcome memory o = _trade(true, true, 100 ether);
        assertEq(ReentrantConversionHook(conversionHook).attempts(), 1);
        assertEq(ReentrantConversionHook(conversionHook).unexpectedSuccesses(), 0);
        _assertAccounting(o, 0, 0);
        assertGt(CREATOR.balance, 0);
    }

    function test_negativeNativeConversionOutputRevertsAtomically() public {
        NegativeOutputConversionHook template = new NegativeOutputConversionHook(manager);
        address conversionHook =
            _atFlags(address(template).code, HookFlags.AFTER_SWAP | HookFlags.AFTER_SWAP_RETURN_DELTA);
        _useMarket(conversionHook);
        uint256 beforePair = pair.balanceOf(address(this));
        uint256 beforeToken = token.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(DCAHook.InvalidConversionDelta.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(key, _params(true, true, 100 ether), 100 ether, 0);
        assertEq(pair.balanceOf(address(this)), beforePair);
        assertEq(token.balanceOf(address(this)), beforeToken);
        assertEq(CREATOR.balance, 0);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 0);
        assertEq(manager.balanceOf(conversionHook, 0), 0);
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
    }

    function _atFlags(bytes memory runtime, uint160 flags) internal returns (address at) {
        at = address((uint160(makeAddr("conversion hook")) & ~HookFlags.ALL) | flags);
        vm.etch(at, runtime);
    }
}
