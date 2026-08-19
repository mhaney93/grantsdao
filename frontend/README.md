# GrantsDAO Frontend

Minimal React + Vite + ethers.js v6 UI over the GrantsDAO contracts, covering
the full grant lifecycle — submit, propose, vote, queue, execute, withdraw —
the read/write MVP surface called for in `../planning.md`'s roadmap.

## Setup

```shell
npm install
cp .env.example .env.local
```

Fill in `.env.local` with the six addresses logged by
`forge script script/Deploy.s.sol:Deploy` (see `../DEMO.md` for a full local
deployment walkthrough on Anvil). Point your wallet (e.g. MetaMask) at the
Anvil RPC (`http://127.0.0.1:8545`, chain ID `31337`) and import one of
Anvil's default private keys.

```shell
npm run dev
```

## What it does

- Reads treasury balance and your `GRANT` voting power.
- Lists all submitted grants with milestone status.
- Submits a new single-milestone grant (`GrantRegistry.submitGrant`).
- Proposes a milestone release (`GrantsGovernor.proposeGrantRelease`).
- Casts votes on an active proposal (`GrantsGovernor.castVote`).
- Queues a succeeded proposal (`GrantsGovernor.queue`).
- Executes a queued proposal once the timelock delay has elapsed
  (`GrantsGovernor.execute`) — the button is always shown once queued;
  the transaction reverts on-chain (and shows an inline error) if the
  delay hasn't elapsed yet.
- Withdraws released funds as the grantee (`GrantsTreasury.withdraw`) — only
  enabled for the connected account matching the grant's grantee, since
  `withdraw` pays `msg.sender` from that account's pending balance.

## Scope

The UI only ever proposes/releases the single milestone created by the
"Submit a grant" form (milestone index `0`, 100% of funds) — matching
`DEMO.md`'s walkthrough. Multi-milestone grants can still be submitted via
`cast` (see `DEMO.md`) but the UI won't drive later milestones through
governance.
