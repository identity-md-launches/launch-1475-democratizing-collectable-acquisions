// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "../../src/HookFlags.sol";

library HookDeployer {
    function mine(address deployer, bytes memory initCode)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 hash = keccak256(initCode);
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, hash)))));
            if (HookFlags.matches(predicted, HookFlags.DCA)) return (salt, predicted);
        }
        revert("salt search exhausted");
    }

    function deploy(bytes memory initCode) internal returns (address hook) {
        (bytes32 salt, address predicted) = mine(address(this), initCode);
        assembly ("memory-safe") { hook := create2(0, add(initCode, 32), mload(initCode), salt) }
        require(hook == predicted && hook.code.length != 0, "hook deployment failed");
    }
}
