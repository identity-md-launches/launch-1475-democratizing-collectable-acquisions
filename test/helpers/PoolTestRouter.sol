// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Local integration scaffolding. Pulls only the caller's funds before unlocking, then
/// settles from its own balance. No environment, external RPC, or arbitrary decoded payer.
contract PoolTestRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    uint256 public nativeBalanceAtSwap;
    enum Action {
        Liquidity,
        Swap,
        SeedAndSwap,
        DrainAndSwap,
        Claims
    }

    struct Request {
        Action action;
        PoolKey key;
        SwapParams swap;
        ModifyLiquidityParams liquidity;
        PoolKey market;
        uint256 leaveNative;
        Currency claimCurrency;
        uint256 claimAmount;
        address claimRecipient;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }
    receive() external payable {}

    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        uint256 max0,
        uint256 max1
    ) external payable nonReentrant returns (BalanceDelta delta) {
        _pull(key.currency0, max0);
        _pull(key.currency1, max1);
        Request memory r;
        r.action = Action.Liquidity;
        r.key = key;
        r.liquidity = params;
        delta = abi.decode(manager.unlock(abi.encode(r)), (BalanceDelta));
        _refund(key.currency0);
        _refund(key.currency1);
    }

    function swap(PoolKey memory key, SwapParams memory params, uint256 maxInput, uint256 minOutput)
        external
        payable
        nonReentrant
        returns (BalanceDelta delta)
    {
        _pull(params.zeroForOne ? key.currency0 : key.currency1, maxInput);
        Request memory r;
        r.action = Action.Swap;
        r.key = key;
        r.swap = params;
        delta = abi.decode(manager.unlock(abi.encode(r)), (BalanceDelta));
        int128 output = params.zeroForOne ? delta.amount1() : delta.amount0();
        require(output >= 0 && uint256(int256(output)) >= minOutput, "slippage");
        _refund(key.currency0);
        _refund(key.currency1);
    }

    function seedAndSwap(
        PoolKey memory key,
        SwapParams memory params,
        PoolKey memory market,
        ModifyLiquidityParams memory liquidity,
        uint256 max0,
        uint256 max1
    ) external payable nonReentrant returns (BalanceDelta delta) {
        _pull(key.currency0, max0);
        _pull(key.currency1, max1);
        Request memory r;
        r.action = Action.SeedAndSwap;
        r.key = key;
        r.swap = params;
        r.market = market;
        r.liquidity = liquidity;
        delta = abi.decode(manager.unlock(abi.encode(r)), (BalanceDelta));
        _refund(key.currency0);
        _refund(key.currency1);
        _refund(Currency.wrap(address(0)));
    }

    function drainAndSwap(PoolKey memory key, SwapParams memory params, uint256 maxInput, uint256 leaveNative)
        external
        nonReentrant
        returns (BalanceDelta delta)
    {
        _pull(params.zeroForOne ? key.currency0 : key.currency1, maxInput);
        Request memory r;
        r.action = Action.DrainAndSwap;
        r.key = key;
        r.swap = params;
        r.leaveNative = leaveNative;
        delta = abi.decode(manager.unlock(abi.encode(r)), (BalanceDelta));
        _refund(key.currency0);
        _refund(key.currency1);
        _refund(Currency.wrap(address(0)));
    }

    function mintClaims(Currency currency, uint256 amount, address recipient) external payable nonReentrant {
        _pull(currency, amount);
        Request memory r;
        r.action = Action.Claims;
        r.claimCurrency = currency;
        r.claimAmount = amount;
        r.claimRecipient = recipient;
        manager.unlock(abi.encode(r));
        _refund(currency);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        Request memory r = abi.decode(data, (Request));
        if (r.action == Action.Claims) {
            manager.mint(r.claimRecipient, r.claimCurrency.toId(), r.claimAmount);
            _settle(r.claimCurrency);
            return "";
        }
        BalanceDelta delta;
        if (r.action == Action.Liquidity) {
            (delta,) = manager.modifyLiquidity(r.key, r.liquidity, "");
        } else {
            if (r.action == Action.SeedAndSwap) manager.modifyLiquidity(r.market, r.liquidity, "");
            if (r.action == Action.DrainAndSwap) {
                manager.take(
                    Currency.wrap(address(0)), address(this), address(manager).balance - r.leaveNative
                );
            }
            nativeBalanceAtSwap = address(manager).balance;
            delta = manager.swap(r.key, r.swap, "");
        }
        _settle(r.key.currency0);
        _settle(r.key.currency1);
        if (r.action == Action.SeedAndSwap || r.action == Action.DrainAndSwap) {
            _settle(Currency.wrap(address(0)));
        }
        return abi.encode(delta);
    }

    function _pull(Currency currency, uint256 amount) private {
        if (currency.isAddressZero()) {
            require(msg.value >= amount, "native budget");
        } else if (amount != 0) {
            IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        } else if (delta < 0) {
            uint256 debt = uint256(-delta);
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: debt}();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), debt);
                manager.settle();
            }
        }
    }

    function _refund(Currency currency) private {
        uint256 balance = currency.balanceOfSelf();
        if (balance != 0) currency.transfer(msg.sender, balance);
    }
}
