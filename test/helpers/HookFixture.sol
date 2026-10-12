// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {DCAToken} from "../../src/DCAToken.sol";
import {DCAHook} from "../../src/DCAHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {HookDeployer} from "./HookDeployer.sol";
import {PoolTestRouter} from "./PoolTestRouter.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address internal constant CREATOR = 0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d;
    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint256 internal constant MAIN_LIQUIDITY = 1_000_000 ether;
    uint256 internal constant MARKET_LIQUIDITY = 100_000 ether;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant FEE_TOPIC = keccak256("FeeCharged(bytes32,bool,uint256,uint256)");
    bytes32 internal constant CONVERSION_TOPIC = keccak256("FeeConverted(uint256,uint256,uint256)");

    IPoolManager internal manager;
    DCAToken internal token;
    MockERC20 internal pair;
    DCAHook internal hook;
    PoolTestRouter internal router;
    PoolKey internal key;
    PoolKey internal market;

    struct Outcome {
        BalanceDelta userDelta;
        int128 rawPair;
        int128 rawToken;
        uint256 fee;
        uint256 gross;
        uint256 spent;
        uint256 ethOut;
        uint256 pending;
        bool buy;
    }

    receive() external payable {}

    function _deploy(bool fundMarket, bool configure, bool tokenBelowPair) internal {
        vm.deal(address(this), 10_000_000 ether);
        manager = IPoolManager(address(new PoolManager(address(this))));
        for (uint256 i; i < 100; i++) {
            token = new DCAToken();
            if ((address(token) < FWA) == tokenBelowPair) break;
        }
        assertEq(address(token) < FWA, tokenBelowPair);
        if (FWA.code.length == 0) vm.etch(FWA, address(new MockERC20("FWA", "FWA", 0)).code);
        pair = MockERC20(FWA);
        pair.mint(address(this), 1_000_000_000 ether);
        hook = DCAHook(
            HookDeployer.deploy(
                abi.encodePacked(
                    type(DCAHook).creationCode, abi.encode(manager, address(token), address(this), CREATOR)
                )
            )
        );
        router = new PoolTestRouter(manager);
        key = PoolKey({
            currency0: Currency.wrap(tokenBelowPair ? address(token) : FWA),
            currency1: Currency.wrap(tokenBelowPair ? FWA : address(token)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        market = PoolKey(Currency.wrap(address(0)), Currency.wrap(FWA), 3000, 60, IHooks(address(0)));
        manager.initialize(key, Q96);
        manager.initialize(market, Q96);
        token.approve(address(router), type(uint256).max);
        pair.approve(address(router), type(uint256).max);
        router.modifyLiquidity(key, _liquidity(MAIN_LIQUIDITY), MAIN_LIQUIDITY, MAIN_LIQUIDITY);
        if (fundMarket) _fundMarket();
        if (configure) _configure(1000, Q96 * 2);
        // Model FWA's restriction: any attempt to withdraw fee FWA to the hook fails.
        pair.setBlockedRecipient(address(hook));
    }

    function _fundMarket() internal {
        router.modifyLiquidity{value: MARKET_LIQUIDITY}(
            market, _liquidity(MARKET_LIQUIDITY), MARKET_LIQUIDITY, MARKET_LIQUIDITY
        );
    }

    function _configure(uint16 moveBps, uint160 ceiling) internal {
        vm.prank(CREATOR);
        hook.setConversionPool(market, moveBps, ceiling);
    }

    function _liquidity(uint256 amount) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(-60_000, 60_000, int256(amount), bytes32(0));
    }

    function _params(bool buy, bool exactInput, uint256 amount) internal view returns (SwapParams memory p) {
        p.zeroForOne = buy == (Currency.unwrap(key.currency0) == FWA);
        p.amountSpecified = exactInput ? -int256(amount) : int256(amount);
        p.sqrtPriceLimitX96 = p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _trade(bool buy, bool exactInput, uint256 amount) internal returns (Outcome memory result) {
        vm.recordLogs();
        BalanceDelta delta = router.swap(key, _params(buy, exactInput, amount), amount * 4 + 100, 0);
        result = _outcome(vm.getRecordedLogs(), delta);
    }

    function _outcome(Vm.Log[] memory logs, BalanceDelta delta) internal view returns (Outcome memory o) {
        o.userDelta = delta;
        bool foundFee;
        bool foundSwap;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == FEE_TOPIC && logs[i].emitter == address(hook)) {
                (o.buy, o.gross, o.fee) = abi.decode(logs[i].data, (bool, uint256, uint256));
                foundFee = true;
            } else if (logs[i].topics[0] == CONVERSION_TOPIC && logs[i].emitter == address(hook)) {
                (o.spent, o.ethOut, o.pending) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            } else if (
                logs[i].topics[0] == SWAP_TOPIC && logs[i].emitter == address(manager)
                    && logs[i].topics[1] == PoolId.unwrap(key.toId())
            ) {
                (int128 a0, int128 a1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                o.rawPair = Currency.unwrap(key.currency0) == FWA ? a0 : a1;
                o.rawToken = Currency.unwrap(key.currency0) == FWA ? a1 : a0;
                foundSwap = true;
            }
        }
        require(foundFee && foundSwap, "expected fee and real swap logs");
    }

    function _pairDelta(BalanceDelta delta) internal view returns (int128) {
        return Currency.unwrap(key.currency0) == FWA ? delta.amount0() : delta.amount1();
    }

    function _tokenDelta(BalanceDelta delta) internal view returns (int128) {
        return Currency.unwrap(key.currency0) == FWA ? delta.amount1() : delta.amount0();
    }

    function _assertAccounting(Outcome memory o, uint256 claimsBefore, uint256 creatorBefore) internal view {
        assertEq(int256(_pairDelta(o.userDelta)), int256(o.rawPair) - int256(o.fee), "pair fee delta");
        assertEq(_tokenDelta(o.userDelta), o.rawToken, "no fee on DCA");
        assertEq(o.fee, o.gross / 20, "five percent of gross FWA");
        assertEq(
            claimsBefore + o.fee, o.spent + manager.balanceOf(address(hook), uint160(FWA)), "FWA conserved"
        );
        assertEq(
            CREATOR.balance + manager.balanceOf(address(hook), 0), creatorBefore + o.ethOut, "ETH conserved"
        );
        assertEq(pair.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        _assertSettled();
    }

    function _assertSettled() internal view {
        assertEq(manager.getNonzeroDeltaCount(), 0, "all participants settled");
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(FWA)), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(token))), 0);
        assertFalse(manager.isUnlocked());
    }
}
