// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IOrderPriceFeed} from "./RouteOrderVault.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IUsdStreamsVerifier {
    function verify(bytes calldata payload, bytes calldata parameters)
        external
        payable
        returns (bytes memory);
}

/// @notice Experimental cache of authenticated v3 crypto/USD reports.
/// @dev Feed IDs, units and provenance must be reviewed before deployment. No
/// caller-provided prices, admin writes, $1 stablecoin assumptions or fallback.
contract RouteUsdStreamsFeed is IOrderPriceFeed, ReentrancyGuard {
    struct Config {
        address token;
        bytes32 feedId;
        uint8 decimals;
    }

    struct Source {
        bytes32 feedId;
        uint8 decimals;
    }

    struct Report {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 price;
        int192 bid;
        int192 ask;
    }

    struct Value {
        uint256 usd;
        uint32 at;
        uint32 expiresAt;
    }
    IUsdStreamsVerifier public immutable verifier;
    uint256 public immutable maxAge;
    mapping(address => Source) public sources;
    mapping(address => Value) private values;
    error InvalidConfig();
    error InvalidReport();
    error Unavailable();
    event Updated(address indexed token, bytes32 indexed feedId, uint256 usd, uint32 at);

    constructor(address proxy, Config[] memory configs, uint256 age) {
        if (
            proxy.code.length == 0 || configs.length == 0 || configs.length > 32 || age == 0
                || age > 60
        ) {
            revert InvalidConfig();
        }
        verifier = IUsdStreamsVerifier(proxy);
        maxAge = age;
        for (uint256 i; i < configs.length; i++) {
            Config memory c = configs[i];
            if (
                c.token.code.length == 0 || uint16(bytes2(c.feedId)) != 3 || c.decimals > 18
                    || sources[c.token].feedId != bytes32(0)
            ) {
                revert InvalidConfig();
            }
            sources[c.token] = Source(c.feedId, c.decimals);
        }
    }

    function update(address token, bytes calldata signedReport) external nonReentrant {
        Source memory s = sources[token];
        if (s.feedId == bytes32(0) || signedReport.length == 0 || signedReport.length > 65536) {
            revert InvalidReport();
        }
        bytes memory verified = verifier.verify(signedReport, bytes(""));
        if (verified.length != 288) {
            revert InvalidReport();
        }
        Report memory r = abi.decode(verified, (Report));
        if (
            r.feedId != s.feedId || r.price <= 0 || r.bid <= 0 || r.ask < r.bid || r.price < r.bid
                || r.price > r.ask || r.validFromTimestamp == 0
                || r.validFromTimestamp > r.observationsTimestamp
                || r.observationsTimestamp > block.timestamp
                || block.timestamp - r.observationsTimestamp > maxAge
                || r.expiresAt <= block.timestamp || r.expiresAt < r.observationsTimestamp
                || r.observationsTimestamp <= values[token].at
        ) {
            revert InvalidReport();
        }
        uint256 usd = uint256(uint192(r.price)) * 10 ** (18 - s.decimals);
        values[token] = Value(usd, r.observationsTimestamp, r.expiresAt);
        emit Updated(token, r.feedId, usd, r.observationsTimestamp);
    }

    function price(address token) external view returns (uint256 value, uint256 updatedAt) {
        Value memory v = values[token];
        if (
            v.at == 0 || v.at > block.timestamp || block.timestamp - v.at > maxAge
                || v.expiresAt <= block.timestamp
        ) {
            revert Unavailable();
        }
        return (v.usd, v.at);
    }
}
