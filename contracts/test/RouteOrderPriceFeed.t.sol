// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteOrderPriceFeed, IOrderAggregator} from "../experimental/RouteOrderPriceFeed.sol";
import {Token, Vm} from "./Route.t.sol";

contract PriceAggregatorFixture is IOrderAggregator {
    uint8 public decimals = 8;
    int256 public answer = 2000e8;
    uint256 public since = 100;
    uint256 public updated = 10000;

    function set(int256 a, uint256 s, uint256 u) external {
        answer = a;
        since = s;
        updated = u;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, since, updated, 1);
    }
}

contract RouteOrderPriceFeedTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    PriceAggregatorFixture source;
    PriceAggregatorFixture uptime;
    Token token;
    RouteOrderPriceFeed reader;

    function configs() internal view returns (RouteOrderPriceFeed.Config[] memory c) {
        c = new RouteOrderPriceFeed.Config[](1);
        c[0] = RouteOrderPriceFeed.Config(address(token), address(source), 60);
    }

    function setUp() public {
        vm.warp(10000);
        token = new Token("M");
        source = new PriceAggregatorFixture();
        uptime = new PriceAggregatorFixture();
        uptime.set(0, 100, 100);
        reader = new RouteOrderPriceFeed(configs(), address(uptime), 3600);
    }

    function testNormalizedPriceAndOriginalTimestamp() public view {
        (uint256 p, uint256 at) = reader.price(address(token));
        require(p == 2000 ether && at == 10000);
    }

    function testUnknownTokenRejected() public {
        vm.expectRevert(RouteOrderPriceFeed.UnsupportedToken.selector);
        reader.price(address(123));
    }

    function testStaleZeroFutureNegativeRejected() public {
        int256[5] memory answers = [int256(1), int256(1), int256(1), int256(0), int256(-1)];
        uint256[5] memory times =
            [uint256(9939), uint256(0), uint256(10001), uint256(10000), uint256(10000)];
        for (uint256 i; i < 5; ++i) {
            source.set(answers[i], 100, times[i]);
            vm.expectRevert(RouteOrderPriceFeed.InvalidPrice.selector);
            reader.price(address(token));
        }
        source.set(1, 100, 9940);
        reader.price(address(token));
    }

    function testSequencerDownUnknownUninitializedAndFutureRejected() public {
        int256[5] memory statuses = [int256(1), int256(2), int256(0), int256(0), int256(0)];
        uint256[5] memory starts =
            [uint256(100), uint256(100), uint256(0), uint256(10001), uint256(100)];
        uint256[5] memory reports =
            [uint256(100), uint256(100), uint256(0), uint256(10001), uint256(10001)];
        for (uint256 i; i < 5; ++i) {
            uptime.set(statuses[i], starts[i], reports[i]);
            vm.expectRevert(RouteOrderPriceFeed.SequencerUnavailable.selector);
            reader.price(address(token));
        }
    }

    function testRecoveryGraceBoundary() public {
        uptime.set(0, 6400, 6400);
        vm.expectRevert(RouteOrderPriceFeed.SequencerUnavailable.selector);
        reader.price(address(token));
        uptime.set(0, 6399, 6399);
        reader.price(address(token));
    }

    function testDecimalsChangeAndOverflowRejected() public {
        source.setDecimals(9);
        vm.expectRevert(RouteOrderPriceFeed.InvalidPrice.selector);
        reader.price(address(token));
        source.setDecimals(8);
        source.set(type(int256).max, 100, 10000);
        vm.expectRevert(RouteOrderPriceFeed.InvalidPrice.selector);
        reader.price(address(token));
    }

    function testInvalidConfigAndDuplicateRejected() public {
        vm.expectRevert(RouteOrderPriceFeed.InvalidConfig.selector);
        new RouteOrderPriceFeed(configs(), address(0), 3600);
        source.setDecimals(19);
        vm.expectRevert(RouteOrderPriceFeed.InvalidConfig.selector);
        new RouteOrderPriceFeed(configs(), address(uptime), 3600);
        source.setDecimals(8);
        RouteOrderPriceFeed.Config[] memory c = new RouteOrderPriceFeed.Config[](2);
        c[0] = configs()[0];
        c[1] = c[0];
        vm.expectRevert(RouteOrderPriceFeed.InvalidConfig.selector);
        new RouteOrderPriceFeed(c, address(uptime), 3600);
    }

    function testFuzzNormalization(uint64 answer) public {
        if (answer == 0) {
            return;
        }
        source.set(int256(uint256(answer)), 100, 10000);
        (uint256 p,) = reader.price(address(token));
        require(p == uint256(answer) * 1e10);
    }
}
