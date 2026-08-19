// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../interfaces/IGrantsGovernor.sol";
import "../interfaces/IGrantRegistry.sol";
import "../interfaces/IGrantsTreasury.sol";
import "../interfaces/IEarner.sol";

/// @title GrantsGovernor
/// @notice OZ Governor extension that ties proposals to GrantRegistry entries.
///         proposeGrantRelease() constructs the treasury calldata, links the IDs in the
///         registry, and returns the standard OZ proposalId.
///         Voters automatically earn GrantToken via the Earner on each castVote call.
///
/// @dev GD-11: Inherits the full OZ Governor stack (Settings, Counting, Votes, Quorum, Timelock).
/// @dev GD-12: _castVote override records Voted action in Earner for every vote cast.
/// @dev GD-13: proposeGrantRelease validates the grant exists in the registry before proposing.
contract GrantsGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    IGrantsGovernor
{
    IGrantRegistry private immutable _registry;
    IGrantsTreasury private immutable _treasury;
    IEarner private immutable _earner;

    /// @dev Maps governor proposalId → grantId for grant-release proposals.
    mapping(uint256 => uint256) private _grantIdOf;

    /// @dev Marks proposalIds created via `proposeGrantRelease`, so the
    ///      ProposalSubmitted reward (GD-16) is only ever paid for those, and only
    ///      once the proposal has actually executed — never at creation time.
    mapping(uint256 => bool) private _isGrantProposal;

    /// @dev The one milestone-release proposal currently allowed to be outstanding
    ///      DAO-wide (0 = none). Only one may be Pending/Active/Succeeded/Queued at
    ///      a time, so voter attention can't be diluted by duplicate/competing
    ///      proposals on the same or different grants.
    uint256 private _activeMilestoneProposalId;

    /// @param token_              GrantToken (IVotes) from which voting power is read.
    /// @param timelock_           TimelockController that executes approved proposals.
    /// @param registry_           GrantRegistry storing grant and milestone state.
    /// @param treasury_           GrantsTreasury that holds and releases ETH.
    /// @param earner_             Earner that mints reward tokens for participation.
    /// @param votingDelay_        Blocks between propose() and the voting window opening.
    /// @param votingPeriod_       Blocks the voting window stays open.
    /// @param proposalThreshold_  Minimum GRANT tokens required to create a proposal.
    /// @param quorumNumerator_    Percentage (0–100) of total supply required for quorum.
    constructor(
        IVotes token_,
        TimelockController timelock_,
        address registry_,
        address payable treasury_,
        address earner_,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_,
        uint256 quorumNumerator_
    )
        Governor("GrantsDAO")
        GovernorSettings(votingDelay_, votingPeriod_, proposalThreshold_)
        GovernorVotes(token_)
        GovernorVotesQuorumFraction(quorumNumerator_)
        GovernorTimelockControl(timelock_)
    {
        _registry = IGrantRegistry(registry_);
        _treasury = IGrantsTreasury(treasury_);
        _earner = IEarner(earner_);
    }

    // ── IGrantsGovernor ───────────────────────────────────────────────────────

    /// @inheritdoc IGrantsGovernor
    function proposeGrantRelease(
        uint256 grantId,
        uint8 milestone,
        string calldata description
    ) external returns (uint256 proposalId) {
        // Only one milestone-release proposal may be outstanding DAO-wide at a time.
        if (_activeMilestoneProposalId != 0) {
            ProposalState activeState = state(_activeMilestoneProposalId);
            if (
                activeState == ProposalState.Pending || activeState == ProposalState.Active
                    || activeState == ProposalState.Succeeded || activeState == ProposalState.Queued
            ) {
                revert ActiveMilestoneProposalExists(_activeMilestoneProposalId);
            }
        }

        // Validate that the grant exists and retrieve its details.
        IGrantRegistry.Grant memory grant = _registry.getGrant(grantId);
        if (grant.grantee == address(0)) revert GrantNotRegistered(grantId);

        // Compute the milestone's USD slice; GrantsTreasury converts to ETH itself
        // at execution time, so price exposure is never locked in at proposal time.
        uint256 milestoneBps = grant.milestones[milestone].basisPoints;
        uint256 usdSlice = (grant.usdAmount * milestoneBps) / 10_000;

        // Build calldata targeting GrantsTreasury.releaseMilestone.
        address[] memory targets = new address[](1);
        targets[0] = address(_treasury);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(
            IGrantsTreasury.releaseMilestone,
            (grantId, milestone, grant.grantee, usdSlice)
        );

        proposalId = propose(targets, values, calldatas, description);

        _grantIdOf[proposalId] = grantId;
        _isGrantProposal[proposalId] = true;
        _activeMilestoneProposalId = proposalId;

        _registry.linkProposal(grantId, proposalId);

        emit GrantProposalCreated(proposalId, grantId);
    }

    /// @inheritdoc IGrantsGovernor
    function grantIdOf(uint256 proposalId) external view returns (uint256) {
        return _grantIdOf[proposalId];
    }

    /// @inheritdoc IGrantsGovernor
    function registry() external view returns (address) {
        return address(_registry);
    }

    /// @inheritdoc IGrantsGovernor
    function treasury() external view returns (address) {
        return address(_treasury);
    }

    // ── OZ Governor overrides ─────────────────────────────────────────────────

    /// @dev Records a Voted action in the Earner after every successful vote.
    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        string memory reason,
        bytes memory params
    ) internal override returns (uint256 weight) {
        weight = super._castVote(proposalId, account, support, reason, params);
        // Only reward votes that actually carried voting power (GD-16) — otherwise an
        // account with zero GRANT could earn tokens for free by voting on every proposal.
        // Silently skip if the Earner call fails (e.g. already recorded).
        if (weight > 0) {
            try _earner.recordAction(account, proposalId, IEarner.Action.Voted) {} catch {}
        }
    }

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);

        // Reward the proposer only after the grant-release proposal has actually
        // executed (GD-16) — not merely been created — so ProposalSubmitted rewards
        // can't be farmed by proposing releases that never pass or execute.
        if (_isGrantProposal[proposalId]) {
            try _earner.recordAction(proposalProposer(proposalId), proposalId, IEarner.Action.ProposalSubmitted) {}
                catch {}

            // Also reward the grantee whose milestone was just approved — distinct
            // from the proposer above, since anyone (not just the grantee) can call
            // proposeGrantRelease. This is what actually gives delivering grantees
            // governance power, rather than only rewarding whoever clicked propose.
            address grantee = _registry.getGrant(_grantIdOf[proposalId]).grantee;
            try _earner.recordAction(grantee, proposalId, IEarner.Action.MilestoneApproved) {} catch {}
        }
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }
}
