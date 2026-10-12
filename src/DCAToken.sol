// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply launch token. Swap fees live exclusively in the hook.
/// @dev The name is the brief's exact spelling, "Acquisions", not a corrected one.
contract DCAToken is ERC20 {
    constructor() ERC20("Democratizing Collectable Acquisions", "DCA") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
