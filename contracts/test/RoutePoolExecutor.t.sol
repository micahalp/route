// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RoutePoolExecutor} from "../RoutePoolExecutor.sol";
import {RouteExecutor} from "../RouteExecutor.sol";
import {RouteRamsesExecutorTest} from "./RouteRamsesExecutor.t.sol";
import {V3CallbackFactoryFixture, V3CallbackPoolFixture, CallbackReentryToken} from "./RouteV3CallbackProbe.t.sol";
import {TaxToken} from "./Route.t.sol";
import {FastMockV3} from "./RouteFastExecutor.t.sol";
import {V3Adapter} from "../adapters/V3Adapter.sol";
import {V4Adapter} from "../adapters/V4Adapter.sol";
import {MockManager} from "./V4Execution.t.sol";
import {JitFactoryFixture} from "./RouteJitV2Executor.t.sol";

// Only test harnesses can inject factories; the actual constructor uses pins.
contract RoutePoolHarness is RoutePoolExecutor {
    address private immutable testV3Factory; address private immutable testV2Factory;
    constructor(address wrapped, address[] memory adapters, address v4, address v3, address v2, address ram, address ramFactory, address pools3, address pools2)
        RoutePoolExecutor(wrapped, adapters, v4, v3, v2, ram, ramFactory) { testV3Factory = pools3; testV2Factory = pools2; }
    function _v3PoolFactory() internal view override returns (address) { return testV3Factory; }
    function _v2PairFactory() internal view override returns (address) { return testV2Factory == address(0) ? super._v2PairFactory() : testV2Factory; }
}

// Re-run the original general and Ramses tests against the new full executor.
contract RoutePoolFallbackTest is RouteRamsesExecutorTest {
    function _makeExecutor(address wrapped, address[] memory adapters, address v4, address v3, address v2, address ram, address ramFactory) internal override returns (address) {
        return address(new RoutePoolExecutor(wrapped, adapters, v4, v3, v2, ram, ramFactory));
    }
}

contract RoutePoolCallbackTest is RoutePoolFallbackTest {
    V3CallbackFactoryFixture pools; V3CallbackPoolFixture poolAB;
    V3Adapter v3; FastMockV3 unused; MockManager manager; V4Adapter v4;
    function adapters() private view returns (address[] memory all) {
        all = new address[](5); all[0] = address(v1); all[1] = address(v2); all[2] = address(v3); all[3] = address(v4); all[4] = address(ramses);
    }
    function setUp() public override {
        super.setUp(); pools = new V3CallbackFactoryFixture(); unused = new FastMockV3();
        uint24[] memory fees = new uint24[](1); fees[0] = 500; v3 = new V3Adapter("canonical fixture", address(unused), address(unused), fees);
        poolAB = pools.add(address(a), address(b)); pools.add(address(a), address(c)); pools.add(address(c), address(b));
        pools.add(address(weth), address(b)); pools.add(address(a), address(weth));
        manager = new MockManager(); v4 = new V4Adapter(address(manager), address(weth));
        b.mint(address(manager), 1e32); c.mint(address(manager), 1e32); vm.deal(address(manager), 100 ether);
        router = RouteExecutor(payable(address(new RoutePoolHarness(address(weth), adapters(), address(v4), address(v3), address(v1), address(ramses), address(factory), address(pools), address(0)))));
        vm.prank(user); a.approve(address(router), type(uint256).max); vm.prank(user); b.approve(address(router), type(uint256).max);
    }
    function pl(address output) private view returns (RouteExecutor.Leg memory) { return RouteExecutor.Leg(address(v3), output, 500, 0, address(0), false); }
    function plan(uint256 amount, address output) private view returns (RouteExecutor.Branch[] memory p) { p = direct(amount); p[0].legs[0] = pl(output); }
    function poolClean() private view { require(a.allowance(address(router), address(unused)) == 0 && a.allowance(address(router), address(poolAB)) == 0); cleared(); }
    function testPoolDirectReceipt() public {
        vm.prank(user); require(router.swap(address(a), address(b), 1 ether, 2 ether, user, block.timestamp, plan(1 ether, address(b))) == 2 ether); poolClean();
    }
    function testPoolGuardClearsForSequentialSwapsInSameTransaction() public {
        for (uint256 i; i < 2; ++i) {
            vm.prank(user); require(router.swap(address(a), address(b), 1 ether, 2 ether, user, block.timestamp, plan(1 ether, address(b))) == 2 ether);
            poolClean();
        }
    }
    function testPoolGuardRollsBackAfterRevertedSwap() public {
        vm.expectRevert(RouteExecutor.SlippageExceeded.selector); vm.prank(user);
        router.swap(address(a), address(b), 1 ether, 3 ether, user, block.timestamp, plan(1 ether, address(b)));
        vm.prank(user); require(router.swap(address(a), address(b), 1 ether, 2 ether, user, block.timestamp, plan(1 ether, address(b))) == 2 ether);
        poolClean();
    }
    function testPoolMultipleHopsAndDonations() public {
        a.mint(address(router), 17); b.mint(address(router), 18); c.mint(address(router), 19);
        RouteExecutor.Branch[] memory p = plan(1 ether, address(b)); p[0].legs = new RouteExecutor.Leg[](2); p[0].legs[0] = pl(address(c)); p[0].legs[1] = pl(address(b));
        vm.prank(user); require(router.swap(address(a), address(b), 1 ether, 4 ether, user, block.timestamp, p) == 4 ether);
        require(a.balanceOf(address(router)) == 17 && b.balanceOf(address(router)) == 18 && c.balanceOf(address(router)) == 19); poolClean();
    }
    function testPoolSplitWithRamsesAndV2Fallback() public {
        RouteExecutor.Branch[] memory p = new RouteExecutor.Branch[](3);
        p[0] = plan(1 ether, address(b))[0]; p[1] = rplan(2 ether, address(b))[0]; p[2] = direct(3 ether)[0]; p[2].legs[0].adapter = address(v2);
        vm.prank(user); require(router.swap(address(a), address(b), 6 ether, 17 ether, user, block.timestamp, p) == 17 ether); poolClean();
    }
    function testPoolMixedV4() public {
        RouteExecutor.Branch[] memory p = plan(1 ether, address(b)); p[0].legs = new RouteExecutor.Leg[](2);
        p[0].legs[0] = pl(address(c)); p[0].legs[1] = RouteExecutor.Leg(address(v4), address(b), 500, 10, address(0), false);
        vm.prank(user); require(router.swap(address(a), address(b), 1 ether, 4 ether, user, block.timestamp, p) == 4 ether);
        require(c.allowance(address(router), address(v4)) == 0); poolClean();
    }
    function testPoolV4NativeFallbackStillWorks() public {
        RouteExecutor.Branch[] memory p = direct(1 ether); p[0].legs[0] = RouteExecutor.Leg(address(v4), address(b), 500, 10, address(0), true);
        vm.prank(user); require(router.swap{value: 1 ether}(address(0), address(b), 1 ether, 2 ether, user, block.timestamp, p) == 2 ether);
    }
    function testPoolV4HooksStillRejected() public {
        RouteExecutor.Branch[] memory p = direct(1 ether); p[0].legs[0] = RouteExecutor.Leg(address(v4), address(b), 500, 10, address(0x80), false);
        vm.prank(user); vm.expectRevert(V4Adapter.InvalidSwap.selector); router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, p);
    }
    function testPoolNativeInputOutput() public {
        vm.prank(user); require(router.swap{value: 1 ether}(address(0), address(b), 1 ether, 2 ether, user, block.timestamp, plan(1 ether, address(b))) == 2 ether);
        uint256 beforeNative = user.balance;
        vm.prank(user); require(router.swap(address(a), address(0), 1 ether, 2 ether, user, block.timestamp, plan(1 ether, address(weth))) == 2 ether);
        require(user.balance == beforeNative + 2 ether); poolClean();
    }
    function testPoolWrongCallerRejected() public { RoutePoolExecutor target = RoutePoolExecutor(payable(address(router))); vm.expectRevert(RoutePoolExecutor.CallbackRejected.selector); target.uniswapV3SwapCallback(1, -2, ""); }
    function testPoolPartialAndRepeatedCallbacksRejected() public {
        for (uint256 m = 1; m <= 7; m++) { poolAB.setMode(m); vm.prank(user); vm.expectRevert(RoutePoolExecutor.CallbackRejected.selector); router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, plan(1 ether, address(b))); }
    }
    function testPoolNoOutputRejected() public { poolAB.setMode(9); vm.prank(user); vm.expectRevert(RoutePoolExecutor.UnsupportedToken.selector); router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, plan(1 ether, address(b))); }
    function testPoolV2PairMixed() public {
        JitFactoryFixture pairs = new JitFactoryFixture(); pairs.add(c, b, 1000 ether, 1000 ether);
        router = RouteExecutor(payable(address(new RoutePoolHarness(address(weth), adapters(), address(v4), address(v3), address(v1), address(ramses), address(factory), address(pools), address(pairs)))));
        vm.prank(user); a.approve(address(router), 1 ether);
        RouteExecutor.Branch[] memory p = plan(1 ether, address(b)); p[0].legs = new RouteExecutor.Leg[](2); p[0].legs[0] = pl(address(c)); p[0].legs[1] = leg(address(v1), address(b));
        uint256 expected = uint256(2 ether) * 997 * 1000 ether / (1000 ether * 1000 + 2 ether * 997);
        vm.prank(user); require(router.swap(address(a), address(b), 1 ether, expected, user, block.timestamp, p) == expected); poolClean();
    }
    function testFuzzPoolSplitContext(uint96 raw, uint8 fraction) public {
        uint256 amount = uint256(raw) + 100; uint256 left = amount * (uint256(fraction) % 99 + 1) / 100;
        RouteExecutor.Branch[] memory p = new RouteExecutor.Branch[](2); p[0] = plan(left, address(b))[0]; p[1] = plan(amount - left, address(b))[0];
        vm.prank(user); require(router.swap(address(a), address(b), amount, amount * 2, user, block.timestamp, p) == amount * 2); poolClean();
    }
    function testPoolReentrancyBlocked() public {
        poolAB.setMode(8); poolAB.setReentry(abi.encodeCall(router.swap, (address(a), address(b), 1 ether, 1, user, block.timestamp, plan(1 ether, address(b)))));
        vm.prank(user); require(router.swap(address(a), address(b), 1 ether, 2 ether, user, block.timestamp, plan(1 ether, address(b))) == 2 ether); poolClean();
    }
    function testPoolTokenReentrancyBlocked() public {
        CallbackReentryToken token = new CallbackReentryToken(); pools.add(address(token), address(b)); token.mint(user, 1 ether);
        vm.prank(user); token.approve(address(router), 1 ether);
        token.configure(address(router), abi.encodeCall(router.swap, (address(token), address(b), 1 ether, 1, user, block.timestamp, plan(1 ether, address(b)))));
        vm.prank(user); require(router.swap(address(token), address(b), 1 ether, 2 ether, user, block.timestamp, plan(1 ether, address(b))) == 2 ether); require(token.blocked());
    }
    function testPoolTaxedInputAndOutputRejected() public {
        TaxToken token = new TaxToken(); pools.add(address(token), address(b)); pools.add(address(a), address(token)); token.mint(user, 1 ether);
        vm.prank(user); token.approve(address(router), 1 ether);
        vm.prank(user); vm.expectRevert(RoutePoolExecutor.UnsupportedToken.selector); router.swap(address(token), address(b), 1 ether, 1, user, block.timestamp, plan(1 ether, address(b)));
        vm.prank(user); vm.expectRevert(RoutePoolExecutor.UnsupportedToken.selector); router.swap(address(a), address(token), 1 ether, 1, user, block.timestamp, plan(1 ether, address(token)));
    }
}
