// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DCAToken} from "../src/DCAToken.sol";

contract TokenTest is Test {
    DCAToken internal token;
    address internal alice;
    address internal bob;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new DCAToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_metadataAndPolicySupply() public view {
        assertEq(token.name(), "Democratizing Collectable Acquisitions");
        assertEq(token.symbol(), "DCA");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_mintsToFactoryRatherThanTransactionOrigin() public {
        vm.prank(alice, bob);
        DCAToken deployed = new DCAToken();
        assertEq(deployed.balanceOf(alice), SUPPLY);
        assertEq(deployed.balanceOf(bob), 0);
    }

    function testFuzz_transferConservesSupplyAndChargesNoFee(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
        vm.prank(alice);
        token.transfer(address(this), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_approvedTransferAndAllowance() public {
        token.approve(alice, 42 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 40 ether));
        assertEq(token.allowance(address(this), alice), 2 ether);
        assertEq(token.balanceOf(bob), 40 ether);
    }

    function test_insufficientAllowanceRevertsWithoutMovingFunds() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1 ether)
        );
        token.transferFrom(address(this), bob, 1 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_insufficientBalanceAndZeroRecipientRevert() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_noMintPauseFeeOrUpgradeEntryPointEvenForDeployer() public {
        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether);
        calls[1] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[2] = abi.encodeWithSignature("setFee(uint256)", 1000);
        calls[3] = abi.encodeWithSignature("pause()");
        calls[4] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[5] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[6] = abi.encodeWithSignature("initialize(address)", alice);
        calls[7] = abi.encodeWithSignature("setMinter(address)", alice);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
            vm.prank(alice);
            (ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_runtimeHasNoEscapeOpcodes() public view {
        bytes memory code = address(token).code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff);
        }
    }
}
