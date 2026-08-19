// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEarner
/// @notice Records participation actions and distributes GrantToken to contributors.
///         Actions include: voted on proposal, submitted proposal, milestone approved,
///         and admin-seeded voting power.
interface IEarner {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a participant earns tokens for an action.
    event TokensEarned(address indexed participant, Action action, uint256 amount);

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Enumeration of recognised participation actions.
    enum Action {
        Voted,
        ProposalSubmitted,
        MilestoneApproved,
        Seeded
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when an action has already been recorded for this account + proposal.
    error AlreadyRecorded(address account, uint256 proposalId, Action action);

    // -------------------------------------------------------------------------
    // Write functions
    // -------------------------------------------------------------------------

    /// @notice Record that `participant` performed `action` on `proposalId` and mint reward tokens.
    /// @dev Only callable by governor or registry (addresses with RECORDER_ROLE).
    /// @param participant Address to reward.
    /// @param proposalId  Associated proposal ID (0 if not proposal-specific).
    /// @param action      The participation action performed.
    function recordAction(address participant, uint256 proposalId, Action action) external;

    /// @notice Update the token reward amount for a given action.
    /// @dev Only callable by owner (DAO via timelock).
    /// @param action The action to update.
    /// @param amount New reward amount (18 decimals).
    function setReward(Action action, uint256 amount) external;

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the current reward amount for `action`.
    function rewardFor(Action action) external view returns (uint256);
}
