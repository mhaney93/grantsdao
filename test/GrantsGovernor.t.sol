// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/Governor.sol";
import "../contracts/GrantToken.sol";
import "../contracts/Earner.sol";
import "../contracts/PriceFeed.sol";
import "../contracts/GrantRegistry.sol";
import "../contracts/GrantsTreasury.sol";
import "../contracts/GrantsGovernor.sol";
import "../interfaces/IGrantRegistry.sol";
import "../interfaces/IGrantsTreasury.sol";
import "../interfaces/IGrantsGovernor.sol";
import "../interfaces/IEarner.sol";
import "./mocks/MockAggregatorV3.sol";

/// @notice Integration test: full deployment wiring + propose -> vote -> queue -> execute -> withdraw.
contract GrantsGovernorTest is Test {
    GrantToken token;
    Earner earner;
    PriceFeed priceFeed;
    MockAggregatorV3 mockFeed;
    GrantRegistry registry;
    GrantsTreasury treasury;
    GrantsGovernor governor;
    TimelockController timelock;

    address admin = makeAddr("admin");
    address grantee = makeAddr("grantee");
    address voter1 = makeAddr("voter1");
    address voter2 = makeAddr("voter2");

    uint256 constant MIN_DELAY = 1 days;
    uint48 constant VOTING_DELAY = 1;
    uint32 constant VOTING_PERIOD = 50;
    uint256 constant PROPOSAL_THRESHOLD = 0;
    uint256 constant QUORUM_NUMERATOR = 4; // 4%
    int256 constant ETH_USD_PRICE = 3000e8; // $3000, 8 decimals

    function setUp() public {
        // Timelock: admin (this test contract) temporarily holds TIMELOCK_ADMIN_ROLE
        // so it can wire the governor in as proposer, then renounce.
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open executor role
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(this));

        token = new GrantToken(admin);
        earner = new Earner(admin, address(token));

        mockFeed = new MockAggregatorV3(ETH_USD_PRICE);
        priceFeed = new PriceFeed(address(mockFeed), 1 hours);

        registry = new GrantRegistry(admin);
        treasury = new GrantsTreasury(address(timelock), address(registry), address(priceFeed));

        governor = new GrantsGovernor(
            token,
            timelock,
            address(registry),
            payable(address(treasury)),
            address(earner),
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_NUMERATOR
        );

        // Wire roles.
        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), address(earner));
        earner.grantRole(earner.RECORDER_ROLE(), address(governor));
        registry.grantRole(registry.GOVERNOR_ROLE(), address(governor));
        registry.grantRole(registry.TREASURY_ROLE(), address(treasury));
        vm.stopPrank();

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        // Fund the treasury.
        vm.deal(address(this), 100 ether);
        (bool ok,) = address(treasury).call{value: 10 ether}("");
        require(ok, "fund treasury");

        // Give voters voting power via the Earner (admin has no RECORDER_ROLE by
        // default — grant it here purely so the test can seed votes directly).
        bytes32 recorderRole = earner.RECORDER_ROLE();
        vm.prank(admin);
        earner.grantRole(recorderRole, admin);

        vm.startPrank(admin);
        earner.recordAction(voter1, 1_000_001, IEarner.Action.Voted);
        earner.recordAction(voter2, 1_000_002, IEarner.Action.Voted);
        vm.stopPrank();

        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);

        vm.roll(block.number + 1);
    }

    function _submitGrant() internal returns (uint256 grantId) {
        IGrantRegistry.Milestone[] memory milestones = new IGrantRegistry.Milestone[](1);
        milestones[0] = IGrantRegistry.Milestone({description: "Ship v1", basisPoints: 10_000, released: false});

        vm.prank(grantee);
        grantId = registry.submitGrant("Build a thing", "ipfs://cid", 3000e18, milestones);
    }

    function _buildReleaseCalldata(uint256 grantId, uint8 milestone)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        IGrantRegistry.Grant memory grant = registry.getGrant(grantId);
        uint256 usdSlice = (grant.usdAmount * grant.milestones[milestone].basisPoints) / 10_000;

        targets = new address[](1);
        targets[0] = address(treasury);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] =
            abi.encodeCall(IGrantsTreasury.releaseMilestone, (grantId, milestone, grant.grantee, usdSlice));
    }

    /// @dev Full happy path: submit -> propose -> vote -> queue -> execute -> withdraw.
    function test_fullLifecycle_grantIsPaidOut() public {
        uint256 grantId = _submitGrant();

        vm.prank(voter1);
        uint256 proposalId = governor.proposeGrantRelease(grantId, 0, "Release milestone 1");

        assertEq(governor.grantIdOf(proposalId), grantId);
        assertEq(registry.getGrant(grantId).governorProposalId, proposalId);

        // ProposalSubmitted is not rewarded at creation time (GD-16) — only seed Voted (10).
        assertEq(token.balanceOf(voter1), 10e18);

        vm.roll(block.number + VOTING_DELAY + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For
        vm.prank(voter2);
        governor.castVote(proposalId, 1); // For

        vm.roll(block.number + VOTING_PERIOD + 1);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildReleaseCalldata(grantId, 0);
        bytes32 descriptionHash = keccak256(bytes("Release milestone 1"));

        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        vm.warp(block.timestamp + MIN_DELAY + 1);
        mockFeed.setAnswer(ETH_USD_PRICE); // refresh so the feed isn't stale at execution time
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
        assertTrue(registry.getGrant(grantId).milestones[0].released);
        assertEq(registry.getGrant(grantId).status == IGrantRegistry.GrantStatus.Completed, true);

        // ProposalSubmitted (50 GRANT) is rewarded here, only now that execution succeeded,
        // on top of the seeded Voted (10) and the Voted reward (10) from casting a vote above.
        assertEq(token.balanceOf(voter1), 10e18 + 10e18 + 50e18);

        // MilestoneApproved (25 GRANT) rewards the grantee, distinct from the
        // proposer's ProposalSubmitted reward above.
        assertEq(token.balanceOf(grantee), 25e18);

        uint256 expectedEth = priceFeed.usdToEth(3000e18); // 1 ETH at $3000/ETH, computed at execution time
        assertEq(treasury.pendingWithdrawal(grantee, grantId, 0), expectedEth);

        uint256 balBefore = grantee.balance;
        vm.prank(grantee);
        treasury.withdraw(grantId, 0);
        assertEq(grantee.balance, balBefore + expectedEth);
    }

    function test_proposeGrantRelease_unknownGrant_reverts() public {
        // GrantRegistry.getGrant reverts first for an unknown ID, before the
        // governor's own GrantNotRegistered check can trigger.
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(IGrantRegistry.GrantNotFound.selector, 42));
        governor.proposeGrantRelease(42, 0, "bad grant");
    }

    function test_castVote_recordsEarnerAction_onlyOnce() public {
        uint256 grantId = _submitGrant();

        vm.prank(voter1);
        uint256 proposalId = governor.proposeGrantRelease(grantId, 0, "Release milestone 1");

        vm.roll(block.number + VOTING_DELAY + 1);

        uint256 balBefore = token.balanceOf(voter1);
        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        // Voted reward (10e18) minted once via the governor's _castVote hook.
        assertEq(token.balanceOf(voter1), balBefore + 10e18);
    }

    function test_castVote_zeroWeight_earnsNoReward() public {
        uint256 grantId = _submitGrant();

        vm.prank(voter1);
        uint256 proposalId = governor.proposeGrantRelease(grantId, 0, "Release milestone 1");

        vm.roll(block.number + VOTING_DELAY + 1);

        // A brand-new account with zero delegated GRANT should not be able to farm
        // the Voted reward simply by casting a (zero-weight) vote (GD-16).
        address freeloader = makeAddr("freeloader");
        assertEq(token.balanceOf(freeloader), 0);

        vm.prank(freeloader);
        governor.castVote(proposalId, 1);

        assertEq(token.balanceOf(freeloader), 0);
    }

    function test_proposeGrantRelease_doesNotRewardUntilExecuted() public {
        uint256 grantId = _submitGrant();

        vm.prank(voter1);
        governor.proposeGrantRelease(grantId, 0, "Release milestone 1");

        // No ProposalSubmitted reward at creation time — only the seeded Voted (10e18).
        assertEq(token.balanceOf(voter1), 10e18);
    }

    /// @dev proposeGrantRelease is permissionless, so the proposer and grantee can
    ///      be different addresses. Both should be rewarded independently once the
    ///      proposal executes: the proposer earns ProposalSubmitted, the grantee
    ///      earns MilestoneApproved.
    function test_milestoneApproved_rewardsGranteeSeparatelyFromProposer() public {
        uint256 grantId = _submitGrant();

        // voter1 proposes on the grantee's behalf — grantee never calls propose.
        vm.prank(voter1);
        uint256 proposalId = governor.proposeGrantRelease(grantId, 0, "Release milestone 1");

        assertEq(token.balanceOf(grantee), 0);

        vm.roll(block.number + VOTING_DELAY + 1);
        vm.prank(voter1);
        governor.castVote(proposalId, 1);
        vm.prank(voter2);
        governor.castVote(proposalId, 1);
        vm.roll(block.number + VOTING_PERIOD + 1);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _buildReleaseCalldata(grantId, 0);
        bytes32 descriptionHash = keccak256(bytes("Release milestone 1"));

        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + MIN_DELAY + 1);
        mockFeed.setAnswer(ETH_USD_PRICE);
        governor.execute(targets, values, calldatas, descriptionHash);

        // Grantee never voted or proposed, yet earns MilestoneApproved (25e18) purely
        // for having their milestone approved.
        assertEq(token.balanceOf(grantee), 25e18);
        // voter1 (the proposer) earns ProposalSubmitted on top of their Voted rewards.
        assertEq(token.balanceOf(voter1), 10e18 + 10e18 + 50e18);
    }

    /// @dev Second grant, so a second milestone-release proposal targets a
    ///      genuinely different grant (not just a different description on the
    ///      same one), proving the cap is DAO-wide and not per-grant.
    function _submitSecondGrant() internal returns (uint256 grantId) {
        IGrantRegistry.Milestone[] memory milestones = new IGrantRegistry.Milestone[](1);
        milestones[0] = IGrantRegistry.Milestone({description: "Ship v2", basisPoints: 10_000, released: false});

        address grantee2 = makeAddr("grantee2");
        vm.prank(grantee2);
        grantId = registry.submitGrant("Build another thing", "ipfs://cid2", 1000e18, milestones);
    }

    function test_proposeGrantRelease_whileAnotherActive_reverts() public {
        uint256 grantId = _submitGrant();
        uint256 grantId2 = _submitSecondGrant();

        vm.prank(voter1);
        uint256 firstProposalId = governor.proposeGrantRelease(grantId, 0, "Release milestone 1");

        vm.prank(voter1);
        vm.expectRevert(
            abi.encodeWithSelector(IGrantsGovernor.ActiveMilestoneProposalExists.selector, firstProposalId)
        );
        governor.proposeGrantRelease(grantId2, 0, "Release milestone 1 (grant 2)");
    }

    function test_proposeGrantRelease_afterPriorDefeated_succeeds() public {
        uint256 grantId = _submitGrant();
        uint256 grantId2 = _submitSecondGrant();

        vm.prank(voter1);
        governor.proposeGrantRelease(grantId, 0, "Release milestone 1");

        // Let the first proposal expire with no votes -> Defeated.
        vm.roll(block.number + VOTING_DELAY + 1);
        vm.roll(block.number + VOTING_PERIOD + 1);

        // A new proposal is now allowed, since the prior one is no longer active.
        vm.prank(voter1);
        uint256 secondProposalId = governor.proposeGrantRelease(grantId2, 0, "Release milestone 1 (grant 2)");
        assertEq(governor.grantIdOf(secondProposalId), grantId2);
    }

    function test_quorumNotReached_proposalDefeated() public {
        uint256 grantId = _submitGrant();

        vm.prank(voter1);
        uint256 proposalId = governor.proposeGrantRelease(grantId, 0, "Release milestone 1");

        vm.roll(block.number + VOTING_DELAY + 1);
        // No votes cast.
        vm.roll(block.number + VOTING_PERIOD + 1);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_registryAndTreasuryRoles_gateAccessCorrectly() public {
        // Only the governor holds GOVERNOR_ROLE, so direct calls revert.
        vm.expectRevert();
        registry.linkProposal(0, 1);

        // Only the timelock can release funds directly on the treasury.
        vm.expectRevert(IGrantsTreasury.CallerNotTimelock.selector);
        treasury.releaseMilestone(0, 0, grantee, 1 ether);
    }
}
