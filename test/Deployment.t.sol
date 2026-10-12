// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MineHook} from "../script/MineHook.s.sol";
import {DCAHook} from "../src/DCAHook.sol";
import {DCAToken} from "../src/DCAToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract DeploymentTest is Test {
    function test_saltFinderDeploysActualCreationCodeAndFactoryInitializes() public {
        MineHook miner = new MineHook();
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));
        DCAToken token = new DCAToken();
        address creator = 0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d;
        (bytes32 salt, address predicted, bytes32 initHash) =
            miner.run(address(this), manager, address(token), address(this), creator, 0, 200_000);
        assertTrue(HookFlags.matches(predicted, HookFlags.DCA));
        assertEq(
            initHash,
            keccak256(
                abi.encodePacked(
                    type(DCAHook).creationCode, abi.encode(manager, address(token), address(this), creator)
                )
            )
        );
        DCAHook hook = new DCAHook{salt: salt}(manager, address(token), address(this), creator);
        assertEq(address(hook), predicted);
        address pair = hook.PAIRED_TOKEN();
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token) < pair ? address(token) : pair),
            currency1: Currency.wrap(address(token) < pair ? pair : address(token)),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, 79228162514264337593543950336);
        assertTrue(hook.initialized());
        assertFalse(hook.conversionConfigured());
    }

    function test_saltFinderRejectsInvalidSearchRatherThanGuessingAddresses() public {
        MineHook miner = new MineHook();
        IPoolManager manager = IPoolManager(makeAddr("manager"));
        address token = makeAddr("token");
        address owner = makeAddr("owner");
        vm.expectRevert(MineHook.InvalidSearch.selector);
        miner.run(address(0), manager, token, address(this), owner, 0, 100);
        vm.expectRevert(MineHook.InvalidSearch.selector);
        miner.run(address(this), manager, token, address(this), owner, 0, 0);
        vm.expectRevert(MineHook.InvalidSearch.selector);
        miner.run(address(this), manager, token, address(this), owner, type(uint256).max, 1);
        vm.expectRevert(MineHook.InvalidSearch.selector);
        miner.run(address(this), manager, token, address(this), owner, 0, 1_000_001);
    }
}
