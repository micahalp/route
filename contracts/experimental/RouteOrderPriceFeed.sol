// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IOrderPriceFeed} from "./RouteOrderVault.sol";

interface IOrderAggregator {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Experimental reader for reviewed crypto/USD feeds. No deployments configured.
/// @dev No admin or mutable feed selection. Not for equity/corporate-action feeds.
/// Feed provenance, token identity, heartbeat and sequencer coverage require external review.
contract RouteOrderPriceFeed is IOrderPriceFeed {
    struct Config { address token; address feed; uint32 maxAge; }
    struct Source { IOrderAggregator feed; uint32 maxAge; uint8 decimals; }
    mapping(address => Source) private sources;
    IOrderAggregator public immutable sequencer;
    uint256 public immutable gracePeriod;
    error InvalidConfig();
    error UnsupportedToken();
    error InvalidPrice();
    error SequencerUnavailable();

    constructor(Config[] memory configs, address uptimeFeed, uint256 grace) {
        if (configs.length == 0 || configs.length > 32 || uptimeFeed.code.length == 0 ||
            grace == 0 || grace > 1 days) revert InvalidConfig();
        sequencer = IOrderAggregator(uptimeFeed);
        gracePeriod = grace;
        for (uint256 i; i < configs.length; ++i) {
            Config memory c = configs[i];
            if (c.token.code.length == 0 || c.feed.code.length == 0 || c.maxAge == 0 ||
                c.maxAge > 1 hours || address(sources[c.token].feed) != address(0)) revert InvalidConfig();
            uint8 d = IOrderAggregator(c.feed).decimals();
            if (d > 18) revert InvalidConfig();
            sources[c.token] = Source(IOrderAggregator(c.feed), c.maxAge, d);
        }
    }

    function price(address token) external view returns (uint256 value, uint256 updatedAt) {
        Source memory s = sources[token];
        if (address(s.feed) == address(0)) revert UnsupportedToken();
        // Uptime feeds describe the last status change, not a price heartbeat.
        (, int256 status, uint256 since, uint256 reportedAt,) = sequencer.latestRoundData();
        if (status != 0 || since == 0 || since > block.timestamp || reportedAt < since ||
            reportedAt > block.timestamp || block.timestamp - since <= gracePeriod)
            revert SequencerUnavailable();
        (, int256 answer,, uint256 at,) = s.feed.latestRoundData();
        if (answer <= 0 || at == 0 || at > block.timestamp || block.timestamp - at > s.maxAge ||
            s.feed.decimals() != s.decimals) revert InvalidPrice();
        uint256 scale = 10 ** (18 - s.decimals);
        if (uint256(answer) > type(uint256).max / scale) revert InvalidPrice();
        return (uint256(answer) * scale, at);
    }
}
