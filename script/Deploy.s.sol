// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "../contracts/GrantToken.sol";
import "../contracts/Earner.sol";
import "../contracts/PriceFeed.sol";
import "../contracts/GrantRegistry.sol";
import "../contracts/GrantsTreasury.sol";
import "../contracts/GrantsGovernor.sol";

/// @dev Deploy order:
///      1. GrantToken   2. Earner   3. PriceFeed   4. GrantRegistry
///      5. TimelockController   6. GrantsTreasury   7. GrantsGovernor
///      Then wire roles so the DAO controls its own registry and treasury.
///
///      Env vars:
///        PRIVATE_KEY          deployer key (required)
///        CHAINLINK_ETH_USD    Chainlink ETH/USD AggregatorV3 feed address for the
///                             target chain (required — e.g. Sepolia, Arbitrum Sepolia,
///                             Base Sepolia; see planning.md for candidate addresses)
///        PRICE_MAX_AGE        staleness window in seconds (optional, default 1 hour)
///        TIMELOCK_MIN_DELAY   timelock delay in seconds (optional, default 1 hour —
///                             short for testnet demos; use 2 days in production)
///        VOTING_DELAY         blocks before voting starts (optional, default 1)
///        VOTING_PERIOD        blocks voting stays open (optional, default 300)
///        PROPOSAL_THRESHOLD   min GRANT balance to propose (optional, default 0)
///        QUORUM_NUMERATOR     quorum percentage (optional, default 4)
contract Deploy is Script {
    struct GovernorParams {
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumNumerator;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address feed = vm.envAddress("CHAINLINK_ETH_USD");
        uint256 priceMaxAge = vm.envOr("PRICE_MAX_AGE", uint256(1 hours));
        uint256 timelockMinDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(1 hours));
        GovernorParams memory gp = GovernorParams({
            votingDelay: uint48(vm.envOr("VOTING_DELAY", uint256(1))),
            votingPeriod: uint32(vm.envOr("VOTING_PERIOD", uint256(300))),
            proposalThreshold: vm.envOr("PROPOSAL_THRESHOLD", uint256(0)),
            quorumNumerator: vm.envOr("QUORUM_NUMERATOR", uint256(4))
        });

        vm.startBroadcast(pk);
        _deploy(deployer, feed, priceMaxAge, timelockMinDelay, gp);
        vm.stopBroadcast();
    }

    struct Deployment {
        GrantToken token;
        Earner earner;
        PriceFeed priceFeed;
        GrantRegistry registry;
        TimelockController timelock;
        GrantsTreasury treasury;
        GrantsGovernor governor;
    }

    function _deploy(
        address deployer,
        address feed,
        uint256 priceMaxAge,
        uint256 timelockMinDelay,
        GovernorParams memory gp
    ) private {
        Deployment memory d;

        // 1. Soulbound governance token (deployer holds DEFAULT_ADMIN_ROLE; grants
        //    MINTER_ROLE to Earner below).
        d.token = new GrantToken(deployer);

        // 2. Earner — mints GRANT for on-chain participation.
        d.earner = new Earner(deployer, address(d.token));

        // 3. Chainlink ETH/USD wrapper used to price grant releases.
        d.priceFeed = new PriceFeed(feed, priceMaxAge);

        // 4. Registry — stores grants, milestones, and their status.
        d.registry = new GrantRegistry(deployer);

        // 5. Timelock — deployer is temporary admin so we can wire roles before
        //    renouncing; open executor role, no proposers yet (governor added below).
        address[] memory noProposers = new address[](0);
        address[] memory openExecutor = new address[](1);
        openExecutor[0] = address(0);
        d.timelock = new TimelockController(timelockMinDelay, noProposers, openExecutor, deployer);

        // 6. Treasury — only the timelock can release milestone funds.
        d.treasury = new GrantsTreasury(address(d.timelock), address(d.registry), address(d.priceFeed));

        // 7. Governor — wires registry + priceFeed + earner, executes through timelock.
        d.governor = new GrantsGovernor(
            IVotes(address(d.token)),
            d.timelock,
            address(d.registry),
            payable(address(d.treasury)),
            address(d.earner),
            gp.votingDelay,
            gp.votingPeriod,
            gp.proposalThreshold,
            gp.quorumNumerator
        );

        _wireRoles(d, deployer);
        _logAddresses(d);
    }

    function _wireRoles(Deployment memory d, address deployer) private {
        d.token.grantRole(d.token.MINTER_ROLE(), address(d.earner));
        d.earner.grantRole(d.earner.RECORDER_ROLE(), address(d.governor));
        d.registry.grantRole(d.registry.GOVERNOR_ROLE(), address(d.governor));
        d.registry.grantRole(d.registry.TREASURY_ROLE(), address(d.treasury));

        d.timelock.grantRole(d.timelock.PROPOSER_ROLE(), address(d.governor));
        d.timelock.grantRole(d.timelock.CANCELLER_ROLE(), address(d.governor));

        // Renounce timelock admin — from this point, all timelock actions require
        // a DAO vote. Comment out to keep the deployer as an emergency admin during
        // the testnet phase.
        d.timelock.renounceRole(d.timelock.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _logAddresses(Deployment memory d) private pure {
        console2.log("GrantToken         :", address(d.token));
        console2.log("Earner             :", address(d.earner));
        console2.log("PriceFeed          :", address(d.priceFeed));
        console2.log("GrantRegistry      :", address(d.registry));
        console2.log("TimelockController :", address(d.timelock));
        console2.log("GrantsTreasury     :", address(d.treasury));
        console2.log("GrantsGovernor     :", address(d.governor));
    }
}
