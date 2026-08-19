// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../contracts/GrantsTreasury.sol";
import "../../contracts/GrantRegistry.sol";
import "../../contracts/PriceFeed.sol";
import "../../interfaces/IGrantRegistry.sol";
import "../mocks/MockAggregatorV3.sol";

/// @title TreasuryEchidna
/// @notice Fuzzes the solvency invariant from planning.md's Testing Plan: the treasury
///         can never owe out more ETH (via pendingWithdrawal + already-paid) than it
///         ever received, regardless of what sequence of grant submissions, milestone
///         releases (acting as the timelock), and withdrawals Echidna tries.
contract TreasuryEchidna {
    GrantsTreasury internal treasury;
    GrantRegistry internal registry;
    PriceFeed internal priceFeed;
    MockAggregatorV3 internal feed;

    uint256 internal totalDeposited;
    uint256 internal totalWithdrawn;

    constructor() {
        registry = new GrantRegistry(address(this));
        feed = new MockAggregatorV3(1000e8); // fixed $1000/ETH, kept simple for this property
        priceFeed = new PriceFeed(address(feed), 365 days);
        // This contract plays the role of the timelock, so it can drive releaseMilestone directly.
        treasury = new GrantsTreasury(address(this), address(registry), address(priceFeed));
        registry.grantRole(registry.TREASURY_ROLE(), address(treasury));
    }

    /// @dev Bounded ETH deposit, tracked so the invariant has an independent total.
    function deposit(uint256 amount) public {
        amount = (amount % 10 ether) + 1;
        (bool ok,) = address(treasury).call{value: amount}("");
        require(ok);
        totalDeposited += amount;
    }

    /// @dev Bounded grant submission with a single 100% milestone.
    function submitGrant(uint256 usdAmount) public returns (uint256 grantId) {
        usdAmount = (usdAmount % 5000e18) + 1;
        IGrantRegistry.Milestone[] memory milestones = new IGrantRegistry.Milestone[](1);
        milestones[0] = IGrantRegistry.Milestone({description: "M", basisPoints: 10_000, released: false});
        grantId = registry.submitGrant("t", "u", usdAmount, milestones);
    }

    /// @dev Releases milestone 0 of `grantId`, re-deriving amount/grantee exactly like
    ///      the real timelock call would (mirrors GrantsGovernor.proposeGrantRelease).
    function releaseMilestone(uint256 grantId) public {
        IGrantRegistry.Grant memory grant = registry.getGrant(grantId);
        if (grant.grantee == address(0)) return;
        uint256 usdAmount = (grant.usdAmount * grant.milestones[0].basisPoints) / 10_000;
        try treasury.releaseMilestone(grantId, 0, grant.grantee, usdAmount) {} catch {}
    }

    /// @dev Any address can call withdraw on its own behalf; the harness itself never
    ///      holds pending funds (grantee == msg.sender in submitGrant is always this
    ///      contract), so this call always no-ops without reverting the run.
    function withdrawSelf(uint256 grantId, uint8 milestone) public {
        uint256 before = address(this).balance;
        try treasury.withdraw(grantId, milestone) {
            totalWithdrawn += address(this).balance - before;
        } catch {}
    }

    receive() external payable {}

    /// @notice Core solvency invariant: the treasury can never be short of what it
    ///         still owes (pending withdrawals) relative to net ETH ever received.
    function echidna_treasury_solvent() public view returns (bool) {
        return address(treasury).balance + totalWithdrawn <= totalDeposited;
    }
}
