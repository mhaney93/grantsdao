// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "../interfaces/IGrantToken.sol";

/// @title GrantToken
/// @notice Soulbound ERC20Votes governance token for GrantsDAO.
///         Voting power is earned via the Earner contract — never transferred.
///         delegate() and delegateBySig() work normally for on-chain checkpoints.
///
/// @dev GD-1: Non-transferable after mint; only mint (from==0) is allowed in _update.
/// @dev GD-2: MINTER_ROLE granted exclusively to the Earner contract after deployment.
contract GrantToken is ERC20Votes, AccessControlDefaultAdminRules, IGrantToken {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @param admin Address that receives DEFAULT_ADMIN_ROLE; grants MINTER_ROLE to Earner.
    constructor(address admin)
        ERC20("GrantToken", "GRANT")
        EIP712("GrantToken", "1")
        AccessControlDefaultAdminRules(0, admin)
    {}

    // ── IGrantToken ───────────────────────────────────────────────────────────

    /// @inheritdoc IGrantToken
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @inheritdoc IGrantToken
    function getVotes(address account) public view override(Votes, IGrantToken) returns (uint256) {
        return super.getVotes(account);
    }

    /// @inheritdoc IGrantToken
    function getPastVotes(address account, uint256 timepoint)
        public
        view
        override(Votes, IGrantToken)
        returns (uint256)
    {
        return super.getPastVotes(account, timepoint);
    }

    /// @inheritdoc IGrantToken
    function getPastTotalSupply(uint256 timepoint) public view override(Votes, IGrantToken) returns (uint256) {
        return super.getPastTotalSupply(timepoint);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /// @dev Allows mint (from==0); reverts on peer-to-peer transfers. Burns (to==0) allowed.
    function _update(address from, address to, uint256 value) internal override(ERC20Votes) {
        if (from != address(0) && to != address(0)) revert SoulboundTransferForbidden();
        super._update(from, to, value);
    }
}
