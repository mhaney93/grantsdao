// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/PriceFeed.sol";
import "../interfaces/IPriceFeed.sol";
import "./mocks/MockAggregatorV3.sol";

contract PriceFeedTest is Test {
    PriceFeed priceFeed;
    MockAggregatorV3 mockFeed;

    uint256 constant MAX_AGE = 1 hours;
    int256 constant ETH_USD_PRICE = 3000e8; // $3000, 8 decimals

    function setUp() public {
        mockFeed = new MockAggregatorV3(ETH_USD_PRICE);
        priceFeed = new PriceFeed(address(mockFeed), MAX_AGE);
    }

    function test_latestPrice_returnsFeedAnswer() public view {
        assertEq(priceFeed.latestPrice(), uint256(ETH_USD_PRICE));
    }

    function test_usdToEth_convertsCorrectly() public view {
        // $3000 usd at $3000/ETH == 1 ETH
        uint256 ethAmount = priceFeed.usdToEth(3000e18);
        assertEq(ethAmount, 1e18);
    }

    function test_usdToEth_partialAmount() public view {
        // $1500 usd at $3000/ETH == 0.5 ETH
        uint256 ethAmount = priceFeed.usdToEth(1500e18);
        assertEq(ethAmount, 0.5e18);
    }

    function test_revertsWhenStale() public {
        mockFeed.setUpdatedAt(block.timestamp);
        vm.warp(block.timestamp + MAX_AGE + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IPriceFeed.StalePriceFeed.selector, block.timestamp - MAX_AGE - 1, MAX_AGE)
        );
        priceFeed.latestPrice();
    }

    function test_doesNotRevertAtExactMaxAge() public {
        mockFeed.setUpdatedAt(block.timestamp);
        vm.warp(block.timestamp + MAX_AGE);
        // exactly at boundary should not revert (uses strict >)
        priceFeed.latestPrice();
    }

    function test_revertsOnZeroPrice() public {
        mockFeed.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(IPriceFeed.InvalidPrice.selector, int256(0)));
        priceFeed.latestPrice();
    }

    function test_revertsOnNegativePrice() public {
        mockFeed.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(IPriceFeed.InvalidPrice.selector, int256(-1)));
        priceFeed.latestPrice();
    }

    function test_feed_returnsUnderlyingAddress() public view {
        assertEq(priceFeed.feed(), address(mockFeed));
    }

    function test_revertsOnIncompleteRound() public {
        mockFeed.setRoundData(5, 4);
        vm.expectRevert(abi.encodeWithSelector(IPriceFeed.IncompleteRound.selector, uint80(5), uint80(4)));
        priceFeed.latestPrice();
    }

    function test_constructor_revertsOnZeroFeedAddress() public {
        vm.expectRevert(IPriceFeed.ZeroFeedAddress.selector);
        new PriceFeed(address(0), MAX_AGE);
    }
}
