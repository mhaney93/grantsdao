// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IGrantsGovernor
/// @notice OZ Governor extension that ties proposals to GrantRegistry entries.
///         Inherits the full OZ IGovernor interface; this file adds the
///         GrantsDAO-specific surface area only.
interface IGrantsGovernor {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a governor proposal is explicitly tied to a grant.
    event GrantProposalCreated(uint256 indexed governorProposalId, uint256 indexed grantId);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a grant-proposal is created without a matching registry entry.
    error GrantNotRegistered(uint256 grantId);

    /// @notice Thrown when a new milestone-release proposal is attempted while
    ///         another one is still outstanding (Pending/Active/Succeeded/Queued) —
    ///         only one may be live DAO-wide at a time, to keep voter attention
    ///         focused and prevent duplicate-proposal spam on the same milestone.
    error ActiveMilestoneProposalExists(uint256 activeProposalId);

    // -------------------------------------------------------------------------
    // Write functions (grant-specific)
    // -------------------------------------------------------------------------

    /// @notice Create a governor proposal that, if passed, releases milestone `milestone`
    ///         of grant `grantId` from the treasury.
    /// @dev Internally calls `propose()` with the treasury's `releaseMilestone` calldata.
    ///      Also calls `GrantRegistry.linkProposal` to associate the IDs.
    /// @param grantId    Registry grant ID.
    /// @param milestone  Zero-indexed milestone to release.
    /// @param description Human-readable proposal description (for the event log).
    /// @return proposalId The OZ governor proposal ID.
    function proposeGrantRelease(
        uint256 grantId,
        uint8 milestone,
        string calldata description
    ) external returns (uint256 proposalId);

    // -------------------------------------------------------------------------
    // View functions (grant-specific)
    // -------------------------------------------------------------------------

    /// @notice Returns the grant ID linked to a given governor proposal ID.
    ///         Returns 0 if the proposal is not a grant-release proposal.
    function grantIdOf(uint256 proposalId) external view returns (uint256);

    /// @notice Address of the GrantRegistry this governor reads from.
    function registry() external view returns (address);

    /// @notice Address of the GrantsTreasury this governor targets.
    function treasury() external view returns (address);
}
