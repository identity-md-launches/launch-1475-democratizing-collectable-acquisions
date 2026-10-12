// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DCAHook} from "../src/DCAHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline CREATE2 salt finder. Takes explicit deployment parameters, does not broadcast,
/// read environment variables, use a private key, or deploy either launch contract.
contract MineHook {
    error InvalidSearch();
    error SaltNotFound();

    function run(
        address create2Deployer,
        IPoolManager manager,
        address token,
        address factory,
        address owner,
        uint256 startSalt,
        uint256 attempts
    ) external pure returns (bytes32 salt, address predicted, bytes32 initCodeHash) {
        if (
            create2Deployer == address(0) || address(manager) == address(0) || token == address(0)
                || factory == address(0) || owner == address(0) || attempts == 0 || attempts > 1_000_000
                || startSalt > type(uint256).max - attempts
        ) revert InvalidSearch();
        initCodeHash = keccak256(
            abi.encodePacked(type(DCAHook).creationCode, abi.encode(manager, token, factory, owner))
        );
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(startSalt + i);
            predicted = computeAddress(create2Deployer, salt, initCodeHash);
            if (HookFlags.matches(predicted, HookFlags.DCA)) return (salt, predicted, initCodeHash);
        }
        revert SaltNotFound();
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        public
        pure
        returns (address)
    {
        // CREATE2 intentionally uses the low 160 bits of this hash.
        // forge-lint: disable-next-line(unsafe-typecast)
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
