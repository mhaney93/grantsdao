# Security Review

This document covers the Module 14 vulnerability review (already fixed in
earlier commits — see `planning.md`) plus the follow-up Slither + Echidna pass
done ahead of Module 16 submission.

## Slither

Run via Docker (same image used for the module14 exercises):

```
docker run --rm -v "$(pwd)":/src -w /src ghcr.io/crytic/echidna/echidna \
  sh -c "slither . --exclude-dependencies --exclude-informational"
```

### Findings addressed this pass

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | Low | `GrantsTreasury` constructor took `timelock_`/`registry_`/`priceFeed_` with no zero-address check. A zero `timelock` would permanently brick `releaseMilestone` (nobody could ever satisfy `onlyTimelock`). | Added `ZeroAddress` error (`IGrantsTreasury`) and a guard in the constructor rejecting all three params. |

### Findings reviewed and accepted (false positive / by design / accepted risk)

| # | Finding | Rationale |
|---|---|---|
| 2 | `reentrancy-events`: `Earner.recordAction` (`token.mint` before `emit TokensEarned`) and `GrantsGovernor.proposeGrantRelease` (`registry.linkProposal` before `emit GrantProposalCreated`) emit their event *after* an external call, so a reentrant callee could observe on-chain state ahead of the corresponding event. | Accepted as-is. `GrantToken.mint` and `GrantRegistry.linkProposal` are both trusted, access-controlled internal contracts with no reentrant callback surface (no external calls to attacker-controlled addresses), so the log-ordering has no exploitable consequence. No state-changing effects occur after either external call in either function. Reordering was considered but not applied — noted here as a known finding rather than a code change. |
| 3 | `uninitialized-local`: `total` in `GrantRegistry.submitGrant` | Solidity default-initializes `uint256` to `0`, which is exactly the accumulator's required starting value. |
| 4 | `unused-return`: `PriceFeed.latestPrice()` ignores `startedAt` from `latestRoundData()` | Only `updatedAt` (staleness) and `answeredInRound` (completeness) are needed for the freshness checks; `startedAt` has no use here. |
| 5 | `timestamp`: `block.timestamp - updatedAt > maxAge` | This *is* the staleness check by design — miner timestamp manipulation of a few seconds has no meaningful effect on a check with a `maxAge` measured in minutes/hours. |

All 57 Foundry tests (58 total, 1 skipped without `SEPOLIA_RPC_URL`) still pass after the fix.

## Echidna

Two property-based harnesses under `test/echidna/`, run with:

```
docker run --rm -v "$(pwd)":/src -w /src ghcr.io/crytic/echidna/echidna \
  sh -c "echidna test/echidna/<Harness>.sol --contract <Harness> --test-mode assertion --test-limit 50000"
```

### `EarnerEchidna.sol` — anti-Sybil minting invariant

Directly targets the class of bug fixed in the Module 14 capstone review
(unconditional `Earner.recordAction` minting that let a zero-capital attacker
Sybil-mint GRANT). Fuzzes `recordAction` across a bounded participant/proposalId/
action space and asserts `GrantToken.totalSupply()` always equals an
independently-tracked ghost sum of unique `(participant, proposalId, action)`
triples ever rewarded — i.e. no duplicate or unauthorized minting is reachable
through any call sequence.

**Result: 50,199 calls, 0 failures.**

### `TreasuryEchidna.sol` — treasury solvency invariant

Covers the "treasury balance never decreases without a passed proposal"
property from `planning.md`'s Testing Plan. The harness plays the role of the
timelock (the only address allowed to call `releaseMilestone`) and fuzzes
deposits, grant submissions, milestone releases, and withdrawals. Asserts the
treasury's on-chain balance plus everything ever withdrawn never exceeds
everything ever deposited — i.e. the treasury can never be tricked into paying
out more ETH than it actually received.

**Result: 50,307 calls, 0 failures.**

## Summary

No new exploitable vulnerabilities found. The zero-address fix is
defense-in-depth hardening, not a live bug (it requires a deployer mistake at
construction). The event-ordering finding was reviewed and accepted as-is —
no state-consistency impact, since neither external call target has a
reentrant callback surface. The two Echidna harnesses independently confirm,
under fuzzing, the two invariants underpinning the contracts' core security
properties: no unauthorized token minting, and treasury solvency.
