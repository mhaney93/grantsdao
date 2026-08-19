// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/GrantRegistry.sol";
import "../interfaces/IGrantRegistry.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

contract GrantRegistryTest is Test {
    GrantRegistry registry;

    address admin = makeAddr("admin");
    address governor = makeAddr("governor");
    address treasury = makeAddr("treasury");
    address grantee = makeAddr("grantee");

    function setUp() public {
        registry = new GrantRegistry(admin);

        vm.startPrank(admin);
        registry.grantRole(registry.GOVERNOR_ROLE(), governor);
        registry.grantRole(registry.TREASURY_ROLE(), treasury);
        vm.stopPrank();
    }

    function _validMilestones() internal pure returns (IGrantRegistry.Milestone[] memory milestones) {
        milestones = new IGrantRegistry.Milestone[](2);
        milestones[0] = IGrantRegistry.Milestone({description: "M1", basisPoints: 4000, released: false});
        milestones[1] = IGrantRegistry.Milestone({description: "M2", basisPoints: 6000, released: false});
    }

    function test_submitGrant_succeeds() public {
        vm.prank(grantee);
        uint256 grantId = registry.submitGrant("Title", "ipfs://uri", 1000e18, _validMilestones());

        assertEq(grantId, 0);
        assertEq(registry.totalGrants(), 1);

        IGrantRegistry.Grant memory g = registry.getGrant(grantId);
        assertEq(g.grantee, grantee);
        assertEq(g.usdAmount, 1000e18);
        assertEq(uint8(g.status), uint8(IGrantRegistry.GrantStatus.Pending));
        assertEq(g.milestones.length, 2);
    }

    function test_submitGrant_badBasisPoints_reverts() public {
        IGrantRegistry.Milestone[] memory milestones = new IGrantRegistry.Milestone[](1);
        milestones[0] = IGrantRegistry.Milestone({description: "M1", basisPoints: 5000, released: false});

        vm.expectRevert(abi.encodeWithSelector(IGrantRegistry.InvalidMilestoneBasisPoints.selector, 5000));
        registry.submitGrant("Title", "ipfs://uri", 1000e18, milestones);
    }

    function test_submitGrant_trackedByGrantee() public {
        vm.startPrank(grantee);
        uint256 id1 = registry.submitGrant("A", "uri1", 100e18, _validMilestones());
        uint256 id2 = registry.submitGrant("B", "uri2", 200e18, _validMilestones());
        vm.stopPrank();

        uint256[] memory ids = registry.grantsByGrantee(grantee);
        assertEq(ids.length, 2);
        assertEq(ids[0], id1);
        assertEq(ids[1], id2);
    }

    function test_linkProposal_byGovernor_succeeds() public {
        vm.prank(grantee);
        uint256 grantId = registry.submitGrant("Title", "uri", 100e18, _validMilestones());

        vm.prank(governor);
        registry.linkProposal(grantId, 42);

        assertEq(registry.getGrant(grantId).governorProposalId, 42);
    }

    function test_linkProposal_byNonGovernor_reverts() public {
        vm.prank(grantee);
        uint256 grantId = registry.submitGrant("Title", "uri", 100e18, _validMilestones());

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, grantee, registry.GOVERNOR_ROLE()
            )
        );
        vm.prank(grantee);
        registry.linkProposal(grantId, 42);
    }

    function test_linkProposal_nonexistentGrant_reverts() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IGrantRegistry.GrantNotFound.selector, 99));
        registry.linkProposal(99, 42);
    }

    function test_updateStatus_byGovernor_succeeds() public {
        vm.prank(grantee);
        uint256 grantId = registry.submitGrant("Title", "uri", 100e18, _validMilestones());

        vm.prank(governor);
        registry.updateStatus(grantId, IGrantRegistry.GrantStatus.Approved);

        assertEq(uint8(registry.getGrant(grantId).status), uint8(IGrantRegistry.GrantStatus.Approved));
    }

    function test_markMilestoneReleased_byTreasury_succeeds() public {
        vm.prank(grantee);
        uint256 grantId = registry.submitGrant("Title", "uri", 100e18, _validMilestones());

        vm.prank(treasury);
        registry.markMilestoneReleased(grantId, 0);

        IGrantRegistry.Grant memory g = registry.getGrant(grantId);
        assertTrue(g.milestones[0].released);
        // only one of two milestones released -> not yet Completed
        assertEq(uint8(g.status), uint8(IGrantRegistry.GrantStatus.Pending));
    }

    function test_markMilestoneReleased_allMilestones_completesGrant() public {
        vm.prank(grantee);
        uint256 grantId = registry.submitGrant("Title", "uri", 100e18, _validMilestones());

        vm.startPrank(treasury);
        registry.markMilestoneReleased(grantId, 0);
        registry.markMilestoneReleased(grantId, 1);
        vm.stopPrank();

        assertEq(uint8(registry.getGrant(grantId).status), uint8(IGrantRegistry.GrantStatus.Completed));
    }

    function test_markMilestoneReleased_twice_reverts() public {
        vm.prank(grantee);
        uint256 grantId = registry.submitGrant("Title", "uri", 100e18, _validMilestones());

        vm.prank(treasury);
        registry.markMilestoneReleased(grantId, 0);

        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IGrantRegistry.MilestoneAlreadyReleased.selector, grantId, 0));
        registry.markMilestoneReleased(grantId, 0);
    }

    function test_getGrant_nonexistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IGrantRegistry.GrantNotFound.selector, 0));
        registry.getGrant(0);
    }
}
