// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Models the verified FWA transfer guard: a transfer succeeds only when it is a mint or burn,
/// one side is a distributor, one side is the token owner, or one side is the PoolManager and a
/// transient allowance (slot 0, bumped only by FWA's own hook in production) covers the amount.
/// Everything else, including any transfer to the launch hook, reverts InvalidTransfer.
/// The deployer of the template is the exempt owner; storage is set after `vm.etch`.
contract MockERC20 is ERC20 {
    address public immutable guardOwner;
    address public poolManager;
    mapping(address => bool) public isDistributor;

    error InvalidTransfer();

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        guardOwner = msg.sender;
        _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPoolManager(address manager) external {
        poolManager = manager;
    }

    function setDistributor(address account, bool allowed) external {
        isDistributor[account] = allowed;
    }

    /// @dev In production only FWA's own hook may call this, and only for its own ETH/FWA pool.
    function increaseTransferAllowance(uint256 amount) external {
        assembly {
            tstore(0, add(tload(0), amount))
        }
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && !isDistributor[from] && !isDistributor[to]) {
            if (from != guardOwner && to != guardOwner) {
                address manager = poolManager;
                if (manager == address(0) || (from != manager && to != manager)) revert InvalidTransfer();
                uint256 allowance;
                assembly {
                    allowance := tload(0)
                }
                if (allowance < value) revert InvalidTransfer();
                assembly {
                    tstore(0, sub(allowance, value))
                }
            }
        }
        super._update(from, to, value);
    }
}
