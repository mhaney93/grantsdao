// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IPriceFeed.sol";

/// @dev Minimal Chainlink AggregatorV3 interface.
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

/// @title PriceFeed
/// @notice Thin wrapper around the Chainlink ETH/USD AggregatorV3 feed.
///         Converts USD grant amounts (18 decimals) to wei at query time.
///
/// @dev GD-6: Staleness check enforced via maxAge; reverts StalePriceFeed if exceeded.
/// @dev GD-6: Reverts InvalidPrice if the Chainlink answer is <= 0.
contract PriceFeed is IPriceFeed {
    AggregatorV3Interface private immutable _feed;

    /// @notice Maximum acceptable age (in seconds) of the Chainlink answer.
    uint256 public immutable maxAge;

    /// @dev 10 ** feed.decimals(), read once at construction and reused for conversion.
    uint256 private immutable _scale;

    /// @param feed_   Address of the Chainlink ETH/USD AggregatorV3 feed.
    /// @param maxAge_ Maximum seconds since updatedAt before the price is considered stale.
    constructor(address feed_, uint256 maxAge_) {
        if (feed_ == address(0)) revert ZeroFeedAddress();
        _feed = AggregatorV3Interface(feed_);
        maxAge = maxAge_;
        _scale = 10 ** _feed.decimals();
    }

    // ── IPriceFeed ────────────────────────────────────────────────────────────

    /// @inheritdoc IPriceFeed
    function latestPrice() public view returns (uint256 priceUsd8) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = _feed.latestRoundData();

        if (answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound);
        if (block.timestamp - updatedAt > maxAge) revert StalePriceFeed(updatedAt, maxAge);
        if (answer <= 0) revert InvalidPrice(answer);

        return uint256(answer);
    }

    /// @inheritdoc IPriceFeed
    /// @dev usdAmount has 18 decimals. Chainlink answer has `_scale` (10 ** feed.decimals()).
    ///      ethAmount = usdAmount * _scale / (priceUsd8 * 1e18) * 1e18
    ///                = usdAmount * _scale / priceUsd8
    function usdToEth(uint256 usdAmount) external view returns (uint256 ethAmount) {
        uint256 priceUsd8 = latestPrice();
        return (usdAmount * _scale) / priceUsd8;
    }

    /// @inheritdoc IPriceFeed
    function feed() external view returns (address) {
        return address(_feed);
    }
}
