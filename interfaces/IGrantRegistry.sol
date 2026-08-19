// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IGrantRegistry
/// @notice Stores every grant proposal's metadata, milestone definitions, and
///         release state. The governor reads from here when building proposal
///         calldata; the treasury writes to here when milestones are released.
interface IGrantRegistry {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Lifecycle state of a single grant.
    enum GrantStatus {
        Pending,   // submitted, not yet voted on
        Active,    // voting in progress
        Approved,  // passed governance; awaiting milestone execution
        Rejected,  // failed governance vote
        Completed  // all milestones released
    }

    /// @notice A single milestone within a grant.
    struct Milestone {
        string  description;   // human-readable deliverable
        uint16  basisPoints;   // share of total grant (sum across milestones == 10 000)
        bool    released;      // true once treasury has paid this tranche
    }

    /// @notice Full record for one grant proposal.
    struct Grant {
        uint256     id;
        address     grantee;
        string      title;
        string      descriptionURI;  // IPFS CID or HTTPS link
        uint256     usdAmount;       // total grant in USD (18 decimals)
        uint256     governorProposalId;
        GrantStatus status;
        Milestone[] milestones;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a new grant is submitted.
    event GrantSubmitted(uint256 indexed grantId, address indexed grantee, uint256 usdAmount);

    /// @notice Emitted when a grant's status changes.
    event GrantStatusUpdated(uint256 indexed grantId, GrantStatus newStatus);

    /// @notice Emitted when a milestone is marked released.
    event MilestoneReleased(uint256 indexed grantId, uint8 milestoneIndex);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error GrantNotFound(uint256 grantId);
    error InvalidMilestoneBasisPoints(uint256 total); // must sum to 10 000
    error MilestoneAlreadyReleased(uint256 grantId, uint8 milestoneIndex);
    error UnauthorisedCaller();

    // -------------------------------------------------------------------------
    // Write functions
    // -------------------------------------------------------------------------

    /// @notice Submit a new grant proposal. Anyone may call this.
    /// @param title           Short name for the grant.
    /// @param descriptionURI  IPFS CID or URL with full proposal text.
    /// @param usdAmount       Requested funding in USD (18 decimals).
    /// @param milestones      Array of milestones; basis points must sum to 10 000.
    /// @return grantId        Auto-incremented ID for the new grant.
    function submitGrant(
        string calldata title,
        string calldata descriptionURI,
        uint256 usdAmount,
        Milestone[] calldata milestones
    ) external returns (uint256 grantId);

    /// @notice Link a governor proposal ID to a grant after it has been queued.
    /// @dev Only callable by the governor (GOVERNOR_ROLE).
    function linkProposal(uint256 grantId, uint256 governorProposalId) external;

    /// @notice Update the status of a grant.
    /// @dev Only callable by the governor or timelock.
    function updateStatus(uint256 grantId, GrantStatus status) external;

    /// @notice Mark a specific milestone as released.
    /// @dev Only callable by the treasury (TREASURY_ROLE).
    function markMilestoneReleased(uint256 grantId, uint8 milestoneIndex) external;

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the full Grant struct for `grantId`.
    function getGrant(uint256 grantId) external view returns (Grant memory);

    /// @notice Returns all grant IDs submitted by `grantee`.
    function grantsByGrantee(address grantee) external view returns (uint256[] memory);

    /// @notice Returns the total number of grants ever submitted.
    function totalGrants() external view returns (uint256);
}
