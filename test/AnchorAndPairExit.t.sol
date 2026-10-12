// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {HookDeployer} from "./helpers/HookDeployer.sol";
import {DCAHook} from "../src/DCAHook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice The conversion anchor across blocks under manipulation, and the owner's FWA exit:
/// who it pays, how it chunks, and that it never touches the ETH side.
contract AnchorAndPairExitTest is HookFixture, IUnlockCallback {
    using StateLibrary for IPoolManager;

    uint256 internal constant CHUNK = uint256(uint128(type(int128).max));
    bool private nestedExitSucceeded;
    bytes private nestedExitError;

    function setUp() public {
        _deploy(true, true, true);
    }

    function _spot() internal view returns (uint160 price) {
        (price,,,) = manager.getSlot0(market.toId());
    }

    function _factor(uint16 bps) internal pure returns (uint256) {
        return Math.sqrt((10_000 + uint256(bps)) * 1e18 / 10_000);
    }

    /// @dev Pushes sqrt(FWA/ETH) up to `target` by selling FWA, as a manipulator would.
    function _pushUpTo(uint160 target) internal {
        router.swap(market, SwapParams(false, -500_000 ether, target), 500_000 ether, 0);
        assertEq(_spot(), target);
    }

    /// @dev A move that landed in an earlier block is not trusted until a later attempt observes it:
    /// the first trade after the move defers, the next block sells from the promoted anchor and
    /// stays within the bound measured from it.
    function test_moveInAnEarlierBlockDefersOnceThenPromotesTheObservedPrice() public {
        // The anchor is the spot an attempt sees before its own sale, not the price it leaves.
        uint160 observed = _spot();
        Outcome memory first = _trade(true, true, 100 ether);
        assertGt(first.spent, 0);
        assertGt(_spot(), observed);
        vm.roll(vm.getBlockNumber() + 1);
        _pushUpTo(uint160(uint256(observed) * 112 / 100));
        uint160 moved = _spot();
        vm.roll(vm.getBlockNumber() + 1);
        Outcome memory deferred = _trade(true, true, 100 ether);
        assertEq(deferred.spent, 0, "a 12% move above the anchor defers even from an earlier block");
        assertEq(hook.anchorSqrtPriceX96(), observed, "anchor is the price the last attempt saw");
        assertEq(hook.observedSqrtPriceX96(), moved);
        assertEq(deferred.pending, first.fee + deferred.fee - first.spent);
        vm.roll(vm.getBlockNumber() + 1);
        Outcome memory sold = _trade(true, true, 100 ether);
        assertEq(hook.anchorSqrtPriceX96(), moved, "the next block promotes the observed price");
        assertEq(sold.spent, sold.fee + deferred.pending, "backlog within the cap sells with the fee");
        assertLe(uint256(_spot()), FullMath.mulDiv(moved, _factor(1000), 1e9));
        _assertSettled();
    }

    /// @dev A spot below the anchor becomes the base, so the sale cannot ride the stale higher anchor.
    function test_loweredSpotTightensTheBoundToSpot() public {
        uint160 anchor = _spot();
        _trade(true, true, 100 ether);
        assertEq(hook.anchorSqrtPriceX96(), anchor);
        // Buy FWA with ETH: sqrt(FWA/ETH) falls by about a third.
        router.swap{value: 60_000 ether}(
            market, SwapParams(true, -60_000 ether, TickMath.MIN_SQRT_PRICE + 1), 60_000 ether, 0
        );
        uint160 lowered = _spot();
        assertLt(uint256(lowered), uint256(anchor) * 8 / 10);
        // Enough backlog that an unbounded sale would move the price past the tightened bound.
        router.mintClaims(Currency.wrap(FWA), 100_000 ether, address(hook));
        Outcome memory o = _trade(true, true, 100_000 ether);
        assertGt(o.spent, 0);
        assertEq(hook.anchorSqrtPriceX96(), anchor, "the anchor itself is unchanged within the block");
        uint256 bound = FullMath.mulDiv(lowered, _factor(1000), 1e9);
        assertLe(uint256(_spot()), bound, "the sale is bounded from the lowered spot, not the anchor");
        assertGt(uint256(_spot()), bound * 999 / 1000, "the sale actually reached the tightened bound");
        assertGt(o.pending, 0, "the rest waits for later blocks");
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 400
    /// @dev Whatever the owner's bound, a same-block move in either direction before or after a
    /// trade, and however many blocks pass, every sale ends at or below the bound from the anchor
    /// the hook promoted in an earlier block and below the absolute ceiling.
    function testFuzz_saleNeverPassesTheBoundFromTheAnchor(
        uint16 rawBps,
        uint96 rawMove,
        bool pushUp,
        bool moveBeforeRoll
    ) public {
        uint16 bps = uint16(bound(uint256(rawBps), 1, 1000));
        uint160 ceiling = uint160(uint256(Q96) * 13 / 10);
        _configure(bps, ceiling);
        router.mintClaims(Currency.wrap(FWA), 50_000 ether, address(hook));
        _checkedTrade(bps, ceiling);
        if (!moveBeforeRoll) vm.roll(vm.getBlockNumber() + 1);
        if (pushUp) {
            uint256 amount = bound(uint256(rawMove), 1 ether, 60_000 ether);
            router.swap(market, SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1), amount, 0);
        } else {
            uint256 amount = bound(uint256(rawMove), 0.01 ether, 30 ether);
            router.swap{value: amount}(
                market, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1), amount, 0
            );
        }
        _checkedTrade(bps, ceiling);
        vm.roll(vm.getBlockNumber() + 1);
        _checkedTrade(bps, ceiling);
        vm.roll(vm.getBlockNumber() + 1);
        _checkedTrade(bps, ceiling);
        _assertSettled();
    }

    function _checkedTrade(uint16 bps, uint160 ceiling) internal {
        uint160 spotBefore = _spot();
        uint256 claimsBefore = manager.balanceOf(address(hook), uint160(FWA));
        uint256 ethBefore = CREATOR.balance + manager.balanceOf(address(hook), 0);
        Outcome memory o = _trade(true, true, 10_000 ether);
        _assertAccounting(o, claimsBefore, ethBefore);
        uint160 spotAfter = _spot();
        if (spotAfter == spotBefore && o.spent == 0) return;
        // The hook touched the market: only within the owner's bounds, measured from an anchor
        // promoted in an earlier block, and never from a spot already at the ceiling.
        uint256 anchor = hook.anchorSqrtPriceX96();
        assertGt(anchor, 0, "the market moved without an earlier-block anchor");
        assertGe(spotAfter, spotBefore, "a sale only raises sqrt(FWA/ETH)");
        assertLe(uint256(spotAfter), FullMath.mulDiv(anchor, _factor(bps), 1e9), "past the relative bound");
        assertLe(uint256(spotAfter), uint256(ceiling), "past the absolute ceiling");
        assertLt(uint256(spotBefore), uint256(ceiling), "sold at or above the ceiling");
    }

    function test_reconfigurationResetsTheAnchorAndRestartsObservation() public {
        _trade(true, true, 100 ether);
        assertGt(hook.anchorSqrtPriceX96(), 0);
        vm.roll(vm.getBlockNumber() + 3);
        vm.prank(CREATOR);
        hook.setConversionPool(market, 500, Q96 * 2);
        assertEq(hook.anchorSqrtPriceX96(), 0);
        assertEq(hook.observedSqrtPriceX96(), _spot());
        assertEq(hook.observedBlock(), vm.getBlockNumber());
        Outcome memory same = _trade(true, true, 100 ether);
        assertEq(same.spent, 0, "no sale in the configuration block");
        assertEq(hook.anchorSqrtPriceX96(), 0);
        vm.roll(vm.getBlockNumber() + 1);
        uint160 promoted = _spot();
        Outcome memory next = _trade(true, true, 100 ether);
        assertEq(hook.anchorSqrtPriceX96(), promoted);
        assertEq(next.spent, next.fee + same.fee);
        assertLe(uint256(_spot()), FullMath.mulDiv(promoted, _factor(500), 1e9));
        _assertSettled();
    }

    /// @dev Owner and recipient are different addresses here. The owner's exit still pays the fixed
    /// recipient, the recipient cannot configure, and the owner receives nothing on either side.
    function test_pairExitPaysTheRecipientNotTheOwner() public {
        address owner = makeAddr("separate owner");
        DCAHook separate = DCAHook(
            HookDeployer.deploy(
                abi.encodePacked(
                    type(DCAHook).creationCode, abi.encode(manager, address(token), address(this), owner)
                )
            )
        );
        PoolKey memory separateKey = key;
        separateKey.hooks = IHooks(address(separate));
        manager.initialize(separateKey, Q96);
        router.modifyLiquidity(separateKey, _liquidity(MAIN_LIQUIDITY), MAIN_LIQUIDITY, MAIN_LIQUIDITY);
        vm.prank(CREATOR);
        vm.expectRevert(DCAHook.OnlyOwner.selector);
        separate.setConversionPool(market, 1000, Q96 * 2);
        vm.prank(owner);
        separate.setConversionPool(market, 1000, Q96 * 2);
        // Same block as the configuration: the sale is deferred, so FWA accrues as claims.
        router.swap(separateKey, _params(true, true, 100 ether), 100 ether, 0);
        uint256 claims = manager.balanceOf(address(separate), uint160(FWA));
        assertEq(claims, 5 ether);
        vm.prank(CREATOR);
        vm.expectRevert(DCAHook.OnlyOwner.selector);
        separate.redeemPair();
        pair.setDistributor(CREATOR, true);
        pair.setDistributor(owner, true);
        vm.prank(owner);
        separate.redeemPair();
        assertEq(pair.balanceOf(CREATOR), claims, "FWA went to the recipient");
        assertEq(pair.balanceOf(owner), 0, "the owner gets no FWA");
        assertEq(manager.balanceOf(address(separate), uint160(FWA)), 0);
        // ETH side: the next block converts and pays the recipient, never the owner.
        vm.roll(vm.getBlockNumber() + 1);
        router.swap(separateKey, _params(true, true, 100 ether), 100 ether, 0);
        assertGt(CREATOR.balance, 0);
        assertEq(owner.balance, 0);
        assertEq(separate.RECIPIENT(), CREATOR);
        assertEq(separate.owner(), owner);
        _assertSettled();
    }

    function test_pairExitChunksAboveInt128AndStopsWhenEmpty() public {
        pair.mint(address(this), 3 * CHUNK);
        pair.approve(address(router), type(uint256).max);
        router.mintClaims(Currency.wrap(FWA), CHUNK, address(hook));
        router.mintClaims(Currency.wrap(FWA), CHUNK, address(hook));
        router.mintClaims(Currency.wrap(FWA), 17, address(hook));
        uint256 total = 2 * CHUNK + 17;
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), total);
        pair.setDistributor(CREATOR, true);
        for (uint256 i; i < 3; ++i) {
            vm.prank(CREATOR);
            hook.redeemPair();
            uint256 expected = i == 0 ? CHUNK : (i == 1 ? 2 * CHUNK : total);
            assertEq(pair.balanceOf(CREATOR), expected);
            assertEq(manager.balanceOf(address(hook), uint160(FWA)), total - expected);
            _assertSettled();
        }
        vm.prank(CREATOR);
        vm.expectRevert(DCAHook.NothingToRedeem.selector);
        hook.redeemPair();
        assertEq(pair.balanceOf(address(hook)), 0);
    }

    /// @dev Both claim kinds outstanding: each exit moves only its own currency, a nested exit from
    /// inside another unlock is refused without leaving an authorization behind, and the next ETH
    /// redemption still pays ETH rather than FWA.
    function test_pairAndEthExitsAreIsolatedAndNestedExitIsRefused() public {
        _configure(1000, Q96);
        Outcome memory o = _trade(true, true, 100 ether);
        router.mintClaims{value: 3 ether}(Currency.wrap(address(0)), 3 ether, address(hook));
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), o.fee);
        assertEq(manager.balanceOf(address(hook), 0), 3 ether);
        pair.setDistributor(CREATOR, true);

        manager.unlock("");
        assertFalse(nestedExitSucceeded, "owner exit ran inside a foreign unlock");
        assertEq(nestedExitError, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), o.fee);
        assertEq(manager.balanceOf(address(hook), 0), 3 ether);
        vm.prank(address(manager));
        vm.expectRevert(DCAHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");

        hook.redeemEth();
        assertEq(CREATOR.balance, 3 ether, "ETH exit pays ETH");
        assertEq(pair.balanceOf(CREATOR), 0, "ETH exit moves no FWA");
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), o.fee, "ETH exit leaves FWA claims");
        assertEq(manager.balanceOf(address(hook), 0), 0);

        router.mintClaims{value: 1 ether}(Currency.wrap(address(0)), 1 ether, address(hook));
        vm.prank(CREATOR);
        hook.redeemPair();
        assertEq(pair.balanceOf(CREATOR), o.fee, "FWA exit pays FWA");
        assertEq(CREATOR.balance, 3 ether, "FWA exit moves no ETH");
        assertEq(manager.balanceOf(address(hook), 0), 1 ether, "FWA exit leaves ETH claims");
        assertEq(manager.balanceOf(address(hook), uint160(FWA)), 0);
        _assertSettled();
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        vm.prank(CREATOR);
        (nestedExitSucceeded, nestedExitError) = address(hook).call(abi.encodeCall(DCAHook.redeemPair, ()));
        return "";
    }
}
