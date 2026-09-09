// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {
    RouteUsdStreamsFeed as Feed,
    IUsdStreamsVerifier
} from "../experimental/RouteUsdStreamsFeed.sol";
import {Token, Vm} from "./Route.t.sol";

contract UsdVerifierFixture is IUsdStreamsVerifier {
    bytes private report;
    bool private fails;

    function set(bytes memory body, bool fail) external {
        report = body;
        fails = fail;
    }

    function verify(bytes calldata, bytes calldata parameters)
        external
        payable
        returns (bytes memory)
    {
        require(!fails && parameters.length == 0 && msg.value == 0);
        return report;
    }
}

contract RouteUsdStreamsFeedTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Feed feed;
    UsdVerifierFixture verifier;
    Token token;
    bytes32 constant id = bytes32(uint256(3) << 240 | 1);

    function setUp() public {
        vm.warp(1000);
        token = new Token("WETH");
        verifier = new UsdVerifierFixture();
        Feed.Config[] memory configs = new Feed.Config[](1);
        configs[0] = Feed.Config(address(token), id, 8);
        feed = new Feed(address(verifier), configs, 30);
    }

    function report() internal pure returns (Feed.Report memory) {
        return Feed.Report(id, 999, 1000, 0, 0, 1030, 2000e8, 1999e8, 2001e8);
    }

    function publish(Feed.Report memory r) internal {
        verifier.set(abi.encode(r), false);
        feed.update(address(token), hex"01");
    }

    function testVerifiedReportNormalizedAndReplayRejected() public {
        publish(report());
        (uint256 usd, uint256 at) = feed.price(address(token));
        require(usd == 2000 ether && at == 1000);
        vm.expectRevert(Feed.InvalidReport.selector);
        feed.update(address(token), hex"01");
    }

    function testBadSignatureCannotUpdate() public {
        verifier.set(abi.encode(report()), true);
        vm.expectRevert();
        feed.update(address(token), hex"01");
        vm.expectRevert(Feed.Unavailable.selector);
        feed.price(address(token));
    }

    function testWrongFeedFutureExpiredZeroAndMalformedRejected() public {
        Feed.Report memory r = report();
        r.feedId = bytes32(uint256(3) << 240 | 2);
        verifier.set(abi.encode(r), false);
        vm.expectRevert(Feed.InvalidReport.selector);
        feed.update(address(token), hex"01");
        r = report();
        r.observationsTimestamp = 1001;
        verifier.set(abi.encode(r), false);
        vm.expectRevert(Feed.InvalidReport.selector);
        feed.update(address(token), hex"01");
        r = report();
        r.expiresAt = 1000;
        verifier.set(abi.encode(r), false);
        vm.expectRevert(Feed.InvalidReport.selector);
        feed.update(address(token), hex"01");
        r = report();
        r.price = 0;
        verifier.set(abi.encode(r), false);
        vm.expectRevert(Feed.InvalidReport.selector);
        feed.update(address(token), hex"01");
        verifier.set(hex"01", false);
        vm.expectRevert(Feed.InvalidReport.selector);
        feed.update(address(token), hex"01");
    }

    function testStaleCacheUnavailableAndOlderReportsCannotReplaceIt() public {
        publish(report());
        vm.warp(1020);
        Feed.Report memory r = report();
        r.observationsTimestamp = 999;
        verifier.set(abi.encode(r), false);
        vm.expectRevert(Feed.InvalidReport.selector);
        feed.update(address(token), hex"01");
        vm.warp(1030);
        vm.expectRevert(Feed.Unavailable.selector);
        feed.price(address(token));
    }

    function testUnsupportedTokenFailsClosed() public {
        vm.expectRevert(Feed.Unavailable.selector);
        feed.price(address(123));
        vm.expectRevert(Feed.InvalidReport.selector);
        feed.update(address(123), hex"01");
    }
}
