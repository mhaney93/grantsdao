# Capstone Project — Planning Document

## Project Name
**GrantsDAO** — A decentralized grants platform where token holders fund and vote on project proposals.

---

## Module 9 — Problem Definition & Research

### 1. Problem Statement

Public goods funding in web3 is broken in two ways:

- **Centralized control:** Most grant programs (foundations, labs, accelerators) rely on small committees to decide who gets funded. This creates gatekeeping, bias, and opacity.
- **No accountability:** Once grants are disbursed, there is little on-chain enforcement of milestones or deliverables. Funds disappear with no recourse.

There is no widely-adopted open protocol that lets a community of token holders collectively fund projects with USD-denominated grants, enforce milestone-based releases, and do all of it transparently on-chain.

### 2. Existing Solutions & Gaps

| Platform | What it does | Gap |
|---|---|---|
| Gitcoin Grants | Quadratic funding rounds run off-chain | Off-chain matching, centralized curation |
| Compound Governor | On-chain governance for protocol params | General-purpose; no grants-specific logic |
| Nouns DAO | Treasury-funded proposals via governance | No USD denomination, no milestone releases |
| Juicebox | Crowdfunding + treasury management | No governance voting on individual grants |

**Our unique approach:** A purpose-built grants DAO with:
- USD-denominated grant requests (Chainlink ETH/USD feed converts at execution time)
- Milestone-based fund releases (proposer unlocks tranches as work is delivered)
- On-chain voting via a soulbound participation token (no plutocracy — one-person-one-vote style earned through participation)
- Full OZ Governor + Timelock stack, audited and battle-tested

### 3. Target Users

- **Grantees:** Developers or teams applying for funding to build public goods or ecosystem tools.
- **Token holders / voters:** Community members who have earned participation tokens and vote on proposals.
- **Treasury contributors:** Anyone who funds the DAO treasury with ETH.

---

## Architecture Overview (draft — to be refined in Modules 10–11)

### Smart Contracts

| Contract | Purpose | Based on |
|---|---|---|
| `GrantToken.sol` | Soulbound ERC20Votes governance token | Module 7 `ParticipationToken` |
| `Earner.sol` | Distributes tokens for participation | Module 7 `Earner` |
| `GrantsTreasury.sol` | Holds ETH; releases to grantees via timelock | Module 7 `Treasury` |
| `GrantsGovernor.sol` | OZ Governor; propose/vote/execute grant releases | Module 7 `DAOGovernor` |
| `GrantRegistry.sol` | Stores proposals, milestone state, USD amounts | **New** |
| `PriceFeed.sol` | Chainlink ETH/USD wrapper; converts grant USD→ETH | **New** |

### Frontend

- React + Next.js
- ethers.js v6 for chain interaction
- Pages: Browse Proposals, Submit Proposal, Vote, Treasury Dashboard

### External Integrations

- **Chainlink Data Feeds** — ETH/USD price at grant execution time
- **Sepolia testnet** — primary deployment
- **Second testnet** (Arbitrum Sepolia or Base Sepolia) — multichain deployment script target

### Security Measures

- Access control (OZ `AccessControl`) on all admin functions
- `ReentrancyGuardTransient` on all ETH-moving functions
- Pull-over-push pattern for milestone releases
- Slither static analysis before final submission — done (2026-08-11), see `SECURITY.md`
- Echidna property-based tests on treasury invariants — done (2026-08-11), see `SECURITY.md`

### Testing Plan

- Foundry unit tests (full coverage of each contract)
- Fork tests (Sepolia fork with live Chainlink feed)
- Fuzz tests (proposal amounts, vote counts, milestone fractions)
- Echidna: treasury balance never decreases without a passed proposal — `test/echidna/TreasuryEchidna.sol`, 50,307 calls, 0 failures
- Echidna: no unauthorized/duplicate GRANT minting — `test/echidna/EarnerEchidna.sol`, 50,199 calls, 0 failures

---

## Roadmap (post-bootcamp)

| Phase | Goals |
|---|---|
| MVP (Module 16) | Core governor + registry + Chainlink feed + basic frontend |
| V2 | Quadratic voting option; multi-token treasuries (ERC20 + ETH) |
| V3 | Reputation system; cross-chain treasury via LayerZero |
| Mainnet | Audit, bug bounty, mainnet deploy |

---

---

## Module 10 — System Architecture & Contract Interfaces

### Architecture Diagram

| Contract | Type | Called By | Calls | Stores |
|---|---|---|---|---|
| `GrantsGovernor` | Core | Voters, Proposers | Registry, PriceFeed, Earner, Timelock | Proposal → Grant ID map |
| `GrantRegistry` | Core | Governor, Treasury | — | Grants, milestones, statuses |
| `GrantsTreasury` | Core | Timelock, Grantees | Registry | ETH balance, withdrawals |
| `TimelockController` | Core | Governor | Treasury | Queued operations |
| `GrantToken` | Support | Earner | — | Balances, voting power |
| `Earner` | Support | Governor | GrantToken | Participation records |
| `PriceFeed` | Support | Governor | Chainlink feed | — |

**External actor interactions:**

| Actor | Action | Target |
|---|---|---|
| Grantee | `submitGrant()` | `GrantRegistry` |
| Voter / Proposer | `proposeGrantRelease()`, `castVote()` | `GrantsGovernor` |
| Anyone | `deposit ETH` | `GrantsTreasury` |
| Grantee | `withdraw()` | `GrantsTreasury` |

### Data Flow — Happy Path

1. **Grantee** calls `GrantRegistry.submitGrant(title, URI, usdAmount, milestones[])` → `grantId` returned.
2. **Any token holder** calls `GrantsGovernor.proposeGrantRelease(grantId, milestone=0, description)`.
   - Governor calls `PriceFeed.usdToEth()` to compute the ETH amount for the proposal calldata.
   - Governor calls `GrantRegistry.linkProposal(grantId, proposalId)`.
3. **Voters** call `Governor.castVote(proposalId, support)`. `Earner.recordAction(voter, proposalId, Voted)` mints reward tokens.
4. Proposal passes → queued in **TimelockController** (48 h delay).
5. After delay, anyone calls `Governor.execute(...)` → `GrantsTreasury.releaseMilestone(grantId, 0, grantee, ethAmount)`.
   - Treasury records a pending withdrawal.
   - Registry marks milestone 0 released.
6. **Grantee** calls `GrantsTreasury.withdraw(grantId, 0)` to pull ETH.
7. Repeat steps 2–6 for each subsequent milestone.

### Contract Interfaces (see `interfaces/` directory)

| File | Purpose |
|---|---|
| `IGrantToken.sol` | Soulbound ERC-20Votes; mint-only |
| `IEarner.sol` | Participation rewards distributor |
| `IGrantsTreasury.sol` | ETH vault; pull-over-push milestone releases |
| `IPriceFeed.sol` | Chainlink ETH/USD wrapper |
| `IGrantRegistry.sol` | Grant + milestone storage and state machine |
| `IGrantsGovernor.sol` | Governor extension for grant-release proposals |

---

## Module 11 — Smart Contract Structure Draft

All six contracts are drafted in `capstoneProject/contracts/`. Each implements its
corresponding interface from `capstoneProject/interfaces/` and follows the patterns
established in Module 7. Full logic will be completed in Modules 13–16.

| File | Inherits / Key OZ Imports | Notes |
|---|---|---|
| `GrantToken.sol` | `ERC20Votes`, `AccessControlDefaultAdminRules` | Soulbound `_update` override; `MINTER_ROLE` for Earner |
| `Earner.sol` | `AccessControlDefaultAdminRules` | `RECORDER_ROLE` for governor/registry; per-(account, proposalId, action) dedup |
| `PriceFeed.sol` | — | Chainlink AggregatorV3 wrapper; staleness + validity checks |
| `GrantRegistry.sol` | `AccessControlDefaultAdminRules` | `GOVERNOR_ROLE` + `TREASURY_ROLE`; milestone basis-points validation |
| `GrantsTreasury.sol` | `ReentrancyGuardTransient` | Pull-over-push; `onlyTimelock` on `releaseMilestone` |
| `GrantsGovernor.sol` | Full OZ Governor stack + Timelock | `proposeGrantRelease` wires registry + pricefeed + earner; `_castVote` hook mints rewards |

---

## Module 12 — Instructor Review & Pitch

Module 12 requires booking a 1-on-1 session with the instructor to present the
project idea and architecture, get feedback, and refine the plan before
development begins in Module 13.

### Pitch Summary (for the session)

- **Problem:** Grants funding in web3 is either centrally gatekept (foundations,
  committees) or has no on-chain accountability once funds are disbursed.
- **Solution:** GrantsDAO — a purpose-built grants protocol combining USD-denominated
  grant requests (Chainlink price feed), milestone-based fund releases, and
  soulbound-token governance (earned via participation, not bought).
- **Architecture:** 6 contracts — `GrantToken` (soulbound ERC20Votes), `Earner`
  (participation rewards), `PriceFeed` (Chainlink wrapper), `GrantRegistry`
  (grant/milestone state), `GrantsTreasury` (pull-over-push ETH vault), `GrantsGovernor`
  (OZ Governor + Timelock, wires the rest together). See Module 10/11 sections above
  for the full data flow and interface breakdown.
- **Differentiation:** existing tools (Gitcoin, Compound Governor, Nouns, Juicebox)
  each cover part of this — none combine USD-denominated grants + milestone escrow +
  participation-earned voting in one protocol.
- **What's built so far:** interfaces (Module 10) and contract skeletons following
  Module 7 patterns (Module 11). No business logic yet — that starts Module 13.
- **Open questions:**
  - Is the soulbound participation-token voting model sound, or does it need a
    decay/delegation mechanism to avoid stale voting power?
  - Milestone basis-points validation — enforce at registry or governor level?
  - Second-testnet deployment target: Arbitrum Sepolia vs Base Sepolia?

---

## Module Progress

- [x] Module 9 — Problem definition, research, unique approach
- [x] Module 10 — System architecture diagram, contract interfaces
- [x] Module 11 — Smart contract structure draft, core function signatures
- [x] Module 12 — Instructor 1-on-1 review, feedback, refine plan (2026-07-14: instructor pleased, no changes requested)
- [x] Module 13 — Core contract logic, unit tests, oracle integration (see Testing section below)
- [x] Module 15 — Deployment script (`script/Deploy.s.sol`); dry-run verified end-to-end on local Anvil
- [ ] Module 16 — Presentation prep

### Frontend (started ahead of Module 16)

`frontend/` — React + Vite + ethers.js v6, per the Module 9 architecture plan.
Full lifecycle wired into the UI: connect wallet, browse grants, submit a
grant, propose a milestone release, vote, queue, execute, and withdraw. See
`frontend/README.md` for exact scope (single-milestone grants only). Verified
against a live local Anvil deployment — the app's exact read/write call paths
(including `queue`/`execute`/`withdraw`) confirmed working end-to-end via a
scripted ethers.js run that reproduced the full lifecycle and matched the
grantee's ETH balance increasing by the expected amount.

### Deployment (Module 15)

`script/Deploy.s.sol` deploys and wires all seven contracts (GrantToken, Earner,
PriceFeed, GrantRegistry, TimelockController, GrantsTreasury, GrantsGovernor) in
dependency order, then grants `MINTER_ROLE`, `RECORDER_ROLE`, `GOVERNOR_ROLE`,
`TREASURY_ROLE`, and timelock `PROPOSER_ROLE`/`CANCELLER_ROLE` before renouncing
the deployer's timelock admin role — matching the wiring sequence proven in
`test/GrantsGovernor.t.sol`. The Chainlink feed address is a required env var
(`CHAINLINK_ETH_USD`), so the same script targets Sepolia or either second-testnet
candidate (Arbitrum Sepolia / Base Sepolia) without code changes — see
`.env.example` for feed addresses and other overridable parameters. Verified with
a full broadcast against local Anvil (all 7 contracts deployed, roles wired,
`ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`).

**Deployed to Sepolia (2026-08-11, later same day) — current:**

| Contract | Address |
| --- | --- |
| GrantToken | `0x7F1ea20141c9E32E49F41e97C3fD4a0002197ecc` |
| Earner | `0x3B4998293664Df43f8deC1dBc71175DDA5984d51` |
| PriceFeed | `0x4E7DE729A9611e61af4a42B4215617bB34dCc43B` |
| GrantRegistry | `0x7db0fBA11858e1B1431F4C7a4b0cA07e53511b7c` |
| TimelockController | `0xDb8Dd9f6769d48BDff46Da821FfDfC758492A646` |
| GrantsTreasury | `0x5a61dC95f9CFe1F90Fec14202e2C94a5CC603EB0` |
| GrantsGovernor | `0x4dC07744BEF3eB11ddccAd858B7c191884ceAf55` |

All 7 auto-verified on Etherscan (identical bytecode to the prior deploy — no
contract source changed between the two, only frontend work). Role wiring
confirmed on-chain (`hasRole` checks), timelock admin renounced. Frontend live
at https://grantsdao-capstone.vercel.app, wired via `frontend/.env.production`.

**Why a same-day second redeploy:** a user testing the live demo cast a vote
that succeeded but silently missed its `Voted` GRANT reward — traced to a
transaction that used 196,230 of a 199,050 gas limit (98.6%, only 2,820 gas of
headroom), strong evidence MetaMask's raw gas estimate undershot and the
reward-mint inside `_castVote`'s `try/catch` ran out of gas and was silently
swallowed while the vote itself still succeeded. Fixed by padding every
frontend write transaction's gas estimate by 30% (`sendWithGasBuffer` in
`App.tsx`) rather than trusting the raw MetaMask estimate. Chose a full fresh
redeploy (rather than manually crediting the missed reward) to start the demo
state clean. Treasury funding is a manual step via the frontend's "Fund
treasury" panel, not scripted.

### Testing (started ahead of Module 13, continued in Module 13)

Foundry project scaffolded at the repo root of `capstoneProject/` (`foundry.toml`,
OpenZeppelin v5.6.1 + forge-std installed under `lib/`). Unit tests written for all
six contracts, including a full `GrantsGovernor` integration suite:

| Contract | Test file | Tests |
|---|---|---|
| `GrantToken` | `test/GrantToken.t.sol` | 7 |
| `Earner` | `test/Earner.t.sol` | 8 |
| `PriceFeed` | `test/PriceFeed.t.sol` | 8 (uses `test/mocks/MockAggregatorV3.sol`) |
| `GrantRegistry` | `test/GrantRegistry.t.sol` | 11 |
| `GrantsTreasury` | `test/GrantsTreasury.t.sol` | 8 |
| `GrantsGovernor` | `test/GrantsGovernor.t.sol` | 5 (full deployment wiring: Timelock, Token, Earner, PriceFeed, Registry, Treasury, Governor) |
| `PriceFeed` (fork) | `test/PriceFeedFork.t.sol` | 3 (live Sepolia Chainlink ETH/USD feed; skips gracefully without `SEPOLIA_RPC_URL`) |

47/47 unit tests passing, plus 3 fork tests (50 total, 1 skipped when run without
`SEPOLIA_RPC_URL`). `GrantsGovernor.t.sol` covers the full propose → vote → queue →
execute → withdraw lifecycle, quorum-not-reached defeat, unregistered-grant revert,
Earner reward dedup on vote, and direct-call access-control gating on the registry
and treasury.

**Oracles (Module 13 task: "Implement oracles for the capstone project, if
applicable"):** Applicable, and already implemented — `PriceFeed.sol` is a Chainlink
AggregatorV3 wrapper (staleness check via `maxAge`, `<=0` answer rejection) used by
`GrantsGovernor.proposeGrantRelease` to convert USD grant amounts to ETH at proposal
time. Verified against the real Sepolia ETH/USD feed
(`0x694AA1769357215DE4FAC081bf1f309aDC325306`) via `test/PriceFeedFork.t.sol`, closing
out the "Fork tests (Sepolia fork with live Chainlink feed)" item from the Testing
Plan above.

Compiling against real OZ v5.6.1 surfaced two bugs in the Module 11 drafts, fixed
during test setup:
- `GrantToken.sol` — `override(ERC20Votes, IGrantToken)` doesn't compile; the actual
  base is `Votes`, not `ERC20Votes`, for `getVotes`/`getPastVotes`/`getPastTotalSupply`.
- `GrantsGovernor.sol` — `treasury_` constructor param needed to be `address payable`
  since `IGrantsTreasury` declares a payable `receive()`.
