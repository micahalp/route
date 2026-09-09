// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {RouteFastExecutor} from "../RouteFastExecutor.sol";
import {RouteExecutor} from "../RouteExecutor.sol";
import {RouteExecutorTest} from "./RouteExecutor.t.sol";
import {TaxToken, RejectNative, MockDex} from "./Route.t.sol";
import {V2Adapter} from "../adapters/V2Adapter.sol";
import {V3Adapter, IV3Router, IV3Quoter} from "../adapters/V3Adapter.sol";
import {V4Adapter} from "../adapters/V4Adapter.sol";
import {MockManager} from "./V4Execution.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FastMockV3 {
    bool public partialFill;
    bool public callback;
    address public callbackTarget;
    bytes public callbackData;
    bool public reentryPrevented;

    function setPartial() external {
        partialFill = true;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = true;
        callbackTarget = target;
        callbackData = data;
    }

    function quoteExactInputSingle(IV3Quoter.Params calldata p)
        external
        pure
        returns (uint256, uint160, uint32, uint256)
    {
        return (p.amountIn * 3, 1, 0, 1);
    }

    function exactInputSingle(IV3Router.Params calldata p) external payable returns (uint256) {
        require(
            p.fee == 500 && p.sqrtPriceLimitX96 == 0 && p.recipient == msg.sender && msg.value == 0
        );
        require(
            IERC20(p.tokenIn)
                .transferFrom(msg.sender, address(this), partialFill ? p.amountIn / 2 : p.amountIn)
        );
        if (callback) {
            (bool ok, bytes memory data) = callbackTarget.call(callbackData);
            require(!ok && bytes4(data) == bytes4(keccak256("ReentrancyGuardReentrantCall()")));
            reentryPrevented = true;
        }
        require(IERC20(p.tokenOut).transfer(p.recipient, p.amountIn * 3));
        return type(uint256).max; // Settlement must use balances, not this claim.
    }
}

contract FastNativeRecipient {
    address public target;
    bytes public data;
    bool public prevented;

    function bind(address t, bytes calldata d) external {
        target = t;
        data = d;
    }

    receive() external payable {
        (bool ok, bytes memory result) = target.call(data);
        require(!ok && bytes4(result) == bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        prevented = true;
    }
}

contract FastMockV2 is MockDex {
    bool public partialFill;
    address public callbackTarget;
    bytes public callbackData;
    bool public reentryPrevented;

    function setPartial() external {
        partialFill = true;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function swapExactTokensForTokens(
        uint256 amount,
        uint256 minOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        require(path.length == 2 && to == msg.sender && deadline == block.timestamp);
        require(!failSwap && rate[path[0]][path[1]] != 0);
        uint256 output = amount * rate[path[0]][path[1]] / 1e18 * executionBps / 10000;
        require(output >= minOut);
        require(
            IERC20(path[0])
                .transferFrom(msg.sender, address(this), partialFill ? amount / 2 : amount)
        );
        if (callbackTarget != address(0)) {
            (bool ok, bytes memory data) = callbackTarget.call(callbackData);
            require(!ok && bytes4(data) == bytes4(keccak256("ReentrancyGuardReentrantCall()")));
            reentryPrevented = true;
        }
        require(IERC20(path[1]).transfer(to, output));
        amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = type(uint256).max;
    }
}

/// Run the complete original executor suite with the fast path disabled.
contract RouteFastFallbackTest is RouteExecutorTest {
    function deployExecutor(address wrapped, address[] memory venues)
        internal
        override
        returns (RouteExecutor)
    {
        return RouteExecutor(
            payable(address(
                    new RouteFastExecutor(wrapped, venues, address(0), address(0), address(0))
                ))
        );
    }
}

/// The V2 fast path also works when no V3 fast path is configured.
contract RouteFastV2OnlyTest is RouteExecutorTest {
    function deployExecutor(address wrapped, address[] memory venues)
        internal
        override
        returns (RouteExecutor)
    {
        return RouteExecutor(
            payable(address(
                    new RouteFastExecutor(wrapped, venues, address(0), address(0), venues[0])
                ))
        );
    }

    function testFastV2OnlyConfiguration() public view {
        RouteFastExecutor fast = RouteFastExecutor(payable(address(router)));
        require(fast.fastV3Adapter() == address(0) && fast.fastV3Router() == address(0));
        require(!fast.isFastV3Fee(500));
        require(fast.fastV2Adapter() == address(v1) && fast.fastV2Router() == address(dex1));
    }
}

/// Also retain that suite with V3 configured, then exercise optimized and mixed routes.
contract RouteFastV3Test is RouteExecutorTest {
    FastMockV3 dex3;
    V3Adapter v3;

    function setUp() public virtual override {
        super.setUp();
        dex3 = new FastMockV3();
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        v3 = new V3Adapter("fast V3", address(dex3), address(dex3), fees);
        address[] memory venues = new address[](3);
        venues[0] = address(v1);
        venues[1] = address(v2);
        venues[2] = address(v3);
        router = RouteExecutor(
            payable(address(
                    new RouteFastExecutor(
                        address(weth), venues, address(0), address(v3), address(0)
                    )
                ))
        );
        vm.prank(user);
        a.approve(address(router), type(uint256).max);
        vm.prank(user);
        b.approve(address(router), type(uint256).max);
        a.mint(address(dex3), 1e32);
        b.mint(address(dex3), 1e32);
        c.mint(address(dex3), 1e32);
        weth.mint(address(dex3), 1e32);
    }

    function fastPlan(uint256 amount, address output)
        internal
        view
        returns (RouteExecutor.Branch[] memory p)
    {
        p = direct(amount);
        p[0].legs[0].adapter = address(v3);
        p[0].legs[0].fee = 500;
        p[0].legs[0].tokenOut = output;
    }

    function checkCleared() internal view {
        require(a.allowance(address(router), address(dex3)) == 0);
        require(a.allowance(address(router), address(v3)) == 0);
        require(a.balanceOf(address(v3)) == 0 && b.balanceOf(address(v3)) == 0);
    }

    function testFastUsesActualOutputAndPreservesDonations() public {
        a.mint(address(router), 7);
        b.mint(address(router), 8);
        uint256 beforeInput = a.balanceOf(user);
        uint256 beforeOutput = b.balanceOf(user);
        vm.prank(user);
        uint256 out = router.swap(
            address(a),
            address(b),
            10 ether,
            30 ether,
            user,
            block.timestamp,
            fastPlan(10 ether, address(b))
        );
        require(
            out == 30 ether && b.balanceOf(user) - beforeOutput == out
                && beforeInput - a.balanceOf(user) == 10 ether
        );
        require(a.balanceOf(address(router)) == 7 && b.balanceOf(address(router)) == 8);
        checkCleared();
    }

    function testFastPartialFillRollsBack() public {
        dex3.setPartial();
        uint256 beforeBalance = a.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(RouteExecutor.UnsupportedToken.selector);
        router.swap(
            address(a), address(b), 1 ether, 1, user, block.timestamp, fastPlan(1 ether, address(b))
        );
        require(a.balanceOf(user) == beforeBalance);
        checkCleared();
    }

    function testFastFinalMinimumRollsBack() public {
        uint256 beforeBalance = a.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(RouteExecutor.SlippageExceeded.selector);
        router.swap(
            address(a),
            address(b),
            1 ether,
            3 ether + 1,
            user,
            block.timestamp,
            fastPlan(1 ether, address(b))
        );
        require(a.balanceOf(user) == beforeBalance);
        checkCleared();
    }

    function testFastOnlyConfiguredFee() public {
        RouteFastExecutor fast = RouteFastExecutor(payable(address(router)));
        require(fast.fastV3Router() == address(dex3) && fast.fastV3Adapter() == address(v3));
        require(fast.isFastV3Fee(500) && !fast.isFastV3Fee(100) && !fast.isFastV3Fee(0));
        RouteExecutor.Branch[] memory p = fastPlan(1 ether, address(b));
        p[0].legs[0].fee = 100;
        vm.prank(user);
        vm.expectRevert(RouteExecutor.InvalidRoute.selector);
        router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, p);
    }

    function testFastNativeInput() public {
        uint256 beforeBalance = b.balanceOf(user);
        vm.prank(user);
        router.swap{value: 1 ether}(
            address(0),
            address(b),
            1 ether,
            3 ether,
            user,
            block.timestamp,
            fastPlan(1 ether, address(b))
        );
        require(
            b.balanceOf(user) - beforeBalance == 3 ether
                && weth.allowance(address(router), address(dex3)) == 0
        );
        require(address(router).balance == 0 && weth.balanceOf(address(router)) == 0);
    }

    function testFastNativeOutput() public {
        uint256 beforeBalance = user.balance;
        vm.prank(user);
        router.swap(
            address(a),
            address(0),
            1 ether,
            3 ether,
            user,
            block.timestamp,
            fastPlan(1 ether, address(weth))
        );
        require(user.balance - beforeBalance == 3 ether && address(router).balance == 0);
        checkCleared();
    }

    function testFastRejectingRecipientRollsBack() public {
        RejectNative recipient = new RejectNative();
        uint256 beforeBalance = a.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(RouteExecutor.NativeTransferFailed.selector);
        router.swap(
            address(a),
            address(0),
            1 ether,
            1,
            address(recipient),
            block.timestamp,
            fastPlan(1 ether, address(weth))
        );
        require(a.balanceOf(user) == beforeBalance);
        checkCleared();
    }

    function testFastDexReentryRejected() public {
        RouteExecutor.Branch[] memory p = fastPlan(1 ether, address(b));
        dex3.setCallback(
            address(router),
            abi.encodeCall(
                router.swap, (address(a), address(b), 1 ether, 1, user, block.timestamp, p)
            )
        );
        vm.prank(user);
        router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, p);
        require(dex3.reentryPrevented());
        checkCleared();
    }

    function testFastRecipientReentryRejected() public {
        FastNativeRecipient recipient = new FastNativeRecipient();
        RouteExecutor.Branch[] memory p = fastPlan(1 ether, address(weth));
        recipient.bind(
            address(router),
            abi.encodeCall(
                router.swap, (address(a), address(0), 1 ether, 1, user, block.timestamp, p)
            )
        );
        vm.prank(user);
        router.swap(address(a), address(0), 1 ether, 1, address(recipient), block.timestamp, p);
        require(recipient.prevented() && address(recipient).balance == 3 ether);
        checkCleared();
    }

    function testFastTaxedInputRollsBack() public {
        TaxToken tax = new TaxToken();
        tax.mint(user, 1 ether);
        vm.prank(user);
        tax.approve(address(router), 1 ether);
        vm.prank(user);
        vm.expectRevert(RouteExecutor.UnsupportedToken.selector);
        router.swap(
            address(tax),
            address(b),
            1 ether,
            1,
            user,
            block.timestamp,
            fastPlan(1 ether, address(b))
        );
    }

    function testFastTaxedRecipientOutputRollsBack() public {
        TaxToken tax = new TaxToken();
        tax.mint(address(dex3), 100 ether);
        uint256 beforeInput = a.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(RouteExecutor.UnsupportedToken.selector);
        router.swap(
            address(a),
            address(tax),
            1 ether,
            1,
            user,
            block.timestamp,
            fastPlan(1 ether, address(tax))
        );
        require(a.balanceOf(user) == beforeInput && tax.balanceOf(user) == 0);
        checkCleared();
    }

    function testMixedV3AndAdapterHopsPreserveDonations() public {
        RouteExecutor.Branch[] memory p = fastPlan(1 ether, address(c));
        p[0].legs = new RouteExecutor.Leg[](3);
        p[0].legs[0] = fastPlan(1 ether, address(c))[0].legs[0];
        p[0].legs[1] = leg(address(v2), address(d));
        p[0].legs[2] = leg(address(v1), address(b));
        c.mint(address(router), 9);
        d.mint(address(router), 10);
        vm.prank(user);
        require(
            router.swap(address(a), address(b), 1 ether, 12 ether, user, block.timestamp, p)
                == 12 ether
        );
        require(c.balanceOf(address(router)) == 9 && d.balanceOf(address(router)) == 10);
        require(
            c.allowance(address(router), address(v2)) == 0
                && d.allowance(address(router), address(v1)) == 0
        );
        checkCleared();
    }

    function testFuzzFastMixedSplit(uint96 input, uint8 fraction) public {
        uint256 amount = uint256(input) + 2;
        uint256 left = amount * (uint256(fraction) % 99 + 1) / 100;
        if (left == 0 || left == amount) {
            return;
        }
        RouteExecutor.Branch[] memory p = new RouteExecutor.Branch[](2);
        p[0] = fastPlan(left, address(b))[0];
        p[1] = direct(amount - left)[0];
        uint256 beforeInput = a.balanceOf(user);
        vm.prank(user);
        uint256 out = router.swap(address(a), address(b), amount, 1, user, block.timestamp, p);
        require(out == left * 3 + (amount - left) * 2 && beforeInput - a.balanceOf(user) == amount);
        checkCleared();
    }

    function testInvalidFastConfigurationRejected() public {
        address[] memory venues = new address[](1);
        venues[0] = address(v1);
        vm.expectRevert(RouteFastExecutor.InvalidRoute.selector);
        new RouteFastExecutor(address(weth), venues, address(0), address(v3), address(0));
        vm.expectRevert(RouteFastExecutor.InvalidRoute.selector);
        new RouteFastExecutor(address(weth), venues, address(0), address(v1), address(0));
        venues[0] = address(v3);
        vm.expectRevert(RouteFastExecutor.InvalidRoute.selector);
        new RouteFastExecutor(address(weth), venues, address(v3), address(v3), address(0));
    }
}

contract RouteFastV4Test is RouteFastV3Test {
    MockManager manager;
    V4Adapter v4;

    function setUp() public virtual override {
        super.setUp();
        manager = new MockManager();
        v4 = new V4Adapter(address(manager), address(weth));
        address[] memory venues = new address[](4);
        venues[0] = address(v1);
        venues[1] = address(v2);
        venues[2] = address(v3);
        venues[3] = address(v4);
        router = RouteExecutor(
            payable(address(
                    new RouteFastExecutor(
                        address(weth), venues, address(v4), address(v3), address(0)
                    )
                ))
        );
        vm.prank(user);
        a.approve(address(router), type(uint256).max);
        vm.prank(user);
        b.approve(address(router), type(uint256).max);
        b.mint(address(manager), 1e32);
        c.mint(address(manager), 1e32);
        vm.deal(address(manager), 100 ether);
    }

    function v4Leg(address output, bool nativePool)
        internal
        view
        returns (RouteExecutor.Leg memory)
    {
        return RouteExecutor.Leg(address(v4), output, 500, 10, address(0), nativePool);
    }

    function testFastMixedV3V4Route() public {
        RouteExecutor.Branch[] memory p = fastPlan(1 ether, address(c));
        p[0].legs = new RouteExecutor.Leg[](2);
        p[0].legs[0] = fastPlan(1 ether, address(c))[0].legs[0];
        p[0].legs[1] = v4Leg(address(b), false);
        vm.prank(user);
        require(
            router.swap(address(a), address(b), 1 ether, 6 ether, user, block.timestamp, p)
                == 6 ether
        );
        require(c.balanceOf(address(router)) == 0 && c.allowance(address(router), address(v4)) == 0);
        checkCleared();
    }

    function testFastV4NativePoolFallback() public {
        RouteExecutor.Branch[] memory p = direct(1 ether);
        p[0].legs[0] = v4Leg(address(b), true);
        vm.prank(user);
        require(
            router.swap{value: 1 ether}(
                address(0), address(b), 1 ether, 2 ether, user, block.timestamp, p
            ) == 2 ether
        );
        require(
            weth.balanceOf(address(router)) == 0 && address(router).balance == 0
                && weth.allowance(address(router), address(v4)) == 0
        );
    }

    function testFastV4HooksRemainRejected() public {
        RouteExecutor.Branch[] memory p = direct(1 ether);
        p[0].legs[0] = v4Leg(address(b), false);
        p[0].legs[0].hooks = address(0x80);
        vm.prank(user);
        vm.expectRevert(V4Adapter.InvalidSwap.selector);
        router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, p);
    }
}

/// Both optimized routers, V2 adapter fallback and V4 remain usable together.
contract RouteFastV2V3Test is RouteFastV4Test {
    FastMockV2 fastDex2;

    function setUp() public override {
        super.setUp();
        fastDex2 = new FastMockV2();
        dex1 = fastDex2;
        v1 = new V2Adapter("fast V2", address(dex1));
        dex1.setRate(address(a), address(b), 2e18);
        dex1.setRate(address(a), address(c), 2e18);
        dex1.setRate(address(d), address(b), 2e18);
        dex1.setRate(address(weth), address(b), 2e18);
        dex1.setRate(address(b), address(weth), 1e18);
        a.mint(address(dex1), 1e32);
        b.mint(address(dex1), 1e32);
        c.mint(address(dex1), 1e32);
        d.mint(address(dex1), 1e32);
        weth.mint(address(dex1), 1e32);
        address[] memory venues = new address[](4);
        venues[0] = address(v1);
        venues[1] = address(v2);
        venues[2] = address(v3);
        venues[3] = address(v4);
        router = RouteExecutor(
            payable(address(
                    new RouteFastExecutor(
                        address(weth), venues, address(v4), address(v3), address(v1)
                    )
                ))
        );
        vm.prank(user);
        a.approve(address(router), type(uint256).max);
        vm.prank(user);
        b.approve(address(router), type(uint256).max);
    }

    function checkV2Cleared() internal view {
        require(
            a.allowance(address(router), address(dex1)) == 0
                && b.allowance(address(router), address(dex1)) == 0
        );
        require(
            weth.allowance(address(router), address(dex1)) == 0
                && d.allowance(address(router), address(dex1)) == 0
        );
        require(
            a.allowance(address(router), address(v1)) == 0 && a.balanceOf(address(v1)) == 0
                && b.balanceOf(address(v1)) == 0
        );
    }

    function testFastV2UsesActualOutputAndPreservesDonations() public {
        a.mint(address(router), 7);
        b.mint(address(router), 8);
        uint256 beforeBalance = a.balanceOf(user);
        uint256 beforeOutput = b.balanceOf(user);
        vm.prank(user);
        uint256 out = router.swap(
            address(a), address(b), 1 ether, 2 ether, user, block.timestamp, direct(1 ether)
        );
        require(
            out == 2 ether && beforeBalance - a.balanceOf(user) == 1 ether
                && b.balanceOf(user) - beforeOutput == out
        );
        require(a.balanceOf(address(router)) == 7 && b.balanceOf(address(router)) == 8);
        checkV2Cleared();
    }

    function testFastV2PartialFillRollsBack() public {
        fastDex2.setPartial();
        uint256 beforeBalance = a.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(RouteExecutor.UnsupportedToken.selector);
        router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, direct(1 ether));
        require(a.balanceOf(user) == beforeBalance);
        checkV2Cleared();
    }

    function testFastV2NonzeroFeeRejected() public {
        RouteExecutor.Branch[] memory p = direct(1 ether);
        p[0].legs[0].fee = 500;
        vm.prank(user);
        vm.expectRevert(RouteExecutor.InvalidRoute.selector);
        router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, p);
        checkV2Cleared();
    }

    function testFastV2TaxedOutputRollsBack() public {
        TaxToken tax = new TaxToken();
        tax.mint(address(dex1), 100 ether);
        dex1.setRate(address(a), address(tax), 2e18);
        RouteExecutor.Branch[] memory p = direct(1 ether);
        p[0].legs[0].tokenOut = address(tax);
        uint256 beforeBalance = a.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(RouteExecutor.UnsupportedToken.selector);
        router.swap(address(a), address(tax), 1 ether, 1, user, block.timestamp, p);
        require(a.balanceOf(user) == beforeBalance && tax.balanceOf(user) == 0);
        checkV2Cleared();
    }

    function testFastV2DexReentryRejected() public {
        RouteExecutor.Branch[] memory p = direct(1 ether);
        fastDex2.setCallback(
            address(router),
            abi.encodeCall(
                router.swap, (address(a), address(b), 1 ether, 1, user, block.timestamp, p)
            )
        );
        vm.prank(user);
        router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, p);
        require(fastDex2.reentryPrevented());
        checkV2Cleared();
    }

    function testFastV2RecipientReentryRejected() public {
        FastNativeRecipient recipient = new FastNativeRecipient();
        RouteExecutor.Branch[] memory p = direct(1 ether);
        p[0].legs[0].tokenOut = address(weth);
        recipient.bind(
            address(router),
            abi.encodeCall(
                router.swap, (address(b), address(0), 1 ether, 1, user, block.timestamp, p)
            )
        );
        vm.prank(user);
        router.swap(address(b), address(0), 1 ether, 1, address(recipient), block.timestamp, p);
        require(recipient.prevented() && address(recipient).balance == 1 ether);
        checkV2Cleared();
    }

    function testFastV2ConfigurationIsFixedAndDistinct() public {
        RouteFastExecutor fast = RouteFastExecutor(payable(address(router)));
        require(fast.fastV2Adapter() == address(v1) && fast.fastV2Router() == address(dex1));
        address[] memory venues = new address[](2);
        venues[0] = address(v1);
        venues[1] = address(v3);
        vm.expectRevert(RouteFastExecutor.InvalidRoute.selector);
        new RouteFastExecutor(address(weth), venues, address(0), address(v3), address(v3));
        vm.expectRevert(RouteFastExecutor.InvalidRoute.selector);
        new RouteFastExecutor(address(weth), venues, address(v1), address(v3), address(v1));
        vm.expectRevert(RouteFastExecutor.InvalidRoute.selector);
        new RouteFastExecutor(address(weth), venues, address(0), address(v3), address(v2));
    }
}
