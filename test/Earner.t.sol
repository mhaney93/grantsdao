// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/Earner.sol";
import "../contracts/GrantToken.sol";
import "../interfaces/IEarner.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

contract EarnerTest is Test {
    GrantToken token;
    Earner earner;

    address admin = makeAddr("admin");
    address recorder = makeAddr("recorder");
    address alice = makeAddr("alice");

    function setUp() public {
        token = new GrantToken(admin);
        earner = new Earner(admin, address(token));

        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), address(earner));
        earner.grantRole(earner.RECORDER_ROLE(), recorder);
        vm.stopPrank();
    }

    function test_defaultRewards() public view {
        assertEq(earner.rewardFor(IEarner.Action.Voted), 10e18);
        assertEq(earner.rewardFor(IEarner.Action.ProposalSubmitted), 50e18);
        assertEq(earner.rewardFor(IEarner.Action.MilestoneApproved), 25e18);
        assertEq(earner.rewardFor(IEarner.Action.Seeded), 10e18);
    }

    function test_recordAction_mintsReward() public {
        vm.prank(recorder);
        earner.recordAction(alice, 1, IEarner.Action.Voted);

        assertEq(token.balanceOf(alice), 10e18);
    }

    function test_recordAction_byNonRecorder_reverts() public {
        bytes32 recorderRole = earner.RECORDER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, recorderRole)
        );
        earner.recordAction(alice, 1, IEarner.Action.Voted);
    }

    function test_recordAction_sameTripleTwice_reverts() public {
        vm.startPrank(recorder);
        earner.recordAction(alice, 1, IEarner.Action.Voted);

        vm.expectRevert(abi.encodeWithSelector(IEarner.AlreadyRecorded.selector, alice, 1, IEarner.Action.Voted));
        earner.recordAction(alice, 1, IEarner.Action.Voted);
        vm.stopPrank();
    }

    function test_recordAction_differentProposalId_succeedsAgain() public {
        vm.startPrank(recorder);
        earner.recordAction(alice, 1, IEarner.Action.Voted);
        earner.recordAction(alice, 2, IEarner.Action.Voted);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 20e18);
    }

    function test_recordAction_differentAction_succeedsAgain() public {
        vm.startPrank(recorder);
        earner.recordAction(alice, 1, IEarner.Action.Voted);
        earner.recordAction(alice, 1, IEarner.Action.ProposalSubmitted);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 60e18);
    }

    function test_setReward_byAdmin_updatesAmount() public {
        vm.prank(admin);
        earner.setReward(IEarner.Action.Voted, 999e18);
        assertEq(earner.rewardFor(IEarner.Action.Voted), 999e18);
    }

    function test_setReward_byNonAdmin_reverts() public {
        bytes32 adminRole = earner.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        earner.setReward(IEarner.Action.Voted, 999e18);
    }
}
