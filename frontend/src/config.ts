export const CHAIN_ID = 11155111n; // Sepolia

// Block the contracts were deployed at (see broadcast/Deploy.s.sol/11155111/run-latest.json).
// Used as the lower bound for event log queries so they don't scan from genesis and hit
// RPC provider eth_getLogs range limits.
export const DEPLOY_BLOCK = 11_517_697;

// Deployer address (Deploy.s.sol `from`). The "Seed voting power" admin panel
// is only shown when the connected wallet matches this address.
export const DEPLOYER_ADDRESS = (import.meta.env.VITE_DEPLOYER_ADDRESS as string || '').toLowerCase();

export const ADDRESSES = {
  token: import.meta.env.VITE_GRANT_TOKEN_ADDRESS as string,
  earner: import.meta.env.VITE_EARNER_ADDRESS as string,
  priceFeed: import.meta.env.VITE_PRICE_FEED_ADDRESS as string,
  registry: import.meta.env.VITE_GRANT_REGISTRY_ADDRESS as string,
  treasury: import.meta.env.VITE_GRANTS_TREASURY_ADDRESS as string,
  governor: import.meta.env.VITE_GRANTS_GOVERNOR_ADDRESS as string,
};
