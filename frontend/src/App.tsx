import { useCallback, useEffect, useState, type MouseEvent } from 'react';
import {
  BrowserProvider, Contract, Interface, ZeroAddress, formatEther, isAddress, keccak256, parseEther, toUtf8Bytes,
  type Signer,
} from 'ethers';
import { ADDRESSES, CHAIN_ID, DEPLOY_BLOCK, DEPLOYER_ADDRESS } from './config';
import RegistryAbi from './abi/GrantRegistry.json';
import GovernorAbi from './abi/GrantsGovernor.json';
import TreasuryAbi from './abi/GrantsTreasury.json';
import TokenAbi from './abi/GrantToken.json';
import EarnerAbi from './abi/Earner.json';
import './App.css';

// Every custom error our contracts can revert with, merged into one Interface
// so any of them can be decoded regardless of which contract a call targeted.
const ALL_ABIS = [RegistryAbi, GovernorAbi, TreasuryAbi, TokenAbi, EarnerAbi];
const errorIface = new Interface(
  ALL_ABIS.flatMap((abi) => abi.filter((f: any) => f.type === 'error')),
);

// MetaMask's transaction flow (as opposed to a plain eth_call through ethers'
// own provider) doesn't always hand ethers the raw revert bytes in the shape
// it needs to auto-decode a custom error against our ABI, even when the ABI
// has the right entry — ethers then falls back to a generic "unknown custom
// error" message. Dig the raw hex out of wherever MetaMask nested it and
// decode it ourselves instead of trusting ethers' automatic decoding.
function findRevertData(e: any): string | undefined {
  const candidates = [
    e?.data, e?.error?.data, e?.info?.error?.data, e?.info?.error?.data?.data,
    e?.data?.data, e?.error?.data?.data,
  ];
  return candidates.find((d) => typeof d === 'string' && d.startsWith('0x') && d.length >= 10);
}

// Friendlier text for the errors most likely to come up during normal use;
// anything else still shows as a readable `ErrorName(args)` fallback below.
const FRIENDLY_ERRORS: Record<string, string> = {
  GovernorAlreadyCastVote: 'You already voted on this proposal.',
  ActiveMilestoneProposalExists: 'Another milestone proposal is still active — only one may be outstanding at a time.',
  AlreadyRecorded: 'That reward has already been recorded for this address.',
};

function decodeCustomError(e: any): string | undefined {
  const data = findRevertData(e);
  if (!data) return undefined;
  try {
    const parsed = errorIface.parseError(data);
    if (!parsed) return undefined;
    if (FRIENDLY_ERRORS[parsed.name]) return FRIENDLY_ERRORS[parsed.name];
    const args = parsed.args.map((a) => (typeof a === 'bigint' ? a.toString() : String(a)));
    return args.length > 0 ? `${parsed.name}(${args.join(', ')})` : parsed.name;
  } catch {
    return undefined;
  }
}

// Ethers wraps unrecognized RPC errors (e.g. from MetaMask) as a generic
// "could not coalesce error" and buries the actual reason in nested provider
// fields. Dig those out so the UI shows something actionable.
function describeError(e: any): string {
  console.error(e);
  const decoded = decodeCustomError(e);
  if (decoded) return decoded;
  const nested = e?.info?.error?.message ?? e?.error?.message ?? e?.info?.error?.data?.message;
  const primary = e?.shortMessage ?? e?.reason ?? e?.message;
  if (nested && nested !== primary) return `${primary ?? 'Error'}: ${nested}`;
  return primary ?? String(e);
}

const PROPOSAL_STATES = [
  'Pending', 'Active', 'Canceled', 'Defeated',
  'Succeeded', 'Queued', 'Expired', 'Executed',
];

const EARNER_ACTIONS = ['Voted', 'ProposalSubmitted', 'MilestoneApproved', 'Seeded'];
const SEPOLIA_TX_URL = 'https://sepolia.etherscan.io/tx/';

type HistoryEntry = {
  blockNumber: number;
  txHash: string;
  label: string;
  detail: string;
  address: string;
};

// The registry only stores one governorProposalId per grant (overwritten on each
// proposeGrantRelease call), so the UI must remember which milestone the *current*
// proposal targets to correctly queue/execute it and to know when to move on to the
// next milestone. Persisted so it survives page reloads.
const PROPOSED_MILESTONE_KEY = 'grantsdao-proposed-milestones';

function loadProposedMilestones(): Record<string, number> {
  try {
    return JSON.parse(localStorage.getItem(PROPOSED_MILESTONE_KEY) ?? '{}');
  } catch {
    return {};
  }
}

function saveProposedMilestones(map: Record<string, number>) {
  localStorage.setItem(PROPOSED_MILESTONE_KEY, JSON.stringify(map));
}

// First milestone not yet marked released on-chain, or null if the grant is complete.
function nextMilestoneIndex(grant: Grant): number | null {
  const i = grant.milestones.findIndex((m) => !m.released);
  return i === -1 ? null : i;
}

function badgeClass(state: string | undefined): string {
  return `badge badge-${(state ?? 'pending').toLowerCase()}`;
}

function truncateId(id: bigint): string {
  const s = id.toString();
  return s.length > 12 ? `${s.slice(0, 6)}…${s.slice(-4)}` : s;
}

// Sepolia averages ~12s/block; used only to estimate when the voting window opens
// (proposalSnapshot is a block number, not a timestamp) between refreshes.
const SECONDS_PER_BLOCK = 12;

function formatCountdown(targetMs: number, nowMs: number): string {
  const remaining = targetMs - nowMs;
  if (remaining <= 0) return 'ready';
  const totalSeconds = Math.ceil(remaining / 1000);
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  return h > 0 ? `${h}h ${m}m ${s}s` : m > 0 ? `${m}m ${s}s` : `${s}s`;
}

// Public Sepolia RPC endpoints commonly cap eth_getLogs at a 10,000-block range,
// so a single queryFilter from the deploy block will fail once the chain has moved
// far enough past it. Split the range into windows under that cap.
const LOG_RANGE_CHUNK = 9_000;

async function queryFilterChunked(
  contract: Contract,
  filter: any,
  fromBlock: number,
  toBlock: number,
): Promise<any[]> {
  const results: any[] = [];
  for (let start = fromBlock; start <= toBlock; start += LOG_RANGE_CHUNK) {
    const end = Math.min(start + LOG_RANGE_CHUNK - 1, toBlock);
    const chunk = await contract.queryFilter(filter, start, end);
    results.push(...chunk);
  }
  return results;
}

const releaseDescription = (grantId: bigint, milestone: number) =>
  `Release milestone ${milestone + 1} for grant #${grantId}`;

const treasuryIface = new Interface(TreasuryAbi);

function buildReleaseArgs(grant: Grant, milestone: number) {
  const usdSlice = (grant.usdAmount * grant.milestones[milestone].basisPoints) / 10_000n;
  const calldata = treasuryIface.encodeFunctionData('releaseMilestone', [
    grant.id, milestone, grant.grantee, usdSlice,
  ]);
  const descriptionHash = keccak256(toUtf8Bytes(releaseDescription(grant.id, milestone)));
  return {
    targets: [ADDRESSES.treasury],
    values: [0n],
    calldatas: [calldata],
    descriptionHash,
  };
}

/// Truncated address (or any long string) with a click-to-copy button, so the
/// full value is never lost just because it's displayed shortened.
function CopyChip({ value, display }: { value: string; display?: string }) {
  const [copied, setCopied] = useState(false);

  const copy = async (e: MouseEvent) => {
    e.stopPropagation();
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Clipboard API unavailable (e.g. insecure context) — silently no-op.
    }
  };

  return (
    <span className="copy-chip" title={value}>
      {display ?? value}
      <button type="button" className="copy-btn" onClick={copy} aria-label="Copy to clipboard">
        {copied ? (
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3">
            <path d="M20 6 9 17l-5-5" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        ) : (
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <rect x="9" y="9" width="12" height="12" rx="2" />
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
          </svg>
        )}
      </button>
    </span>
  );
}

function AddressChip({ address }: { address: string }) {
  return <CopyChip value={address} display={`${address.slice(0, 6)}…${address.slice(-4)}`} />;
}

// MetaMask's raw eth_estimateGas can undershoot for calls with conditional
// try/catch branches (e.g. the reward-mint inside GrantsGovernor._castVote) --
// the main path succeeds within the tight estimate, but a secondary try/catch
// call can silently run out of gas and get swallowed with no error surfaced
// anywhere. Padding every write with a real buffer avoids that failure mode.
async function sendWithGasBuffer(contract: Contract, method: string, args: any[]) {
  const estimate: bigint = await contract[method].estimateGas(...args);
  const gasLimit = (estimate * 130n) / 100n;
  return contract[method](...args, { gasLimit });
}

type Milestone = { description: string; basisPoints: bigint; released: boolean };
type Grant = {
  id: bigint;
  grantee: string;
  title: string;
  descriptionURI: string;
  usdAmount: bigint;
  governorProposalId: bigint;
  status: bigint;
  milestones: Milestone[];
};

function App() {
  const [account, setAccount] = useState<string | null>(null);
  const [signer, setSigner] = useState<Signer | null>(null);
  const [treasuryBalance, setTreasuryBalance] = useState<string>('—');
  const [votingPower, setVotingPower] = useState<string>('—');
  const [tokenBalance, setTokenBalance] = useState<bigint>(0n);
  const [delegatee, setDelegatee] = useState<string>(ZeroAddress);
  const [delegateAddress, setDelegateAddress] = useState('');
  const [grants, setGrants] = useState<Grant[]>([]);
  const [proposalStates, setProposalStates] = useState<Record<string, string>>({});
  const [pendingWithdrawals, setPendingWithdrawals] = useState<Record<string, bigint>>({});
  const [proposedMilestones, setProposedMilestones] = useState<Record<string, number>>(loadProposedMilestones);
  // Estimated ms-epoch when voting opens (Pending state), derived from proposalSnapshot's
  // block number since Governor's clock is block-based, not timestamp-based.
  const [votingOpensAt, setVotingOpensAt] = useState<Record<string, number>>({});
  // Estimated ms-epoch when voting closes (Active state), derived the same way from proposalDeadline.
  const [votingEndsAt, setVotingEndsAt] = useState<Record<string, number>>({});
  // Exact ms-epoch when a queued proposal becomes executable, from the timelock via proposalEta.
  const [executableAt, setExecutableAt] = useState<Record<string, number>>({});
  const [now, setNow] = useState(() => Date.now());
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  const [form, setForm] = useState({ title: '', uri: '', usdAmount: '' });
  const [milestoneForm, setMilestoneForm] = useState([{ description: '', percent: '100' }]);
  const [fundAmount, setFundAmount] = useState('');
  const [bulkSeedAddresses, setBulkSeedAddresses] = useState('');
  const [bulkSeedResult, setBulkSeedResult] = useState<string | null>(null);
  const [rewardAmounts, setRewardAmounts] = useState<Record<string, string>>({});

  const [historyAddress, setHistoryAddress] = useState('');
  const [history, setHistory] = useState<HistoryEntry[]>([]);
  const [historyLoaded, setHistoryLoaded] = useState(false);
  const [showAllHistory, setShowAllHistory] = useState(false);

  const milestoneTotal = milestoneForm.reduce((sum, m) => sum + (Number(m.percent) || 0), 0);

  const addMilestone = useCallback(() => {
    setMilestoneForm((prev) => [...prev, { description: '', percent: '0' }]);
  }, []);

  const removeMilestone = useCallback((index: number) => {
    setMilestoneForm((prev) => prev.filter((_, i) => i !== index));
  }, []);

  const updateMilestone = useCallback((index: number, field: 'description' | 'percent', value: string) => {
    setMilestoneForm((prev) => prev.map((m, i) => (i === index ? { ...m, [field]: value } : m)));
  }, []);

  const readProvider = useCallback(() => {
    if (!(window as any).ethereum) throw new Error('No wallet found (install MetaMask).');
    return new BrowserProvider((window as any).ethereum);
  }, []);

  const connect = useCallback(async () => {
    setError(null);
    try {
      const provider = readProvider();
      await provider.send('eth_requestAccounts', []);
      const s = await provider.getSigner();
      setSigner(s);
      setAccount(await s.getAddress());
    } catch (e: any) {
      setError(describeError(e));
    }
  }, [readProvider]);

  const refresh = useCallback(async () => {
    setError(null);
    try {
      const provider = readProvider();
      const network = await provider.getNetwork();
      if (network.chainId !== CHAIN_ID) {
        throw new Error(`Wrong network: MetaMask is on chain ${network.chainId}, expected Sepolia (${CHAIN_ID}). Switch networks and refresh.`);
      }
      const treasury = new Contract(ADDRESSES.treasury, TreasuryAbi, provider);
      const registry = new Contract(ADDRESSES.registry, RegistryAbi, provider);
      const governor = new Contract(ADDRESSES.governor, GovernorAbi, provider);
      const token = new Contract(ADDRESSES.token, TokenAbi, provider);
      const earner = new Contract(ADDRESSES.earner, EarnerAbi, provider);

      const bal: bigint = await treasury.balance();
      setTreasuryBalance(formatEther(bal));

      const rewards: Record<string, string> = {};
      for (let i = 0; i < EARNER_ACTIONS.length; i++) {
        const amount: bigint = await earner.rewardFor(i);
        rewards[EARNER_ACTIONS[i]] = formatEther(amount);
      }
      setRewardAmounts(rewards);

      if (account) {
        const votes: bigint = await token.getVotes(account);
        setVotingPower(formatEther(votes));
        const balance: bigint = await token.balanceOf(account);
        setTokenBalance(balance);
        const currentDelegatee: string = await token.delegates(account);
        setDelegatee(currentDelegatee);
      }

      const total: bigint = await registry.totalGrants();
      const loaded: Grant[] = [];
      for (let i = 0n; i < total; i++) {
        const g = await registry.getGrant(i);
        loaded.push({
          id: g.id, grantee: g.grantee, title: g.title, descriptionURI: g.descriptionURI,
          usdAmount: g.usdAmount, governorProposalId: g.governorProposalId, status: g.status,
          milestones: g.milestones,
        });
      }
      setGrants(loaded);

      const states: Record<string, string> = {};
      const pending: Record<string, bigint> = {};
      const votingOpens: Record<string, number> = {};
      const votingEnds: Record<string, number> = {};
      const executable: Record<string, number> = {};
      let currentBlock: number | null = null;
      const nowMs = Date.now();
      for (const g of loaded) {
        if (g.governorProposalId > 0n) {
          try {
            const s: bigint = await governor.state(g.governorProposalId);
            const stateName = PROPOSAL_STATES[Number(s)] ?? String(s);
            states[g.id.toString()] = stateName;

            // Governor.state() flips Pending→Active/Active→Succeeded only once currentBlock
            // *exceeds* the snapshot/deadline (strict >, not >=), so the transition happens
            // one block after the target — add 1 or the countdown hits zero a block early.
            if (stateName === 'Pending') {
              if (currentBlock === null) currentBlock = await provider.getBlockNumber();
              const snapshot: bigint = await governor.proposalSnapshot(g.governorProposalId);
              const blocksLeft = Number(snapshot) + 1 - currentBlock;
              votingOpens[g.id.toString()] = nowMs + Math.max(blocksLeft, 0) * SECONDS_PER_BLOCK * 1000;
            } else if (stateName === 'Active') {
              if (currentBlock === null) currentBlock = await provider.getBlockNumber();
              const deadline: bigint = await governor.proposalDeadline(g.governorProposalId);
              const blocksLeft = Number(deadline) + 1 - currentBlock;
              votingEnds[g.id.toString()] = nowMs + Math.max(blocksLeft, 0) * SECONDS_PER_BLOCK * 1000;
            } else if (stateName === 'Queued') {
              const eta: bigint = await governor.proposalEta(g.governorProposalId);
              executable[g.id.toString()] = Number(eta) * 1000;
            }
          } catch {
            states[g.id.toString()] = 'unknown';
          }
        }
        for (let i = 0; i < g.milestones.length; i++) {
          if (g.milestones[i].released) {
            pending[`${g.id}-${i}`] = await treasury.pendingWithdrawal(g.grantee, g.id, i);
          }
        }
      }
      setProposalStates(states);
      setPendingWithdrawals(pending);
      setVotingOpensAt(votingOpens);
      setVotingEndsAt(votingEnds);
      setExecutableAt(executable);
    } catch (e: any) {
      setError(describeError(e));
    }
  }, [readProvider, account]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // Defaults the delegate target to yourself (the common case) without
  // clobbering a value the user has already typed in.
  useEffect(() => {
    if (account && !delegateAddress) setDelegateAddress(account);
  }, [account, delegateAddress]);

  // The error banner lives at the very top of the page, but most actions
  // happen scrolled deep into a panel further down -- without this, a new
  // error can appear completely off-screen with no indication anything
  // went wrong.
  useEffect(() => {
    if (error) window.scrollTo({ top: 0, behavior: 'smooth' });
  }, [error]);

  const loadHistory = useCallback(async () => {
    const addr = showAllHistory ? null : (historyAddress || account);
    if (!showAllHistory && !addr) return setError('Connect a wallet or enter an address first.');
    setBusy('history');
    setError(null);
    try {
      const provider = readProvider();
      const token = new Contract(ADDRESSES.token, TokenAbi, provider);
      const earner = new Contract(ADDRESSES.earner, EarnerAbi, provider);
      const treasury = new Contract(ADDRESSES.treasury, TreasuryAbi, provider);
      const registry = new Contract(ADDRESSES.registry, RegistryAbi, provider);
      const latestBlock = await provider.getBlockNumber();

      const [earned, deposits, submitted, mints] = await Promise.all([
        queryFilterChunked(earner, earner.filters.TokensEarned(addr), DEPLOY_BLOCK, latestBlock),
        queryFilterChunked(treasury, treasury.filters.Deposited(addr), DEPLOY_BLOCK, latestBlock),
        queryFilterChunked(registry, registry.filters.GrantSubmitted(null, addr), DEPLOY_BLOCK, latestBlock),
        queryFilterChunked(token, token.filters.Transfer(null, addr), DEPLOY_BLOCK, latestBlock),
      ]);

      const entries: HistoryEntry[] = [];

      for (const ev of earned) {
        if (!('args' in ev)) continue;
        const [participant, action, amount] = ev.args as unknown as [string, bigint, bigint];
        entries.push({
          blockNumber: ev.blockNumber,
          txHash: ev.transactionHash,
          label: `Earned ${formatEther(amount)} GRANT`,
          detail: EARNER_ACTIONS[Number(action)] ?? `Action ${action}`,
          address: participant,
        });
      }
      for (const ev of deposits) {
        if (!('args' in ev)) continue;
        const [from, amount] = ev.args as unknown as [string, bigint];
        entries.push({
          blockNumber: ev.blockNumber,
          txHash: ev.transactionHash,
          label: `Deposited ${formatEther(amount)} ETH`,
          detail: 'Treasury funding',
          address: from,
        });
      }
      for (const ev of submitted) {
        if (!('args' in ev)) continue;
        const [grantId, grantee, usdAmount] = ev.args as unknown as [bigint, string, bigint];
        entries.push({
          blockNumber: ev.blockNumber,
          txHash: ev.transactionHash,
          label: `Submitted grant #${(grantId + 1n).toString()}`,
          detail: `Requested $${formatEther(usdAmount)}`,
          address: grantee,
        });
      }
      // Every GrantToken mint is already covered by an Earner "Earned" entry above
      // (Earner holds the sole MINTER_ROLE), so only show Transfer events the other
      // three queries missed — e.g. seeded balances from the admin "Seed voting power" flow.
      const covered = new Set(entries.map((e) => e.txHash));
      for (const ev of mints) {
        if (!('args' in ev) || covered.has(ev.transactionHash)) continue;
        const [, to, value] = ev.args as unknown as [string, string, bigint];
        entries.push({
          blockNumber: ev.blockNumber,
          txHash: ev.transactionHash,
          label: `Received ${formatEther(value)} GRANT`,
          detail: 'Mint',
          address: to,
        });
      }

      entries.sort((a, b) => b.blockNumber - a.blockNumber);
      setHistory(entries);
      setHistoryLoaded(true);
    } catch (e: any) {
      setError(describeError(e));
    } finally {
      setBusy(null);
    }
  }, [readProvider, historyAddress, account, showAllHistory]);

  const fundTreasury = useCallback(async () => {
    if (!signer) return setError('Connect a wallet first.');
    setBusy('fund');
    setError(null);
    try {
      const tx = await signer.sendTransaction({ to: ADDRESSES.treasury, value: parseEther(fundAmount || '0') });
      await tx.wait();
      setFundAmount('');
      await refresh();
    } catch (e: any) {
      setError(describeError(e));
    } finally {
      setBusy(null);
    }
  }, [signer, fundAmount, refresh]);

  // Bootstraps the very first voter. Deploy.s.sol mints no GRANT (Earner's
  // RECORDER_ROLE goes only to the Governor), so quorum starts at 0 and nobody
  // can vote until someone with Earner's DEFAULT_ADMIN_ROLE (the deployer) seeds
  // a voter directly — see DEMO.md "Seed voting power". Only works from the
  // deployer wallet; recipients must still self-delegate to activate the vote.
  // Deploy.s.sol grants Earner's RECORDER_ROLE only to the Governor, so seeding
  // requires the deployer (Earner's DEFAULT_ADMIN_ROLE holder) to self-grant it
  // once.
  const ensureRecorderRole = useCallback(async (earner: Contract, me: string) => {
    const recorderRole: string = await earner.RECORDER_ROLE();
    const alreadyRecorder: boolean = await earner.hasRole(recorderRole, me);
    if (!alreadyRecorder) {
      const grantTx = await sendWithGasBuffer(earner, 'grantRole', [recorderRole, me]);
      await grantTx.wait();
    }
  }, []);

  const seedGrantors = useCallback(async () => {
    if (!signer) return setError('Connect a wallet first.');
    const addresses = bulkSeedAddresses
      .split(/[\s,]+/)
      .map((a) => a.trim())
      .filter(Boolean);
    if (addresses.length === 0) return setError('Enter at least one address to seed.');
    const invalid = addresses.filter((a) => !isAddress(a));
    if (invalid.length > 0) return setError(`Invalid address(es): ${invalid.join(', ')}`);

    setBusy('seed');
    setError(null);
    setBulkSeedResult(null);
    try {
      const earner = new Contract(ADDRESSES.earner, EarnerAbi, signer);
      const me = await signer.getAddress();
      await ensureRecorderRole(earner, me);
      for (let i = 0; i < addresses.length; i++) {
        const proposalId = BigInt(Date.now()) + BigInt(i);
        const tx = await sendWithGasBuffer(earner, 'recordAction', [addresses[i], proposalId, 3]); // Action.Seeded
        await tx.wait();
      }
      setBulkSeedResult(`Seeded ${addresses.length} address(es) with 10 GRANT each.`);
      setBulkSeedAddresses('');
      await refresh();
    } catch (e: any) {
      setError(describeError(e));
    } finally {
      setBusy(null);
    }
  }, [signer, bulkSeedAddresses, refresh, ensureRecorderRole]);

  const delegateVotes = useCallback(async () => {
    if (!signer) return setError('Connect a wallet first.');
    if (tokenBalance === 0n) return setError('No GRANT balance to delegate yet.');
    if (!isAddress(delegateAddress)) return setError('Enter a valid address to delegate to.');
    setBusy('delegate');
    setError(null);
    try {
      const token = new Contract(ADDRESSES.token, TokenAbi, signer);
      const tx = await sendWithGasBuffer(token, 'delegate', [delegateAddress]);
      await tx.wait();
      await refresh();
    } catch (e: any) {
      setError(describeError(e));
    } finally {
      setBusy(null);
    }
  }, [signer, refresh, tokenBalance, delegateAddress]);

  const submitGrant = useCallback(async () => {
    if (!signer) return setError('Connect a wallet first.');
    setBusy('submit');
    setError(null);
    try {
      const registry = new Contract(ADDRESSES.registry, RegistryAbi, signer);
      const usdAmount = parseEther(form.usdAmount || '0');
      const basisPoints = milestoneForm.map((m) => Math.round(Number(m.percent) * 100));
      if (basisPoints.reduce((sum, bp) => sum + bp, 0) !== 10_000) {
        throw new Error('Milestone percentages must add up to 100%.');
      }
      const milestones = milestoneForm.map((m, i) => ({
        description: m.description || `Milestone ${i + 1}`,
        basisPoints: basisPoints[i],
        released: false,
      }));
      const tx = await sendWithGasBuffer(registry, 'submitGrant', [form.title, form.uri, usdAmount, milestones]);
      await tx.wait();
      setForm({ title: '', uri: '', usdAmount: '' });
      setMilestoneForm([{ description: '', percent: '100' }]);
      await refresh();
    } catch (e: any) {
      setError(describeError(e));
    } finally {
      setBusy(null);
    }
  }, [signer, form, milestoneForm, refresh]);

  const proposeRelease = useCallback(async (grantId: bigint, milestone: number) => {
    if (!signer) return setError('Connect a wallet first.');
    setBusy(`propose-${grantId}`);
    setError(null);
    try {
      const governor = new Contract(ADDRESSES.governor, GovernorAbi, signer);
      const tx = await sendWithGasBuffer(
        governor, 'proposeGrantRelease', [grantId, milestone, releaseDescription(grantId, milestone)],
      );
      await tx.wait();
      const updated = { ...proposedMilestones, [grantId.toString()]: milestone };
      setProposedMilestones(updated);
      saveProposedMilestones(updated);
      await refresh();
    } catch (e: any) {
      setError(describeError(e));
    } finally {
      setBusy(null);
    }
  }, [signer, refresh, proposedMilestones]);

  const castVote = useCallback(async (proposalId: bigint, support: 0 | 1 | 2) => {
    if (!signer) return setError('Connect a wallet first.');
    setBusy(`vote-${proposalId}`);
    setError(null);
    try {
      const governor = new Contract(ADDRESSES.governor, GovernorAbi, signer);
      const tx = await sendWithGasBuffer(governor, 'castVote', [proposalId, support]);
      await tx.wait();
      await refresh();
    } catch (e: any) {
      setError(describeError(e));
    } finally {
      setBusy(null);
    }
  }, [signer, refresh]);

  const queueRelease = useCallback(async (grant: Grant, milestone: number) => {
    if (!signer) return setError('Connect a wallet first.');
    setBusy(`queue-${grant.id}`);
    setError(null);
    try {
      const governor = new Contract(ADDRESSES.governor, GovernorAbi, signer);
      const { targets, values, calldatas, descriptionHash } = buildReleaseArgs(grant, milestone);
      const tx = await sendWithGasBuffer(governor, 'queue', [targets, values, calldatas, descriptionHash]);
      await tx.wait();
      await refresh();
    } catch (e: any) {
      setError(describeError(e));
    } finally {
      setBusy(null);
    }
  }, [signer, refresh]);

  const executeRelease = useCallback(async (grant: Grant, milestone: number) => {
    if (!signer) return setError('Connect a wallet first.');
    setBusy(`execute-${grant.id}`);
    setError(null);
    try {
      const governor = new Contract(ADDRESSES.governor, GovernorAbi, signer);
      const { targets, values, calldatas, descriptionHash } = buildReleaseArgs(grant, milestone);
      const tx = await sendWithGasBuffer(governor, 'execute', [targets, values, calldatas, descriptionHash]);
      await tx.wait();
      await refresh();
    } catch (e: any) {
      setError(describeError(e) + ' (timelock delay may not have elapsed yet)');
    } finally {
      setBusy(null);
    }
  }, [signer, refresh]);

  const withdrawGrant = useCallback(async (grant: Grant, milestone: number) => {
    if (!signer) return setError('Connect a wallet first.');
    setBusy(`withdraw-${grant.id}-${milestone}`);
    setError(null);
    try {
      const treasury = new Contract(ADDRESSES.treasury, TreasuryAbi, signer);
      const tx = await sendWithGasBuffer(treasury, 'withdraw', [grant.id, milestone]);
      await tx.wait();
      await refresh();
    } catch (e: any) {
      setError(describeError(e));
    } finally {
      setBusy(null);
    }
  }, [signer, refresh]);

  return (
    <div className="app">
      <header className="hero">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true">🌱</span>
          <div className="brand-text">
            <h1>GrantsDAO</h1>
            <p className="tagline">Community-funded grants, released milestone by milestone</p>
          </div>
        </div>
        {account ? (
          <span className="account"><AddressChip address={account} /></span>
        ) : (
          <button onClick={connect}>Connect Wallet</button>
        )}
      </header>

      {error && <div className="error">{error}</div>}

      <section className="stats">
        <div className="stat"><span>Treasury balance</span><strong>{treasuryBalance} ETH</strong></div>
        <div className="stat"><span>Your voting power</span><strong>{votingPower} GRANT</strong></div>
      </section>

      <section className="panel">
        <details>
          <summary><h2>How to earn GRANT</h2></summary>
          <ul className="reward-list">
            <li>
              <strong>Vote on a proposal</strong> — {rewardAmounts.Voted ?? '10'} GRANT, automatically,
              as long as your vote carries weight (delegate to self first).
            </li>
            <li>
              <strong>Propose a milestone release that executes</strong> — {rewardAmounts.ProposalSubmitted ?? '50'} GRANT,
              paid to whoever called propose once that proposal passes and executes — not at submission time.
            </li>
            <li>
              <strong>Have your milestone approved</strong> — {rewardAmounts.MilestoneApproved ?? '25'} GRANT,
              paid to the grantee once their milestone's release proposal executes, separate from whoever proposed it.
            </li>
            <li>
              <strong>Get seeded by the deployer</strong> — {rewardAmounts.Seeded ?? '10'} GRANT,
              an admin-only bootstrap so the very first vote has someone able to cast it.
            </li>
          </ul>
        </details>
      </section>

      <section className="panel">
        <h2>Delegate (activates GRANT)</h2>
        {account && (
          <p className="hint">
            Pending (undelegated): <strong>{formatEther(delegatee === ZeroAddress ? tokenBalance : 0n)} GRANT</strong>
            {delegatee !== ZeroAddress && (
              <> — currently delegated to <AddressChip address={delegatee} /></>
            )}
          </p>
        )}
        <div className="form-row">
          <input
            placeholder="Address to delegate to"
            value={delegateAddress}
            onChange={(e) => setDelegateAddress(e.target.value)}
          />
          <button
            disabled={busy === 'delegate' || !signer || tokenBalance === 0n}
            title={tokenBalance === 0n ? 'No GRANT balance to delegate yet' : undefined}
            onClick={delegateVotes}
          >
            {busy === 'delegate' ? 'Delegating…' : 'Delegate'}
          </button>
        </div>
      </section>

      {account && DEPLOYER_ADDRESS && account.toLowerCase() === DEPLOYER_ADDRESS && (
        <section className="panel">
          <h2>Seed voting power (deployer only)</h2>
          <textarea
            className="bulk-seed-textarea"
            placeholder="0xAddress1&#10;0xAddress2&#10;0xAddress3"
            rows={3}
            value={bulkSeedAddresses}
            onChange={(e) => setBulkSeedAddresses(e.target.value)}
          />
          <div className="form-row">
            <button disabled={busy === 'seed'} onClick={seedGrantors}>
              {busy === 'seed' ? 'Seeding…' : 'Grant 10 GRANT each'}
            </button>
            {bulkSeedResult && <span className="hint">{bulkSeedResult}</span>}
          </div>
        </section>
      )}

      <section className="panel">
        <h2>Fund treasury</h2>
        <div className="form-row">
          <input placeholder="ETH amount" type="number" step="0.001" value={fundAmount}
            onChange={(e) => setFundAmount(e.target.value)} />
          <button disabled={busy === 'fund'} onClick={fundTreasury}>
            {busy === 'fund' ? 'Sending…' : 'Send ETH'}
          </button>
        </div>
      </section>

      <section className="panel">
        <h2>Submit a grant</h2>
        <div className="form-row">
          <input placeholder="Title" value={form.title}
            onChange={(e) => setForm({ ...form, title: e.target.value })} />
          <input placeholder="Description URI (ipfs://…)" value={form.uri}
            onChange={(e) => setForm({ ...form, uri: e.target.value })} />
          <span className="usd-input">
            <span className="usd-prefix">$</span>
            <input placeholder="USD amount" type="number" value={form.usdAmount}
              onChange={(e) => setForm({ ...form, usdAmount: e.target.value })} />
          </span>
        </div>

        <div className="milestones-form">
          {milestoneForm.map((m, i) => (
            <div className="form-row" key={i}>
              <input placeholder={`Milestone ${i + 1} description`} value={m.description}
                onChange={(e) => updateMilestone(i, 'description', e.target.value)} />
              <span className="usd-input">
                <input placeholder="%" type="number" value={m.percent}
                  onChange={(e) => updateMilestone(i, 'percent', e.target.value)} />
                <span className="usd-prefix">%</span>
              </span>
              {milestoneForm.length > 1 && (
                <button type="button" onClick={() => removeMilestone(i)}>Remove</button>
              )}
            </div>
          ))}
          <div className="form-row">
            <button type="button" onClick={addMilestone}>+ Add milestone</button>
            <span className={milestoneTotal === 100 ? 'hint' : 'error-inline'}>
              Total: {milestoneTotal}% {milestoneTotal !== 100 && '(must equal 100%)'}
            </span>
          </div>
        </div>

        <div className="form-row">
          <button disabled={busy === 'submit' || milestoneTotal !== 100} onClick={submitGrant}>
            {busy === 'submit' ? 'Submitting…' : 'Submit'}
          </button>
        </div>
      </section>

      <section className="panel">
        <h2>Grants</h2>
        <button onClick={refresh}>Refresh</button>
        <div className="grants">
          {grants.length === 0 && <p className="hint">No grants submitted yet.</p>}
          {grants.map((g) => {
            const proposalState = proposalStates[g.id.toString()];
            const next = nextMilestoneIndex(g);
            // The active proposal targets whichever milestone we remember proposing;
            // fall back to `next` for a fresh grant with no proposal yet.
            const activeMilestone = proposedMilestones[g.id.toString()] ?? next;
            const proposalTargetsCurrent = g.governorProposalId > 0n
              && activeMilestone !== null
              && activeMilestone === next;

            return (
              <div className="grant-card" key={g.id.toString()}>
                <h3>#{(g.id + 1n).toString()} — {g.title}</h3>
                <p>{g.descriptionURI}</p>
                <p>Requested: ${formatEther(g.usdAmount)} · Grantee: <AddressChip address={g.grantee} /></p>
                <ul>
                  {g.milestones.map((m, i) => {
                    const pending = pendingWithdrawals[`${g.id}-${i}`] ?? 0n;
                    const isGrantee = account?.toLowerCase() === g.grantee.toLowerCase();
                    return (
                      <li key={i} className={m.released ? 'milestone-done' : undefined}>
                        {m.description} — {Number(m.basisPoints) / 100}% {m.released ? '(released)' : ''}
                        {m.released && pending > 0n && (
                          <span className="withdraw">
                            <span>Pending: {formatEther(pending)} ETH</span>
                            <button
                              disabled={busy === `withdraw-${g.id}-${i}` || !isGrantee}
                              title={isGrantee ? undefined : 'Only the grantee can withdraw'}
                              onClick={() => withdrawGrant(g, i)}
                            >
                              {busy === `withdraw-${g.id}-${i}` ? 'Withdrawing…' : 'Withdraw'}
                            </button>
                          </span>
                        )}
                      </li>
                    );
                  })}
                </ul>
                {next === null ? (
                  <span className="hint">All milestones released.</span>
                ) : !proposalTargetsCurrent ? (
                  <button disabled={busy === `propose-${g.id}`} onClick={() => proposeRelease(g.id, next)}>
                    {busy === `propose-${g.id}` ? 'Proposing…' : `Propose milestone ${next + 1} release`}
                  </button>
                ) : (
                  <div className="proposal">
                    <span>
                      Proposal #<CopyChip value={g.governorProposalId.toString()} display={truncateId(g.governorProposalId)} />{' '}
                      (milestone {next + 1}){' '}
                      <span className={badgeClass(proposalState)}>{proposalState ?? 'loading…'}</span>
                    </span>
                    {proposalState === 'Pending' && votingOpensAt[g.id.toString()] !== undefined && (
                      <span className="hint">
                        {votingOpensAt[g.id.toString()] <= now
                          ? 'Voting should be opening any block now — click Refresh to check.'
                          : `Voting opens in ${formatCountdown(votingOpensAt[g.id.toString()], now)} (estimated)`}
                      </span>
                    )}
                    {proposalState === 'Active' && (
                      <>
                        {votingEndsAt[g.id.toString()] !== undefined && (
                          <span className="hint">
                            {votingEndsAt[g.id.toString()] <= now
                              ? 'Voting should be closing any block now — click Refresh to check.'
                              : `Voting ends in ${formatCountdown(votingEndsAt[g.id.toString()], now)} (estimated)`}
                          </span>
                        )}
                        <div className="vote-buttons">
                          <button disabled={!!busy} onClick={() => castVote(g.governorProposalId, 1)}>Vote For</button>
                          <button disabled={!!busy} onClick={() => castVote(g.governorProposalId, 0)}>Vote Against</button>
                          <button disabled={!!busy} onClick={() => castVote(g.governorProposalId, 2)}>Abstain</button>
                        </div>
                      </>
                    )}
                    {proposalState === 'Succeeded' && (
                      <button disabled={busy === `queue-${g.id}`} onClick={() => queueRelease(g, next)}>
                        {busy === `queue-${g.id}` ? 'Queuing…' : 'Queue'}
                      </button>
                    )}
                    {proposalState === 'Queued' && (
                      <>
                        {executableAt[g.id.toString()] !== undefined && (
                          <span className="hint">
                            {executableAt[g.id.toString()] <= now
                              ? 'Timelock delay elapsed — ready to execute.'
                              : `Executable in ${formatCountdown(executableAt[g.id.toString()], now)}`}
                          </span>
                        )}
                        <button
                          disabled={busy === `execute-${g.id}` || (executableAt[g.id.toString()] ?? 0) > now}
                          onClick={() => executeRelease(g, next)}
                        >
                          {busy === `execute-${g.id}` ? 'Executing…' : 'Execute'}
                        </button>
                      </>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </section>

      <section className="panel">
        <h2>Transaction history</h2>
        <div className="form-row">
          <input placeholder="Address" value={historyAddress} disabled={showAllHistory}
            onChange={(e) => setHistoryAddress(e.target.value)} />
          <button disabled={busy === 'history'} onClick={loadHistory}>
            {busy === 'history' ? 'Loading…' : 'Load history'}
          </button>
        </div>
        <label className="checkbox-row">
          <input
            type="checkbox"
            checked={showAllHistory}
            onChange={(e) => setShowAllHistory(e.target.checked)}
          />
          View entire GrantsDAO history (all addresses)
        </label>
        <div className="history">
          {historyLoaded && history.length === 0 && (
            <p className="hint">No activity found.</p>
          )}
          {history.map((h) => (
            <div className="history-row" key={`${h.txHash}-${h.label}`}>
              <div>
                <strong>{h.label}</strong>
                <span className="hint"> — {h.detail}</span>
                {showAllHistory && (
                  <span className="hint"> · <AddressChip address={h.address} /></span>
                )}
              </div>
              <a
                className="hint"
                href={`${SEPOLIA_TX_URL}${h.txHash}`}
                target="_blank"
                rel="noreferrer"
              >
                block {h.blockNumber} · {h.txHash.slice(0, 8)}…
              </a>
            </div>
          ))}
        </div>
      </section>

    </div>
  );
}

export default App;
