// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "../interfaces/IEarner.sol";
import "../interfaces/IGrantToken.sol";

/// @title Earner
/// @notice Records participation actions (Voted, ProposalSubmitted, MilestoneApproved)
///         and mints GrantToken rewards to contributors.
///
/// @dev GD-3: Only addresses with RECORDER_ROLE (governor, registry) may call recordAction.
/// @dev GD-4: Rewards are configurable per action type by the DAO via the timelock.
/// @dev GD-5: Each (account, proposalId, action) triple is recorded at most once.
contract Earner is AccessControlDefaultAdminRules, IEarner {
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    IGrantToken public immutable token;

    /// @dev Reward amounts per action in token units (18 decimals).
    mapping(Action => uint256) private _rewards;

    /// @dev Tracks whether a (account, proposalId, action) has already been recorded.
    mapping(address => mapping(uint256 => mapping(Action => bool))) private _recorded;

    /// @param admin   Address that receives DEFAULT_ADMIN_ROLE; grants RECORDER_ROLE.
    /// @param token_  Address of the GrantToken contract (must have MINTER_ROLE granted here).
    constructor(address admin, address token_) AccessControlDefaultAdminRules(0, admin) {
        token = IGrantToken(token_);

        // Default reward amounts — adjustable via setReward.
        _rewards[Action.Voted] = 10e18;
        _rewards[Action.ProposalSubmitted] = 50e18;
        _rewards[Action.MilestoneApproved] = 25e18;
        _rewards[Action.Seeded] = 10e18;
    }

    // ── IEarner ───────────────────────────────────────────────────────────────

    /// @inheritdoc IEarner
    function recordAction(address participant, uint256 proposalId, Action action) external onlyRole(RECORDER_ROLE) {
        if (_recorded[participant][proposalId][action]) {
            revert AlreadyRecorded(participant, proposalId, action);
        }

        _recorded[participant][proposalId][action] = true;

        uint256 amount = _rewards[action];

        token.mint(participant, amount);

        emit TokensEarned(participant, action, amount);
    }

    /// @inheritdoc IEarner
    function setReward(Action action, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _rewards[action] = amount;
    }

    /// @inheritdoc IEarner
    function rewardFor(Action action) external view returns (uint256) {
        return _rewards[action];
    }
}
