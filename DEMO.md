# GrantsDAO — Module 16 Live Demo Walkthrough

Runs the full grant lifecycle (submit → propose → vote → queue → execute →
withdraw) against a local Anvil chain using `cast`, mirroring the proven
integration test `test_fullLifecycle_grantIsPaidOut` in
`test/GrantsGovernor.t.sol`. Every step below is a real transaction, not a
test run — good for screen-sharing during the presentation.

Two terminals: one running `anvil`, one running the `cast`/`forge` commands.

## 0. Setup

Terminal A:

```shell
anvil
```

Anvil prints 10 funded accounts + private keys. We'll use the first three:

```shell
DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
GRANTEE_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
VOTER1_PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
GRANTEE=$(cast wallet address --private-key $GRANTEE_PK)
VOTER1=$(cast wallet address --private-key $VOTER1_PK)
DEPLOYER=$(cast wallet address --private-key $DEPLOYER_PK)
RPC=http://127.0.0.1:8545
```

Deploy a mock Chainlink feed inline (the deploy script needs a real feed
address — `test/mocks/MockAggregatorV3.sol` gives us one without needing a
fork). Deploy everything else with `script/Deploy.s.sol`:

```shell
MOCK_FEED=$(forge create test/mocks/MockAggregatorV3.sol:MockAggregatorV3 \
  --rpc-url $RPC --private-key $DEPLOYER_PK --broadcast \
  --constructor-args 300000000000 | grep "Deployed to" | awk '{print $3}')

CHAINLINK_ETH_USD=$MOCK_FEED PRIVATE_KEY=$DEPLOYER_PK \
  TIMELOCK_MIN_DELAY=5 VOTING_DELAY=1 VOTING_PERIOD=5 \
  forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --broadcast -vvv
```

Copy the seven logged addresses into env vars:

```shell
TOKEN=<GrantToken address>
EARNER=<Earner address>
PRICEFEED=<PriceFeed address>
REGISTRY=<GrantRegistry address>
TIMELOCK=<TimelockController address>
TREASURY=<GrantsTreasury address>
GOVERNOR=<GrantsGovernor address>
```

## 1. Fund the treasury

```shell
cast send $TREASURY --value 10ether --rpc-url $RPC --private-key $DEPLOYER_PK
cast call $TREASURY "balance()(uint256)" --rpc-url $RPC
```

## 2. Seed voting power

`RECORDER_ROLE` on `Earner` is only granted to the governor by the deploy
script (so nobody can farm rewards outside governance). As the deployer
(who holds `DEFAULT_ADMIN_ROLE` on `Earner`), grant it to yourself once, just
to seed initial voter balances the same way `test/GrantsGovernor.t.sol`'s
`setUp()` does:

```shell
RECORDER_ROLE=$(cast call $EARNER "RECORDER_ROLE()(bytes32)" --rpc-url $RPC)
cast send $EARNER "grantRole(bytes32,address)" $RECORDER_ROLE $DEPLOYER \
  --rpc-url $RPC --private-key $DEPLOYER_PK

# Action.Voted = 0
cast send $EARNER "recordAction(address,uint256,uint8)" $VOTER1 1000001 0 \
  --rpc-url $RPC --private-key $DEPLOYER_PK

cast call $TOKEN "balanceOf(address)(uint256)" $VOTER1 --rpc-url $RPC
# -> 10000000000000000000 (10 GRANT)
```

Delegate so the balance becomes voting power (GrantToken is `ERC20Votes` —
balances don't count until delegated):

```shell
cast send $TOKEN "delegate(address)" $VOTER1 \
  --rpc-url $RPC --private-key $VOTER1_PK

cast call $TOKEN "getVotes(address)(uint256)" $VOTER1 --rpc-url $RPC
```

Mine one block so the delegation checkpoint is in the past for proposal
snapshots:

```shell
cast rpc anvil_mine 1 --rpc-url $RPC
```

## 3. Grantee submits a grant

One milestone, 100% of funds, $3000 requested:

```shell
cast send $REGISTRY \
  "submitGrant(string,string,uint256,(string,uint16,bool)[])" \
  "Build a thing" "ipfs://demo-cid" 3000000000000000000000 \
  "[(\"Ship v1\",10000,false)]" \
  --rpc-url $RPC --private-key $GRANTEE_PK

cast call $REGISTRY "totalGrants()(uint256)" --rpc-url $RPC
```

`grantId` is `0` (first grant).

## 4. Propose a milestone release

```shell
cast send $GOVERNOR "proposeGrantRelease(uint256,uint8,string)" \
  0 0 "Release milestone 1" \
  --rpc-url $RPC --private-key $VOTER1_PK
```

`proposalId` is deterministic (`keccak256` of targets/values/calldatas/description
hash), so recompute it with `hashProposal` instead of parsing logs — we need the
targets/calldata/hash for queue/execute anyway:

```shell
CALLDATA=$(cast calldata "releaseMilestone(uint256,uint8,address,uint256)" \
  0 0 $GRANTEE 3000000000000000000000)
DESC_HASH=$(cast keccak "Release milestone 1")

# awk strips cast's trailing "[2.5e76]" scientific-notation annotation
PID=$(cast call $GOVERNOR "hashProposal(address[],uint256[],bytes[],bytes32)(uint256)" \
  "[$TREASURY]" "[0]" "[$CALLDATA]" $DESC_HASH --rpc-url $RPC | awk '{print $1}')

cast call $GOVERNOR "grantIdOf(uint256)(uint256)" "$PID" --rpc-url $RPC
```

## 5. Vote

Mine past the 1-block voting delay, then vote For (support = 1):

```shell
cast rpc anvil_mine 2 --rpc-url $RPC
cast send $GOVERNOR "castVote(uint256,uint8)" "$PID" 1 \
  --rpc-url $RPC --private-key $VOTER1_PK
```

Voting mints another 10 GRANT to voter1 via the `Earner` reward hook —
show `balanceOf` before/after to prove the participation-reward loop works.

Mine past the voting period (5 blocks) and check state:

```shell
cast rpc anvil_mine 6 --rpc-url $RPC
cast call $GOVERNOR "state(uint256)(uint8)" "$PID" --rpc-url $RPC
# 4 = Succeeded
```

## 6. Queue and execute

The queue/execute calldata must exactly match what was proposed — same
target, value, calldata, and description hash we already built above
(`$CALLDATA`, `$DESC_HASH`) for `IGrantsTreasury.releaseMilestone(grantId, milestone, grantee, usdAmount)`:

```shell
cast send $GOVERNOR "queue(address[],uint256[],bytes[],bytes32)" \
  "[$TREASURY]" "[0]" "[$CALLDATA]" $DESC_HASH \
  --rpc-url $RPC --private-key $VOTER1_PK

cast rpc evm_increaseTime 6 --rpc-url $RPC
cast rpc anvil_mine 1 --rpc-url $RPC

cast send $GOVERNOR "execute(address[],uint256[],bytes[],bytes32)" \
  "[$TREASURY]" "[0]" "[$CALLDATA]" $DESC_HASH \
  --rpc-url $RPC --private-key $VOTER1_PK
```

Check the grant is marked Completed and the milestone released:

```shell
cast call $REGISTRY "getGrant(uint256)((uint256,address,string,string,uint256,uint256,uint8,(string,uint16,bool)[]))" 0 --rpc-url $RPC
```

## 7. Grantee withdraws

```shell
cast call $TREASURY "pendingWithdrawal(address,uint256,uint8)(uint256)" $GRANTEE 0 0 --rpc-url $RPC

BEFORE=$(cast balance $GRANTEE --rpc-url $RPC)
cast send $TREASURY "withdraw(uint256,uint8)" 0 0 \
  --rpc-url $RPC --private-key $GRANTEE_PK
cast balance $GRANTEE --rpc-url $RPC
```

Balance increases by ~1 ETH (3000 USD / $3000 per ETH from the mock feed,
minus gas).

## Talking points while running this

- **Every write path is role-gated** — `test_registryAndTreasuryRoles_gateAccessCorrectly`
  proves `GrantRegistry.linkProposal` and `GrantsTreasury.releaseMilestone`
  revert on direct calls; only the governor/timelock can trigger them.
- **Pull-over-push**: step 6 only marks a pending withdrawal; the grantee
  pulls funds themselves in step 7 (`GrantsTreasury.withdraw`), avoiding
  push-payment reentrancy/DoS risk.
- **Oracle integration**: `PriceFeed.usdToEth` converts the USD grant amount
  to ETH at *execution* time (step 6), not proposal time — demonstrated
  against a live Sepolia feed in `test/PriceFeedFork.t.sol`.
- **Reward loop**: `Earner` mints GRANT for `Voted` (step 5) and
  `ProposalSubmitted` — but only once execution succeeds (see
  `test_proposeGrantRelease_doesNotRewardUntilExecuted` — no reward at
  proposal time, GD-16 dedup fix).
- All tests: `forge test` (57 passed, 1 skipped without `SEPOLIA_RPC_URL`,
  58 total).

## MetaMask "Malicious site detected" warning

MetaMask's Blockaid scanner flags the live frontend (hosted on a generic
`*.vercel.app` subdomain) as a malicious site on first connect. This is a
category-level false positive, not a finding about this project specifically:

- All 7 contracts are verified on Etherscan (see addresses below) — Blockaid's
  own "Interacting with" contract warning clears once verified; only the
  site-hosting-pattern warning remains.
- Renaming the Vercel project to a fresh, never-before-used subdomain did
  **not** clear the flag — confirming it's a heuristic on the hosting pattern
  itself (free `*.vercel.app`/`*.netlify.app` domains are heavily abused by
  real wallet-drainer phishing kits), not a reputation issue tied to this
  specific URL.
- Safe to click "Connect Anyway": this is a Sepolia testnet deployment with
  only test ETH at risk, the full source is committed to git, and the
  contracts are independently verifiable on Etherscan.

## If something goes wrong live

Fall back to `forge test --match-test test_fullLifecycle_grantIsPaidOut -vvvv`
— same lifecycle, deterministic, verbose trace of every call.
