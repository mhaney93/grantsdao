// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IGrantsTreasury
/// @notice Holds the DAO's ETH. Releases funds to grantees milestone-by-milestone.
///         All disbursements must be authorised by the governor via the timelock.
interface IGrantsTreasury {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when ETH is deposited into the treasury.
    event Deposited(address indexed from, uint256 amount);

    /// @notice Emitted when a milestone tranche is released to a grantee.
    event MilestoneReleased(uint256 indexed grantId, uint8 milestone, address indexed grantee, uint256 ethAmount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when the treasury does not have enough ETH.
    error InsufficientBalance(uint256 available, uint256 required);

    /// @notice Thrown when the caller is not the timelock.
    error CallerNotTimelock();

    /// @notice Thrown when a constructor address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when `grantee` doesn't match the registry's record for `grantId`.
    error GranteeMismatch(address expected, address actual);

    /// @notice Thrown when `usdAmount` doesn't match the milestone's share of the
    ///         grant's total USD amount, as recorded in the registry.
    error UsdAmountMismatch(uint256 expected, uint256 actual);

    // -------------------------------------------------------------------------
    // Write functions
    // -------------------------------------------------------------------------

    /// @notice Accept an ETH deposit. Any address can contribute.
    receive() external payable;

    /// @notice Release the ETH equivalent of `usdAmount` to `grantee` for milestone
    ///         `milestone` of grant `grantId`, converted at execution time.
    /// @dev Only callable by the TimelockController (after a passed governor proposal).
    ///      Uses a pull pattern: records a pending withdrawal instead of pushing ETH directly.
    ///      `grantee` and `usdAmount` are independently verified against the registry's
    ///      own grant/milestone data before any funds move.
    /// @param grantId   Registry grant ID.
    /// @param milestone Zero-indexed milestone number.
    /// @param grantee   Address authorised to withdraw the funds.
    /// @param usdAmount USD value (18 decimals) of this milestone's share of the grant.
    function releaseMilestone(uint256 grantId, uint8 milestone, address grantee, uint256 usdAmount) external;

    /// @notice Grantee calls this to pull their pending ETH after a milestone is released.
    /// @param grantId   Registry grant ID.
    /// @param milestone Zero-indexed milestone number.
    function withdraw(uint256 grantId, uint8 milestone) external;

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Current ETH balance of the treasury.
    function balance() external view returns (uint256);

    /// @notice Pending withdrawal amount for a given grantee + grant + milestone.
    function pendingWithdrawal(address grantee, uint256 grantId, uint8 milestone) external view returns (uint256);
}
