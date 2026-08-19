// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/GrantsTreasury.sol";
import "../contracts/GrantRegistry.sol";
import "../contracts/PriceFeed.sol";
import "../interfaces/IGrantsTreasury.sol";
import "../interfaces/IGrantRegistry.sol";
import "./mocks/MockAggregatorV3.sol";

contract GrantsTreasuryTest is Test {
    GrantsTreasury treasury;
    GrantRegistry registry;
    PriceFeed priceFeed;
    MockAggregatorV3 mockFeed;

    address admin = makeAddr("admin");
    address timelock = makeAddr("timelock");
    address grantee = makeAddr("grantee");

    int256 constant ETH_USD_PRICE = 1000e8; // $1000/ETH, 8 decimals

    function setUp() public {
        registry = new GrantRegistry(admin);
        mockFeed = new MockAggregatorV3(ETH_USD_PRICE);
        priceFeed = new PriceFeed(address(mockFeed), 1 hours);
        treasury = new GrantsTreasury(timelock, address(registry), address(priceFeed));

        bytes32 treasuryRole = registry.TREASURY_ROLE();
        vm.prank(admin);
        registry.grantRole(treasuryRole, address(treasury));

        vm.deal(address(treasury), 10 ether);
    }

    /// @dev Single 10,000 bps milestone worth `usdAmount` USD (18 decimals).
    function _submitGrant(uint256 usdAmount) internal returns (uint256 grantId) {
        IGrantRegistry.Milestone[] memory milestones = new IGrantRegistry.Milestone[](1);
        milestones[0] = IGrantRegistry.Milestone({description: "M1", basisPoints: 10_000, released: false});

        vm.prank(grantee);
        grantId = registry.submitGrant("Title", "uri", usdAmount, milestones);
    }

    function test_receive_emitsDeposited() public {
        vm.expectEmit(true, false, false, true);
        emit IGrantsTreasury.Deposited(address(this), 1 ether);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_releaseMilestone_byTimelock_recordsPending() public {
        uint256 grantId = _submitGrant(1000e18); // $1000 == 1 ETH at $1000/ETH

        vm.prank(timelock);
        treasury.releaseMilestone(grantId, 0, grantee, 1000e18);

        assertEq(treasury.pendingWithdrawal(grantee, grantId, 0), 1 ether);
        assertTrue(registry.getGrant(grantId).milestones[0].released);
    }

    function test_releaseMilestone_byNonTimelock_reverts() public {
        uint256 grantId = _submitGrant(1000e18);

        vm.expectRevert(IGrantsTreasury.CallerNotTimelock.selector);
        treasury.releaseMilestone(grantId, 0, grantee, 1000e18);
    }

    function test_releaseMilestone_insufficientBalance_reverts() public {
        // $1,000,000 at $1000/ETH == 1000 ETH, far more than the 10 ETH held.
        uint256 grantId = _submitGrant(1_000_000e18);

        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(IGrantsTreasury.InsufficientBalance.selector, 10 ether, 1000 ether)
        );
        treasury.releaseMilestone(grantId, 0, grantee, 1_000_000e18);
    }

    function test_releaseMilestone_granteeMismatch_reverts() public {
        uint256 grantId = _submitGrant(1000e18);
        address impostor = makeAddr("impostor");

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(IGrantsTreasury.GranteeMismatch.selector, grantee, impostor));
        treasury.releaseMilestone(grantId, 0, impostor, 1000e18);
    }

    function test_releaseMilestone_usdAmountMismatch_reverts() public {
        uint256 grantId = _submitGrant(1000e18);

        // Registry says this milestone is worth $1000; calldata claims $2000.
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(IGrantsTreasury.UsdAmountMismatch.selector, 1000e18, 2000e18));
        treasury.releaseMilestone(grantId, 0, grantee, 2000e18);
    }

    function test_releaseMilestone_convertsAtReleaseTimePrice() public {
        uint256 grantId = _submitGrant(1000e18);

        // Price moves between proposal and release; treasury must use the current price.
        mockFeed.setAnswer(500e8); // $500/ETH => $1000 == 2 ETH

        vm.prank(timelock);
        treasury.releaseMilestone(grantId, 0, grantee, 1000e18);

        assertEq(treasury.pendingWithdrawal(grantee, grantId, 0), 2 ether);
    }

    function test_withdraw_transfersEthAndClearsPending() public {
        uint256 grantId = _submitGrant(1000e18);

        vm.prank(timelock);
        treasury.releaseMilestone(grantId, 0, grantee, 1000e18);

        uint256 balBefore = grantee.balance;

        vm.prank(grantee);
        treasury.withdraw(grantId, 0);

        assertEq(grantee.balance, balBefore + 1 ether);
        assertEq(treasury.pendingWithdrawal(grantee, grantId, 0), 0);
    }

    function test_withdraw_withNoPending_reverts() public {
        vm.prank(grantee);
        vm.expectRevert(abi.encodeWithSelector(IGrantsTreasury.InsufficientBalance.selector, 0, 1));
        treasury.withdraw(0, 0);
    }

    function test_withdraw_twice_revertsSecondTime() public {
        uint256 grantId = _submitGrant(1000e18);

        vm.prank(timelock);
        treasury.releaseMilestone(grantId, 0, grantee, 1000e18);

        vm.prank(grantee);
        treasury.withdraw(grantId, 0);

        vm.prank(grantee);
        vm.expectRevert(abi.encodeWithSelector(IGrantsTreasury.InsufficientBalance.selector, 0, 1));
        treasury.withdraw(grantId, 0);
    }

    function test_balance_reflectsEthHeld() public view {
        assertEq(treasury.balance(), 10 ether);
    }
}
