// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {HookDeployer} from "./helpers/HookDeployer.sol";
import {DCAHook} from "../src/DCAHook.sol";
import {HookBase} from "../src/HookBase.sol";
import {DCAToken} from "../src/DCAToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract RejectEth {
    receive() external payable {
        revert("reject ETH");
    }
}

contract ReenterRecipient {
    DCAHook public immutable target;
    uint256 public attempts;
    uint256 public unexpectedSuccesses;

    constructor(DCAHook target_) {
        target = target_;
    }

    receive() external payable {
        ++attempts;
        (bool ok,) = address(target).call(abi.encodeCall(DCAHook.redeemEth, ()));
        if (ok) ++unexpectedSuccesses;
    }
}

contract HookSecurityTest is HookFixture {
    function setUp() public {
        _deploy(true, true, true);
    }

    function test_permissionsExactlyMatchMinedAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(p.afterAddLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.DCA);
        assertEq(HookFlags.DCA, 0x20cc);
        assertEq(hook.owner(), CREATOR);
        assertEq(hook.factory(), address(this));
        assertEq(hook.RECIPIENT(), CREATOR);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(PoolId.unwrap(hook.launchPoolId()), PoolId.unwrap(key.toId()));
    }

    function test_enabledCallbacksAndUnlockRejectUnauthorizedCallers() public {
        vm.expectRevert(HookBase.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        SwapParams memory p = _params(true, true, 100 ether);
        vm.expectRevert(HookBase.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(HookBase.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(HookBase.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(DCAHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
    }

    function test_disabledCallbacksFailClosed() public {
        bytes[] memory calls = new bytes[](7);
        ModifyLiquidityParams memory p = _liquidity(100);
        calls[0] = abi.encodeCall(IHooks.afterInitialize, (address(this), key, Q96, 0));
        calls[1] = abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, p, ""));
        calls[2] = abi.encodeCall(
            IHooks.afterAddLiquidity, (address(this), key, p, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "")
        );
        calls[3] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, p, ""));
        calls[4] = abi.encodeCall(
            IHooks.afterRemoveLiquidity,
            (address(this), key, p, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "")
        );
        calls[5] = abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, ""));
        calls[6] = abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, ""));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(reason), HookBase.OnlyPoolManager.selector);
            vm.prank(address(manager));
            (ok, reason) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(reason), HookBase.CallbackDisabled.selector);
        }
    }

    function test_initializationRequiresFactoryAndCorrectPool() public {
        DCAHook uninitialized = _freshHook(address(manager));
        PoolKey memory newKey = key;
        newKey.currency0 = Currency.wrap(uninitialized.token());
        if (uninitialized.token() > FWA) {
            newKey.currency0 = Currency.wrap(FWA);
            newKey.currency1 = Currency.wrap(uninitialized.token());
        }
        newKey.hooks = IHooks(address(uninitialized));
        vm.prank(makeAddr("unauthorized initializer"));
        vm.expectRevert();
        manager.initialize(newKey, Q96);
        PoolKey memory invalid = abi.decode(abi.encode(newKey), (PoolKey));
        invalid.fee = 3000;
        vm.expectRevert();
        manager.initialize(invalid, Q96);
        invalid = abi.decode(abi.encode(newKey), (PoolKey));
        invalid.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(invalid, Q96);
        invalid = abi.decode(abi.encode(newKey), (PoolKey));
        invalid.currency0 = Currency.wrap(address(0));
        vm.expectRevert();
        manager.initialize(invalid, Q96);
        assertFalse(uninitialized.initialized());
        manager.initialize(newKey, Q96);
        assertTrue(uninitialized.initialized());
        vm.expectRevert();
        manager.initialize(newKey, Q96);
    }

    function test_constructorNeedsNoExternalCodeAtAnyDependency() public {
        address emptyManager = makeAddr("empty manager supplied by deployer");
        address emptyToken = makeAddr("empty launch token");
        address launchFactory = makeAddr("launch factory");
        DCAHook built = DCAHook(
            HookDeployer.deploy(
                abi.encodePacked(
                    type(DCAHook).creationCode, abi.encode(emptyManager, emptyToken, launchFactory, CREATOR)
                )
            )
        );
        assertEq(address(built.poolManager()), emptyManager);
        assertEq(built.token(), emptyToken);
        assertEq(built.owner(), CREATOR);
    }

    function test_constructorRejectsZeroArgumentsAndPairAsLaunchToken() public {
        address[4] memory args = [address(manager), address(token), address(this), CREATOR];
        for (uint256 i; i < args.length; ++i) {
            address saved = args[i];
            args[i] = address(0);
            vm.expectRevert(HookBase.ZeroAddress.selector);
            new DCAHook(IPoolManager(args[0]), args[1], args[2], args[3]);
            args[i] = saved;
        }
        vm.expectRevert(DCAHook.InvalidPool.selector);
        new DCAHook(manager, FWA, address(this), CREATOR);
    }

    function test_constructorRejectsWrongAddressFlags() public {
        bytes memory code = abi.encodePacked(
            type(DCAHook).creationCode, abi.encode(manager, address(token), address(this), CREATOR)
        );
        bytes32 salt;
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code)))))
        );
        assertFalse(HookFlags.matches(predicted, HookFlags.DCA));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new DCAHook{salt: salt}(manager, address(token), address(this), CREATOR);
    }

    function test_configurationIsOwnerOnlyIncludingAgainstFactory() public {
        vm.expectRevert(DCAHook.OnlyOwner.selector);
        hook.setConversionPool(market, 100, Q96 * 2);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(DCAHook.OnlyOwner.selector);
        hook.setConversionPool(market, 100, Q96 * 2);
        _configure(100, Q96 * 2);
        assertEq(hook.maxPriceMoveBps(), 100);
    }

    function test_configurationRejectsWrongCurrencyHookUninitializedMarketAndLimits() public {
        PoolKey memory invalid = market;
        invalid.currency1 = Currency.wrap(address(token));
        _rejectMarket(invalid);
        invalid = market;
        invalid.currency0 = Currency.wrap(address(token));
        _rejectMarket(invalid);
        invalid = market;
        invalid.hooks = IHooks(address(hook));
        _rejectMarket(invalid);
        invalid = market;
        invalid.fee = 10_000;
        _rejectMarket(invalid); // not initialized
        invalid = market;
        invalid.fee = 1_000_000;
        _rejectMarket(invalid);
        invalid = market;
        invalid.tickSpacing = 0;
        _rejectMarket(invalid);
        vm.startPrank(CREATOR);
        vm.expectRevert(DCAHook.InvalidPriceLimits.selector);
        hook.setConversionPool(market, 0, Q96 * 2);
        vm.expectRevert(DCAHook.InvalidPriceLimits.selector);
        hook.setConversionPool(market, 1001, Q96 * 2);
        vm.expectRevert(DCAHook.InvalidPriceLimits.selector);
        hook.setConversionPool(market, 100, TickMath.MIN_SQRT_PRICE);
        vm.expectRevert(DCAHook.InvalidPriceLimits.selector);
        hook.setConversionPool(market, 100, TickMath.MAX_SQRT_PRICE);
        vm.stopPrank();
    }

    function test_ownerCanReplaceMarketWhileKeepingOldFeeClaims() public {
        _configure(1000, Q96);
        Outcome memory first = _trade(true, true, 100 ether);
        PoolKey memory replacement = market;
        replacement.fee = 500;
        manager.initialize(replacement, Q96);
        router.modifyLiquidity{value: MARKET_LIQUIDITY}(
            replacement, _liquidity(MARKET_LIQUIDITY), MARKET_LIQUIDITY, MARKET_LIQUIDITY
        );
        vm.prank(CREATOR);
        hook.setConversionPool(replacement, 1000, Q96 * 2);
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), first.fee);
        Outcome memory next = _trade(false, true, 100 ether);
        assertEq(next.spent, first.fee + next.fee);
        assertEq(next.pending, 0);
    }

    function test_rejectingRecipientDefersWithoutBlockingAndCanRecover() public {
        vm.etch(CREATOR, address(new RejectEth()).code);
        Outcome memory o = _trade(true, true, 100 ether);
        assertGt(o.ethOut, 0);
        assertEq(CREATOR.balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), o.ethOut);
        hook.redeemEth();
        assertEq(manager.balanceOf(address(hook), 0), o.ethOut, "failed redemption preserves claim");
        vm.etch(CREATOR, "");
        vm.prank(makeAddr("redeem caller"));
        hook.redeemEth();
        assertEq(CREATOR.balance, o.ethOut);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function test_recipientCannotReenterFeePaymentOrClaimRedemption() public {
        ReenterRecipient recipient = new ReenterRecipient(hook);
        vm.etch(CREATOR, address(recipient).code);
        Outcome memory o = _trade(true, true, 100 ether);
        assertEq(ReenterRecipient(payable(CREATOR)).attempts(), 1);
        assertEq(ReenterRecipient(payable(CREATOR)).unexpectedSuccesses(), 0);
        assertEq(CREATOR.balance, o.ethOut);
        router.drainAndSwap(key, _params(false, true, 100 ether), 100 ether, 0);
        hook.redeemEth();
        assertEq(ReenterRecipient(payable(CREATOR)).attempts(), 2);
        assertEq(ReenterRecipient(payable(CREATOR)).unexpectedSuccesses(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function test_donatedClaimsCannotRedirectFeesAndAreRecoverableToCreator() public {
        router.mintClaims{value: 1 ether}(Currency.wrap(address(0)), 1 ether, address(hook));
        router.mintClaims(Currency.wrap(FWA), 2 ether, address(hook));
        hook.redeemEth();
        assertEq(CREATOR.balance, 1 ether);
        Outcome memory o = _trade(true, true, 100 ether);
        assertEq(o.spent, 7 ether);
        assertEq(CREATOR.balance, 1 ether + o.ethOut);
        _assertSettled();
    }

    function test_beforeSwapRejectsWrongPoolZeroAndOversizedAmounts() public {
        SwapParams memory p = _params(true, true, 100 ether);
        PoolKey memory other = key;
        other.fee = 3000;
        vm.startPrank(address(manager));
        vm.expectRevert(DCAHook.InvalidPool.selector);
        hook.beforeSwap(address(this), other, p, "");
        p.amountSpecified = 0;
        vm.expectRevert(DCAHook.InvalidSwapAmount.selector);
        hook.beforeSwap(address(this), key, p, "");
        p.amountSpecified = type(int256).min;
        vm.expectRevert(DCAHook.InvalidSwapAmount.selector);
        hook.beforeSwap(address(this), key, p, "");
        p.amountSpecified = type(int256).max;
        vm.expectRevert(DCAHook.InvalidSwapAmount.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.stopPrank();
        p = _params(false, false, uint256(uint128(type(int128).max)));
        vm.prank(address(manager));
        vm.expectRevert(DCAHook.InvalidSwapAmount.selector);
        hook.beforeSwap(address(this), key, p, "");
    }

    function test_runtimeWithinSizeLimitAndNoEscapeOpcodes() public view {
        bytes memory code = address(hook).code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff);
        }
    }

    function _freshHook(address manager_) internal returns (DCAHook) {
        DCAToken otherToken = new DCAToken();
        return DCAHook(
            HookDeployer.deploy(
                abi.encodePacked(
                    type(DCAHook).creationCode,
                    abi.encode(manager_, address(otherToken), address(this), CREATOR)
                )
            )
        );
    }

    function _rejectMarket(PoolKey memory invalid) internal {
        vm.prank(CREATOR);
        vm.expectRevert(DCAHook.InvalidConversionPool.selector);
        hook.setConversionPool(invalid, 100, Q96 * 2);
    }
}
