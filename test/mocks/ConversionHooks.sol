// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {DCAHook} from "../../src/DCAHook.sol";

contract ReentrantConversionHook {
    IPoolManager private immutable manager;
    DCAHook private immutable hook;
    PoolKey private launchKey;
    uint256 public attempts;
    uint256 public unexpectedSuccesses;

    constructor(IPoolManager manager_, DCAHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function setLaunchKey(PoolKey calldata key) external {
        launchKey = key;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(msg.sender == address(manager), "manager only");
        ++attempts;
        (bool ok,) = address(hook).call(abi.encodeCall(DCAHook.redeemEth, ()));
        if (ok) ++unexpectedSuccesses;
        try manager.swap(launchKey, SwapParams(true, -1 ether, 4295128740), "") {
            ++unexpectedSuccesses;
        } catch {}
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
}

/// @dev A market whose hook refuses every swap: the launch hook must fall back to claims.
contract RevertingConversionHook {
    error MarketClosed();

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert MarketClosed();
    }
}

/// @dev A market whose hook burns every unit of gas it is given.
contract GasBurningConversionHook {
    uint256 private sink;

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        while (true) sink += 1;
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
}

contract NegativeOutputConversionHook {
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        require(msg.sender == address(manager), "manager only");
        // Charges twice the native output: accounting balances, but leaves the swap caller owing ETH.
        int128 excessiveFee = delta.amount0() * 2;
        manager.mint(address(this), 0, uint256(int256(excessiveFee)));
        return (IHooks.afterSwap.selector, excessiveFee);
    }
}
