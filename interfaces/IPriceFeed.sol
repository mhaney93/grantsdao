// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceFeed
/// @notice Thin wrapper around the Chainlink ETH/USD AggregatorV3 feed.
///         Converts a USD-denominated grant amount to wei at execution time.
interface IPriceFeed {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when the Chainlink answer is stale (updatedAt too old).
    error StalePriceFeed(uint256 updatedAt, uint256 maxAge);

    /// @notice Thrown when the Chainlink answer is <= 0.
    error InvalidPrice(int256 price);

    /// @notice Thrown when the round is incomplete (`answeredInRound < roundId`).
    error IncompleteRound(uint80 roundId, uint80 answeredInRound);

    /// @notice Thrown when the feed address supplied at construction is the zero address.
    error ZeroFeedAddress();

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the latest ETH price in USD (8 decimals, same as Chainlink).
    function latestPrice() external view returns (uint256 priceUsd8);

    /// @notice Converts a USD amount (18 decimals) to ETH (wei).
    /// @param usdAmount Amount in USD with 18 decimal places.
    /// @return ethAmount Equivalent amount in wei.
    function usdToEth(uint256 usdAmount) external view returns (uint256 ethAmount);

    /// @notice Address of the underlying Chainlink AggregatorV3 feed.
    function feed() external view returns (address);
}
