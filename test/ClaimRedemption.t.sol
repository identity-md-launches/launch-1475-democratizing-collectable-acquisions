// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {RejectEth} from "./HookSecurity.t.sol";
import {DCAHook} from "src/DCAHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract NestedRedemptionProbe is IUnlockCallback {
    IPoolManager private immutable manager;
    DCAHook private immutable hook;
    bool public redemptionSucceeded;
    bytes public redemptionError;

    constructor(IPoolManager manager_, DCAHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function run() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (redemptionSucceeded, redemptionError) = address(hook).call(abi.encodeCall(DCAHook.redeemEth, ()));
        return "";
    }
}

contract ReconfiguringRecipient {
    DCAHook private immutable hook;
    uint256 public attempts;
    bool public configurationSucceeded;
    bytes4 public errorSelector;

    constructor(DCAHook hook_) {
        hook = hook_;
    }

    receive() external payable {
        ++attempts;
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks hooks) = hook.conversionPool();
        try hook.setConversionPool(
            PoolKey(c0, c1, fee, spacing, hooks), 1, hook.maxConversionSqrtPriceX96()
        ) {
            configurationSucceeded = true;
        } catch (bytes memory reason) {
            errorSelector = bytes4(reason);
        }
    }
}

contract ClaimRedemptionTest is HookFixture {
    function setUp() public {
        _deploy(true, true, true);
    }

    function test_redemptionChunksAboveInt128AndCannotBeReplayed() public {
        uint256 chunk = uint256(uint128(type(int128).max));
        uint256 total = 2 * chunk + 17;
        // Native funding is test setup for the arithmetic boundary, not a manager storage patch.
        vm.deal(address(this), total);
        router.mintClaims{value: chunk}(Currency.wrap(address(0)), chunk, address(hook));
        router.mintClaims{value: chunk}(Currency.wrap(address(0)), chunk, address(hook));
        router.mintClaims{value: 17}(Currency.wrap(address(0)), 17, address(hook));
        assertEq(manager.balanceOf(address(hook), 0), total);
        address caller = makeAddr("claim redemption caller");
        for (uint256 i; i < 4; ++i) {
            vm.prank(caller);
            hook.redeemEth();
            uint256 expectedPaid = i == 0 ? chunk : (i == 1 ? 2 * chunk : total);
            assertEq(CREATOR.balance, expectedPaid);
            assertEq(manager.balanceOf(address(hook), 0), total - expectedPaid);
            assertEq(caller.balance, 0);
            _assertSettled();
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_oldClaimsAndNewFeeConservedWithLimitedCash(bool reject, uint96 rawCash) public {
        uint256 cash = bound(uint256(rawCash), 0, 20 ether);
        router.mintClaims{value: 8 ether}(Currency.wrap(address(0)), 8 ether, address(hook));
        if (reject) vm.etch(CREATOR, address(new RejectEth()).code);
        vm.recordLogs();
        BalanceDelta delta = router.drainAndSwap(key, _params(true, true, 100 ether), 100 ether, cash);
        Outcome memory o = _outcome(vm.getRecordedLogs(), delta);
        uint256 entitlement = 8 ether + o.ethOut;
        uint256 paid = reject ? 0 : (cash < entitlement ? cash : entitlement);
        assertGt(o.ethOut, 0, "a conversion must occur");
        assertEq(CREATOR.balance, paid);
        assertEq(manager.balanceOf(address(hook), 0), entitlement - paid);
        assertEq(router.nativeBalanceAtSwap(), cash);
        _assertSettled();

        vm.etch(CREATOR, "");
        hook.redeemEth();
        hook.redeemEth();
        assertEq(CREATOR.balance, entitlement);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function test_redemptionDuringExistingUnlockCannotLeavePendingAuthorization() public {
        router.mintClaims{value: 3 ether}(Currency.wrap(address(0)), 3 ether, address(hook));
        NestedRedemptionProbe probe = new NestedRedemptionProbe(manager, hook);
        probe.run();
        assertFalse(probe.redemptionSucceeded());
        assertEq(probe.redemptionError(), abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        assertEq(manager.balanceOf(address(hook), 0), 3 ether);
        vm.prank(address(manager));
        vm.expectRevert(DCAHook.UnexpectedUnlock.selector);
        hook.unlockCallback(hex"1234");
        hook.redeemEth();
        assertEq(CREATOR.balance, 3 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        vm.prank(address(manager));
        vm.expectRevert(DCAHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
        _assertSettled();
    }

    function test_ownerRecipientCannotChangeRouteInsideSwapOrRedemptionPayout() public {
        ReconfiguringRecipient implementation = new ReconfiguringRecipient(hook);
        vm.etch(CREATOR, address(implementation).code);
        ReconfiguringRecipient receiver = ReconfiguringRecipient(payable(CREATOR));
        _trade(true, true, 100 ether);
        assertEq(receiver.attempts(), 1);
        assertFalse(receiver.configurationSucceeded());
        assertEq(receiver.errorSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hook.maxPriceMoveBps(), 1000);
        router.mintClaims{value: 1 ether}(Currency.wrap(address(0)), 1 ether, address(hook));
        uint256 paidBefore = CREATOR.balance;
        hook.redeemEth();
        assertEq(CREATOR.balance, paidBefore + 1 ether);
        assertEq(receiver.attempts(), 2);
        assertFalse(receiver.configurationSucceeded());
        assertEq(hook.maxPriceMoveBps(), 1000);
        _configure(1, Q96 * 2);
        assertEq(hook.maxPriceMoveBps(), 1, "owner can configure after the external payout returns");
        _assertSettled();
    }
}
