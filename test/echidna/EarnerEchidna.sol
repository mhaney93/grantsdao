// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../contracts/GrantToken.sol";
import "../../contracts/Earner.sol";
import "../../interfaces/IEarner.sol";

/// @title EarnerEchidna
/// @notice Fuzzes Earner.recordAction directly as the RECORDER_ROLE holder to check
///         the anti-Sybil invariant behind the Module 14 capstone fix: GRANT supply
///         can never grow by more than one reward per unique
///         (participant, proposalId, action) triple, no matter what sequence of
///         recordAction calls Echidna throws at it.
contract EarnerEchidna {
    GrantToken internal token;
    Earner internal earner;

    /// @dev Ghost accounting: sum of rewards actually owed, mirroring Earner's own
    ///      _recorded bookkeeping, kept independently so a bug in Earner can't also
    ///      corrupt the oracle checking it.
    uint256 internal expectedSupply;
    mapping(address => mapping(uint256 => mapping(uint8 => bool))) internal seen;

    constructor() {
        token = new GrantToken(address(this));
        earner = new Earner(address(this), address(token));
        token.grantRole(token.MINTER_ROLE(), address(earner));
        earner.grantRole(earner.RECORDER_ROLE(), address(this));
    }

    /// @dev Fuzzed entry point. Bounds inputs so Echidna explores a small address/id
    ///      space thoroughly instead of getting lost in a huge sparse one.
    function recordAction(uint8 participantSeed, uint256 proposalId, uint8 actionSeed) public {
        address participant = address(uint160(uint256(participantSeed % 5) + 1));
        IEarner.Action action = IEarner.Action(actionSeed % 4);
        proposalId = proposalId % 5;

        uint256 rewardBefore = earner.rewardFor(action);
        bool alreadySeen = seen[participant][proposalId][uint8(action)];

        try earner.recordAction(participant, proposalId, action) {
            // A successful call must mean this exact triple had never been recorded.
            assert(!alreadySeen);
            seen[participant][proposalId][uint8(action)] = true;
            expectedSupply += rewardBefore;
        } catch {
            // Replay of an already-recorded triple is the only expected revert path
            // (RECORDER_ROLE is fixed/granted once, so access control can't fail here).
            assert(alreadySeen);
        }
    }

    /// @notice Core invariant: on-chain GRANT supply always matches the ghost total
    ///         of unique triples actually rewarded — no free/duplicate minting.
    function echidna_supply_matches_unique_rewards() public view returns (bool) {
        return token.totalSupply() == expectedSupply;
    }
}
