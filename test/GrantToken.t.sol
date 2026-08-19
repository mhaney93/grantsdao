// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/GrantToken.sol";
import "../interfaces/IGrantToken.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

contract GrantTokenTest is Test {
    GrantToken token;

    address admin = makeAddr("admin");
    address minter = makeAddr("minter");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new GrantToken(admin);
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.grantRole(minterRole, minter);
    }

    function test_mint_byMinter_succeeds() public {
        vm.prank(minter);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_mint_byNonMinter_reverts() public {
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, minterRole)
        );
        token.mint(alice, 100e18);
    }

    function test_transfer_isForbidden() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(IGrantToken.SoulboundTransferForbidden.selector);
        token.transfer(bob, 1e18);
    }

    function test_transferFrom_isForbidden() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.approve(bob, 1e18);

        vm.prank(bob);
        vm.expectRevert(IGrantToken.SoulboundTransferForbidden.selector);
        token.transferFrom(alice, bob, 1e18);
    }

    function test_delegate_worksNormally() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.delegate(alice);

        assertEq(token.getVotes(alice), 100e18);
    }

    function test_getPastVotes_afterCheckpoint() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.delegate(alice);

        uint256 b0 = block.number;
        vm.roll(b0 + 1);

        assertEq(token.getPastVotes(alice, b0), 100e18);
    }

    function test_mint_withoutDelegation_hasNoVotingPower() public {
        vm.prank(minter);
        token.mint(alice, 100e18);
        // votes are only counted after explicit delegation
        assertEq(token.getVotes(alice), 0);
    }
}
