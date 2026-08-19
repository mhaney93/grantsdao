// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IGrantToken
/// @notice Soulbound ERC-20Votes token used as the GrantsDAO governance token.
///         Non-transferable after mint; one address = one voter.
interface IGrantToken {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when tokens are minted to a participant.
    event TokensMinted(address indexed to, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a transfer is attempted on a soulbound token.
    error SoulboundTransferForbidden();

    // -------------------------------------------------------------------------
    // Write functions
    // -------------------------------------------------------------------------

    /// @notice Mint `amount` tokens to `to`.
    /// @dev Only callable by an address with the MINTER_ROLE (i.e. Earner contract).
    /// @param to    Recipient address.
    /// @param amount Number of tokens (18 decimals).
    function mint(address to, uint256 amount) external;

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the current voting power of `account`.
    function getVotes(address account) external view returns (uint256);

    /// @notice Returns the voting power of `account` at a past block/timestamp.
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);

    /// @notice Returns the total supply at a past block/timestamp.
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
}
