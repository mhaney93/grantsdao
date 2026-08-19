// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/PriceFeed.sol";

/// @notice Fork test against the live Chainlink ETH/USD feed on Sepolia, per the
///         capstone testing plan (planning.md "Fork tests"). Skips gracefully if
///         no SEPOLIA_RPC_URL is configured, so `forge test` stays runnable offline.
///
/// @dev Run explicitly with: forge test --match-contract PriceFeedForkTest --fork-url $SEPOLIA_RPC_URL
contract PriceFeedForkTest is Test {
    // Chainlink ETH/USD AggregatorV3 proxy on Sepolia.
    address constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    PriceFeed priceFeed;

    function setUp() public {
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);
        priceFeed = new PriceFeed(SEPOLIA_ETH_USD_FEED, 1 days);
    }

    function test_latestPrice_returnsPlausibleLiveEthUsdPrice() public view {
        if (address(priceFeed) == address(0)) return; // skipped: no RPC configured

        uint256 price = priceFeed.latestPrice();
        // Sanity band: ETH has not traded below $100 or above $100,000 historically.
        assertGt(price, 100e8);
        assertLt(price, 100_000e8);
    }

    function test_usdToEth_convertsUsingLiveFeed() public view {
        if (address(priceFeed) == address(0)) return; // skipped: no RPC configured

        uint256 ethAmount = priceFeed.usdToEth(1000e18); // $1000
        assertGt(ethAmount, 0);
    }

    function test_feed_pointsAtSepoliaAggregator() public view {
        if (address(priceFeed) == address(0)) return; // skipped: no RPC configured

        assertEq(priceFeed.feed(), SEPOLIA_ETH_USD_FEED);
    }
}
