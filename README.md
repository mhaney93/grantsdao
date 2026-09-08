# GrantsDAO

A grants protocol where voting power is **earned through participation, not bought**.
Token holders fund a shared ETH treasury, then propose and vote on
**USD-denominated, milestone-gated** releases to grantees. Every disbursement
passes through an OpenZeppelin Governor + Timelock and a pull-over-push treasury.

Solidity 0.8.24 · Foundry · OpenZeppelin v5.6.1 · Chainlink Data Feeds ·
deployed and verified on Sepolia.

- **Live demo:** https://grantsdao-capstone.vercel.app (Sepolia)
- **Local walkthrough:** [`DEMO.md`](./DEMO.md) — full lifecycle via `cast` against Anvil
- **Security review:** [`SECURITY.md`](./SECURITY.md) — Slither + Echidna pass
- **Design notes / research:** [`planning.md`](./planning.md)

---

## Why it exists

Web3 public-goods funding tends to fail in one of two ways: a small committee
gatekeeps who gets funded, or funds are disbursed up front with no on-chain
accountability once the money leaves the treasury. GrantsDAO addresses both:

- **Participation-earned governance.** `GRANT` is a soulbound `ERC20Votes`
  token. It cannot be transferred or purchased — it is minted only by the
  `Earner` contract in response to on-chain actions (voting, having a proposal
  execute, delivering a milestone). Voting power tracks contribution.
- **Milestone escrow.** A grant is registered with milestones whose weights sum
  to exactly 100%. Each milestone is a separate governance proposal; the
  treasury only ever releases that milestone's slice.
- **USD denomination priced at execution.** Grants are requested in USD. The ETH
  amount is computed from the Chainlink ETH/USD feed at *release* time, not at
  proposal time, so price drift during the voting/timelock window doesn't
  over- or under-pay the grantee.

---

## Architecture

Seven contracts, wired in dependency order by [`script/Deploy.s.sol`](./script/Deploy.s.sol):

| Contract | Responsibility | Key base / pattern |
|---|---|---|
| [`GrantToken`](./contracts/GrantToken.sol) | Soulbound `ERC20Votes` governance token (`GRANT`) | `_update` override rejects peer transfers; mint-only via `MINTER_ROLE` |
| [`Earner`](./contracts/Earner.sol) | Mints `GRANT` rewards for participation actions | `RECORDER_ROLE`; per-`(account, proposalId, action)` dedup |
| [`PriceFeed`](./contracts/PriceFeed.sol) | Chainlink ETH/USD wrapper; `usdToEth()` | staleness (`maxAge`) + incomplete-round + non-positive-answer checks |
| [`GrantRegistry`](./contracts/GrantRegistry.sol) | Grant metadata, milestone definitions, release state | `AccessControlDefaultAdminRules`; `GOVERNOR_ROLE` / `TREASURY_ROLE` |
| `TimelockController` | Executes passed proposals after a delay | stock OZ |
| [`GrantsTreasury`](./contracts/GrantsTreasury.sol) | Holds ETH; releases milestone-by-milestone | `ReentrancyGuardTransient`; pull-over-push; `onlyTimelock` |
| [`GrantsGovernor`](./contracts/GrantsGovernor.sol) | OZ Governor stack; ties proposals to registry entries | Settings + CountingSimple + Votes + QuorumFraction + TimelockControl |

Interfaces for all custom contracts live in [`interfaces/`](./interfaces).

### Lifecycle

1. **Grantee** calls `GrantRegistry.submitGrant(title, descriptionURI, usdAmount, milestones[])`
   (permissionless). Milestone basis points must sum to `10_000` or it reverts.
2. **Any `GRANT` holder** calls `GrantsGovernor.proposeGrantRelease(grantId, milestone, description)`.
   The governor validates the grant exists, builds the treasury calldata for
   that milestone's USD slice, links the proposal ID in the registry, and marks
   it the single DAO-wide active milestone proposal.
3. **Voters** call `castVote`. Each vote that carried weight mints a `Voted`
   reward via `Earner`.
4. Proposal succeeds → `queue` → Timelock delay → `execute`.
5. On execution `GrantsTreasury.releaseMilestone` runs: it **re-derives the USD
   amount from the registry independently** of the governor calldata, converts
   to ETH at the current Chainlink price, checks solvency, records a pending
   withdrawal (effects before interactions), and marks the milestone released.
   `Earner` then rewards the proposer (`ProposalSubmitted`) and the grantee
   (`MilestoneApproved`).
6. **Grantee** calls `GrantsTreasury.withdraw(grantId, milestone)` to pull the ETH.

---

## Trust boundary & permission model

| Authority | Held by | Scope |
|---|---|---|
| `MINTER_ROLE` (GrantToken) | `Earner` only | mint `GRANT`; no other minter exists after deploy |
| `RECORDER_ROLE` (Earner) | `GrantsGovernor` only | record participation actions → trigger mint |
| `GOVERNOR_ROLE` (GrantRegistry) | `GrantsGovernor` | `linkProposal`, `updateStatus` |
| `TREASURY_ROLE` (GrantRegistry) | `GrantsTreasury` | `markMilestoneReleased` |
| `onlyTimelock` (GrantsTreasury) | `TimelockController` | `releaseMilestone` — the only path that moves ETH out |
| Timelock `PROPOSER` / `CANCELLER` | `GrantsGovernor` | queue / cancel operations |
| Timelock admin | **renounced by deployer** in the deploy script | — |

Design decisions worth calling out:

- **The treasury does not trust the governor's calldata.** `releaseMilestone`
  takes `usdAmount` as an argument but recomputes the expected value from
  `registry.getGrant(...)` and reverts on mismatch (`UsdAmountMismatch`), and
  checks `grant.grantee == grantee` (`GranteeMismatch`). A malformed or
  tampered proposal payload can't redirect funds or change the amount.
- **Price exposure is never locked in early.** Conversion happens in
  `releaseMilestone`, at the execution block — verified against the real Sepolia
  feed in [`test/PriceFeedFork.t.sol`](./test/PriceFeedFork.t.sol).
- **Rewards can't be farmed.** `Earner` dedups every
  `(account, proposalId, action)` triple. The `_castVote` hook only rewards
  votes with non-zero weight. Proposer/grantee rewards fire from
  `_executeOperations` — *after* execution — so proposing releases that never
  pass earns nothing. Zero-address checks in the treasury constructor prevent a
  deployer mistake from bricking `releaseMilestone`.
- **One active milestone proposal DAO-wide** so voter attention can't be diluted
  by competing or duplicate release proposals.

Known findings reviewed and accepted (with rationale) are in
[`SECURITY.md`](./SECURITY.md) — chiefly a Slither `reentrancy-events`
log-ordering note on two functions whose only external calls are to trusted,
access-controlled internal contracts with no reentrant callback surface.

---

## Tests

```shell
forge test                 # 57 pass, 1 skipped without SEPOLIA_RPC_URL
SEPOLIA_RPC_URL=... forge test   # runs the Chainlink fork tests too
```

| Suite | File | Covers |
|---|---|---|
| Unit | `test/*.t.sol` | each contract in isolation |
| Governor integration | [`test/GrantsGovernor.t.sol`](./test/GrantsGovernor.t.sol) | full propose → vote → queue → execute → withdraw; quorum-not-reached defeat; unregistered-grant revert; reward dedup; direct-call access-control gating |
| Oracle fork | [`test/PriceFeedFork.t.sol`](./test/PriceFeedFork.t.sol) | live Sepolia ETH/USD feed; skips gracefully without RPC |

**Property-based ([Echidna](./test/echidna), `--test-limit 50000`):**

- `EarnerEchidna` — `GrantToken.totalSupply()` always equals an independent
  ghost sum of unique rewarded `(participant, proposalId, action)` triples:
  no duplicate or unauthorized minting is reachable. **50,199 calls, 0 failures.**
- `TreasuryEchidna` — treasury balance plus everything ever withdrawn never
  exceeds everything ever deposited: the treasury can't be tricked into paying
  out more ETH than it received. **50,307 calls, 0 failures.**

Static analysis: Slither via the crytic Docker image — see `SECURITY.md`.
CI ([`.github/workflows/test.yml`](./.github/workflows/test.yml)) runs `forge fmt
--check`, `forge build --sizes`, and `forge test` on every push and PR.

---

## Build & deploy

```shell
forge build
```

`script/Deploy.s.sol` deploys all seven contracts, wires every role, and
renounces the deployer's timelock admin. The Chainlink feed address is an env
var (`CHAINLINK_ETH_USD`), so the same script targets Sepolia, Arbitrum Sepolia,
or Base Sepolia unchanged. See [`.env.example`](./.env.example) for all
overridable parameters (`TIMELOCK_MIN_DELAY`, `VOTING_DELAY`, `VOTING_PERIOD`,
`PROPOSAL_THRESHOLD`, `QUORUM_NUMERATOR`).

### Deployed on Sepolia (2026-08-11, all verified on Etherscan)

| Contract | Address |
|---|---|
| GrantToken | `0x7F1ea20141c9E32E49F41e97C3fD4a0002197ecc` |
| Earner | `0x3B4998293664Df43f8deC1dBc71175DDA5984d51` |
| PriceFeed | `0x4E7DE729A9611e61af4a42B4215617bB34dCc43B` |
| GrantRegistry | `0x7db0fBA11858e1B1431F4C7a4b0cA07e53511b7c` |
| TimelockController | `0xDb8Dd9f6769d48BDff46Da821FfDfC758492A646` |
| GrantsTreasury | `0x5a61dC95f9CFe1F90Fec14202e2C94a5CC603EB0` |
| GrantsGovernor | `0x4dC07744BEF3eB11ddccAd858B7c191884ceAf55` |

---

## Frontend

`frontend/` — React + Vite + ethers.js v6, covering the full lifecycle
(connect, browse, submit, propose, vote, queue, execute, withdraw) for
single-milestone grants. See [`frontend/README.md`](./frontend/README.md).

---

## Repo layout

```
contracts/      six custom contracts
interfaces/     interface per custom contract
script/         Deploy.s.sol — deploy + role wiring + admin renounce
test/           Foundry unit + integration + fork tests
test/echidna/   property-based harnesses
frontend/       React + ethers.js v6 UI
DEMO.md         live cast walkthrough on Anvil
SECURITY.md     Slither + Echidna review
planning.md     problem framing, architecture, design decisions
```

## License

MIT
