// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "../interfaces/IGrantsTreasury.sol";
import "../interfaces/IGrantRegistry.sol";
import "../interfaces/IPriceFeed.sol";

/// @title GrantsTreasury
/// @notice Holds the DAO's ETH and releases funds to grantees milestone-by-milestone.
///         All disbursements are authorised exclusively by the TimelockController.
///         Uses a pull-over-push pattern: releaseMilestone records a pending withdrawal;
///         the grantee calls withdraw() to receive funds.
///
/// @dev GD-9: All ETH-moving functions protected by ReentrancyGuardTransient (EIP-1153).
/// @dev GD-10: releaseMilestone is callable only by the timelock (set at construction).
contract GrantsTreasury is ReentrancyGuardTransient, IGrantsTreasury {
    address public immutable timelock;
    IGrantRegistry public immutable registry;
    IPriceFeed public immutable priceFeed;

    /// @dev pendingWithdrawals[grantee][grantId][milestone] = ethAmount
    mapping(address => mapping(uint256 => mapping(uint8 => uint256))) private _pending;

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert CallerNotTimelock();
        _;
    }

    /// @param timelock_  Address of the TimelockController that authorises releases.
    /// @param registry_  Address of the GrantRegistry for milestone state updates.
    /// @param priceFeed_ Address of the PriceFeed used to convert USD amounts to ETH
    ///                   at release time (not at proposal time — see GD-14).
    constructor(address timelock_, address registry_, address priceFeed_) {
        if (timelock_ == address(0) || registry_ == address(0) || priceFeed_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        registry = IGrantRegistry(registry_);
        priceFeed = IPriceFeed(priceFeed_);
    }

    // ── IGrantsTreasury ───────────────────────────────────────────────────────

    /// @inheritdoc IGrantsTreasury
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    /// @inheritdoc IGrantsTreasury
    /// @dev Called by the timelock after a passed governor proposal. Independently
    ///      re-derives `usdAmount` from the registry's own grant/milestone data (GD-15)
    ///      before converting to ETH at *this* call's block (GD-14), rather than trusting
    ///      the governor calldata's amount as-is or the price at proposal time.
    function releaseMilestone(uint256 grantId, uint8 milestone, address grantee, uint256 usdAmount)
        external
        onlyTimelock
        nonReentrant
    {
        IGrantRegistry.Grant memory grant = registry.getGrant(grantId);

        if (grant.grantee != grantee) revert GranteeMismatch(grant.grantee, grantee);

        uint256 expectedUsdAmount = (grant.usdAmount * grant.milestones[milestone].basisPoints) / 10_000;
        if (expectedUsdAmount != usdAmount) revert UsdAmountMismatch(expectedUsdAmount, usdAmount);

        uint256 ethAmount = priceFeed.usdToEth(usdAmount);

        if (address(this).balance < ethAmount) {
            revert InsufficientBalance(address(this).balance, ethAmount);
        }

        // Effects before interactions (CEI).
        _pending[grantee][grantId][milestone] += ethAmount;
        registry.markMilestoneReleased(grantId, milestone);

        emit MilestoneReleased(grantId, milestone, grantee, ethAmount);
    }

    /// @inheritdoc IGrantsTreasury
    function withdraw(uint256 grantId, uint8 milestone) external nonReentrant {
        uint256 amount = _pending[msg.sender][grantId][milestone];
        if (amount == 0) revert InsufficientBalance(0, 1);

        // Effects before interactions (CEI).
        _pending[msg.sender][grantId][milestone] = 0;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    /// @inheritdoc IGrantsTreasury
    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @inheritdoc IGrantsTreasury
    function pendingWithdrawal(address grantee, uint256 grantId, uint8 milestone)
        external
        view
        returns (uint256)
    {
        return _pending[grantee][grantId][milestone];
    }
}
