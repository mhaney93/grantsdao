// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "../interfaces/IGrantRegistry.sol";

/// @title GrantRegistry
/// @notice Stores every grant's metadata, milestone definitions, and release state.
///         The governor reads from here when building proposal calldata; the treasury
///         writes to here when milestones are released.
///
/// @dev GD-7: submitGrant is permissionless. Status transitions and milestone releases
///            are access-controlled (GOVERNOR_ROLE / TREASURY_ROLE).
/// @dev GD-8: Milestone basis points must sum to exactly 10 000; validated on submit.
contract GrantRegistry is AccessControlDefaultAdminRules, IGrantRegistry {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    uint256 private _nextGrantId;

    /// @dev Storage for all grants, keyed by grant ID.
    mapping(uint256 => Grant) private _grants;

    /// @dev Grant IDs per grantee address.
    mapping(address => uint256[]) private _grantsByGrantee;

    /// @param admin Address that receives DEFAULT_ADMIN_ROLE; grants GOVERNOR_ROLE and TREASURY_ROLE.
    constructor(address admin) AccessControlDefaultAdminRules(0, admin) {}

    // ── IGrantRegistry ────────────────────────────────────────────────────────

    /// @inheritdoc IGrantRegistry
    function submitGrant(
        string calldata title,
        string calldata descriptionURI,
        uint256 usdAmount,
        Milestone[] calldata milestones
    ) external returns (uint256 grantId) {
        // Validate milestone basis points sum to 10 000.
        uint256 total;
        for (uint256 i; i < milestones.length; ++i) {
            total += milestones[i].basisPoints;
        }
        if (total != 10_000) revert InvalidMilestoneBasisPoints(total);

        grantId = _nextGrantId++;

        Grant storage g = _grants[grantId];
        g.id = grantId;
        g.grantee = msg.sender;
        g.title = title;
        g.descriptionURI = descriptionURI;
        g.usdAmount = usdAmount;
        g.status = GrantStatus.Pending;

        for (uint256 i; i < milestones.length; ++i) {
            g.milestones.push(milestones[i]);
        }

        _grantsByGrantee[msg.sender].push(grantId);

        emit GrantSubmitted(grantId, msg.sender, usdAmount);
    }

    /// @inheritdoc IGrantRegistry
    function linkProposal(uint256 grantId, uint256 governorProposalId) external onlyRole(GOVERNOR_ROLE) {
        _requireExists(grantId);
        _grants[grantId].governorProposalId = governorProposalId;
    }

    /// @inheritdoc IGrantRegistry
    function updateStatus(uint256 grantId, GrantStatus status) external onlyRole(GOVERNOR_ROLE) {
        _requireExists(grantId);
        _grants[grantId].status = status;
        emit GrantStatusUpdated(grantId, status);
    }

    /// @inheritdoc IGrantRegistry
    function markMilestoneReleased(uint256 grantId, uint8 milestoneIndex) external onlyRole(TREASURY_ROLE) {
        _requireExists(grantId);
        Grant storage g = _grants[grantId];

        if (g.milestones[milestoneIndex].released) {
            revert MilestoneAlreadyReleased(grantId, milestoneIndex);
        }

        g.milestones[milestoneIndex].released = true;
        emit MilestoneReleased(grantId, milestoneIndex);

        // Mark grant Completed when every milestone is released.
        bool allReleased = true;
        for (uint256 i; i < g.milestones.length; ++i) {
            if (!g.milestones[i].released) {
                allReleased = false;
                break;
            }
        }
        if (allReleased) {
            g.status = GrantStatus.Completed;
            emit GrantStatusUpdated(grantId, GrantStatus.Completed);
        }
    }

    /// @inheritdoc IGrantRegistry
    function getGrant(uint256 grantId) external view returns (Grant memory) {
        _requireExists(grantId);
        return _grants[grantId];
    }

    /// @inheritdoc IGrantRegistry
    function grantsByGrantee(address grantee) external view returns (uint256[] memory) {
        return _grantsByGrantee[grantee];
    }

    /// @inheritdoc IGrantRegistry
    function totalGrants() external view returns (uint256) {
        return _nextGrantId;
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _requireExists(uint256 grantId) private view {
        if (grantId >= _nextGrantId) revert GrantNotFound(grantId);
    }
}
