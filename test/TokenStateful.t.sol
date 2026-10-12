// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DCAToken} from "src/DCAToken.sol";

/// @dev A closed set of four holders allows the invariant to count every token and every
/// allowance. Ghost state follows requested ERC-20 operations, never the token's return values.
contract DCATokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    DCAToken public immutable token;
    address[4] public actors;
    uint256[4] public expectedBalance;
    uint256[4][4] public expectedAllowance;

    constructor(DCAToken token_) {
        token = token_;
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("DCA holder ", vm.toString(i)));
            expectedBalance[i] = SUPPLY / 4;
        }
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 raw) external {
        uint256 from = fromSeed % 4;
        _transfer(from, toSeed % 4, bound(raw, 0, expectedBalance[from]));
    }

    function transferEntireBalance(uint8 fromSeed, uint8 toSeed) external {
        uint256 from = fromSeed % 4;
        _transfer(from, toSeed % 4, expectedBalance[from]);
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 raw, bool infinite) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 amount = infinite ? type(uint256).max : bound(raw, 0, SUPPLY);
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint8 fromSeed, uint8 spenderSeed, uint8 toSeed, uint256 raw) external {
        uint256 from = fromSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 to = toSeed % 4;
        uint256 allowance = expectedAllowance[from][spender];
        uint256 limit = expectedBalance[from] < allowance ? expectedBalance[from] : allowance;
        uint256 amount = bound(raw, 0, limit);
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[from], actors[to], amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) expectedAllowance[from][spender] -= amount;
    }

    function rejectInvalidTransfer(uint8 fromSeed, uint8 toSeed, bool zeroRecipient) external {
        uint256 from = fromSeed % 4;
        uint256 balance = expectedBalance[from];
        vm.prank(actors[from]);
        if (zeroRecipient) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(address(0), 0);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, actors[from], balance, balance + 1
                )
            );
            token.transfer(actors[toSeed % 4], balance + 1);
        }
    }

    function rejectAllowanceOverspend(uint8 fromSeed, uint8 spenderSeed, uint8 toSeed, uint256 raw) external {
        uint256 from = fromSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 allowance = bound(raw, 0, SUPPLY);
        vm.prank(actors[from]);
        token.approve(actors[spender], allowance);
        expectedAllowance[from][spender] = allowance;
        vm.prank(actors[spender]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, actors[spender], allowance, allowance + 1
            )
        );
        token.transferFrom(actors[from], actors[toSeed % 4], allowance + 1);
    }

    function _transfer(uint256 from, uint256 to, uint256 amount) private {
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TokenStatefulTest is Test {
    DCAToken internal token;
    DCATokenHandler internal handler;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new DCAToken();
        handler = new DCATokenHandler(token);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), SUPPLY / 4);
        }
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferEntireBalance.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.transferFrom.selector;
        selectors[4] = handler.rejectInvalidTransfer.selector;
        selectors[5] = handler.rejectAllowanceOverspend.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_balancesMatchRequestedTransfersAndFixedSupply() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            uint256 balance = token.balanceOf(handler.actors(i));
            assertEq(balance, handler.expectedBalance(i), "no loss, tax, or unauthorized transfer");
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function invariant_onlyApprovalAndSuccessfulDelegatedTransfersChangeAllowances() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                assertEq(
                    token.allowance(handler.actors(i), handler.actors(j)), handler.expectedAllowance(i, j)
                );
            }
        }
    }

    function test_sequenceExhaustRevokeReapproveAndSelfTransfer() public {
        handler.approve(0, 1, 100, false);
        handler.transferFrom(0, 1, 2, 100);
        assertEq(token.allowance(handler.actors(0), handler.actors(1)), 0);
        handler.approve(0, 1, 0, false);
        handler.rejectAllowanceOverspend(0, 1, 2, 0);
        handler.approve(0, 1, 0, true);
        handler.transferFrom(0, 1, 0, 100);
        handler.transferEntireBalance(0, 2);
        handler.transferEntireBalance(2, 3);
        handler.transferEntireBalance(3, 0);
        invariant_balancesMatchRequestedTransfersAndFixedSupply();
        invariant_onlyApprovalAndSuccessfulDelegatedTransfersChangeAllowances();
    }

    function test_failedTransferFromRestoresAllowanceAfterBalanceCheck() public {
        address owner = handler.actors(0);
        address spender = handler.actors(1);
        address recipient = handler.actors(2);
        uint256 amount = SUPPLY / 4 + 1;
        vm.prank(owner);
        token.approve(spender, amount);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, SUPPLY / 4, amount)
        );
        token.transferFrom(owner, recipient, amount);
        assertEq(token.allowance(owner, spender), amount, "revert must undo allowance spending");
        invariant_balancesMatchRequestedTransfersAndFixedSupply();
    }

    function test_failedTransferFromToZeroRestoresAllowance() public {
        address owner = handler.actors(0);
        address spender = handler.actors(1);
        vm.prank(owner);
        token.approve(spender, 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(owner, address(0), 1);
        assertEq(token.allowance(owner, spender), 1);
        invariant_balancesMatchRequestedTransfersAndFixedSupply();
    }

    function test_zeroSpenderApprovalIsRejected() public {
        address owner = handler.actors(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), type(uint256).max);
        assertEq(token.allowance(owner, address(0)), 0);
        invariant_balancesMatchRequestedTransfersAndFixedSupply();
    }
}
