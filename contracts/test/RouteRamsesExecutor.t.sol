// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteRamsesExecutor} from "../RouteRamsesExecutor.sol";
import {IRamsesRouter} from "../interfaces/IRamsesRouter.sol";
import {RouteExecutor} from "../RouteExecutor.sol";
import {RouteExecutorTest} from "./RouteExecutor.t.sol";
import {TaxToken, RejectNative} from "./Route.t.sol";
import {FastMockV3, FastNativeRecipient} from "./RouteFastExecutor.t.sol";
import {V3Adapter} from "../adapters/V3Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RamsesMock {
    address public immutable WETH9;
    address public immutable deployer;
    uint256 public fillBps = 10000;
    bool public zeroOutput;
    address public callbackTarget;
    bytes public callbackData;
    bool public reentryPrevented;
    constructor(address wrapped) { WETH9 = wrapped; deployer = address(this); }
    function setFill(uint256 bps) external { fillBps = bps; }
    function setZeroOutput() external { zeroOutput = true; }
    function setCallback(address target, bytes calldata data) external { callbackTarget = target; callbackData = data; }
    function exactInputSingle(IRamsesRouter.Params calldata p) external payable returns (uint256) {
        require((p.tickSpacing == 1 || p.tickSpacing == 100) && p.deadline >= block.timestamp);
        require(p.sqrtPriceLimitX96 == 0 && p.amountOutMinimum == 1 && p.recipient == msg.sender && msg.value == 0);
        require(IERC20(p.tokenIn).allowance(msg.sender, address(this)) == p.amountIn);
        require(IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn * fillBps / 10000));
        if (callbackTarget != address(0)) {
            (bool ok, bytes memory data) = callbackTarget.call(callbackData);
            require(!ok && bytes4(data) == bytes4(keccak256("ReentrancyGuardReentrantCall()")));
            reentryPrevented = true;
        }
        if (!zeroOutput) require(IERC20(p.tokenOut).transfer(p.recipient, p.amountIn * 3));
        return type(uint256).max;
    }
}
contract RamsesFactoryMock {
    address public immutable ramsesV3PoolDeployer;
    constructor(address deployer) { ramsesV3PoolDeployer = deployer; }
}

/// Retain the original executor suite and exercise Ramses alongside the V2 fast path.
contract RouteRamsesExecutorTest is RouteExecutorTest {
    RamsesMock ramses;
    RamsesFactoryMock factory;
    function _makeExecutor(address wrapped, address[] memory adapters, address v4, address v3, address v2, address ram, address ramFactory) internal virtual returns (address) {
        return address(new RouteRamsesExecutor(wrapped, adapters, v4, v3, v2, ram, ramFactory));
    }
    function deployExecutor(address wrapped, address[] memory adapters) internal override returns (RouteExecutor) {
        ramses = new RamsesMock(wrapped); factory = new RamsesFactoryMock(address(ramses));
        address[] memory all = new address[](adapters.length + 1);
        for (uint256 i; i < adapters.length; i++) all[i] = adapters[i];
        all[adapters.length] = address(ramses);
        return RouteExecutor(payable(address(_makeExecutor(wrapped, all, address(0), address(0), adapters[0], address(ramses), address(factory)))));
    }
    function setUp() public virtual override {
        super.setUp();
        a.mint(address(ramses), 1e32); b.mint(address(ramses), 1e32); c.mint(address(ramses), 1e32); weth.mint(address(ramses), 1e32);
    }
    function rleg(address output) internal view returns (RouteExecutor.Leg memory) {
        return RouteExecutor.Leg(address(ramses), output, 0, 100, address(0), false);
    }
    function rplan(uint256 amount, address output) internal view returns (RouteExecutor.Branch[] memory p) {
        p = direct(amount); p[0].legs[0] = rleg(output);
    }
    function cleared() internal view {
        require(a.allowance(address(router), address(ramses)) == 0);
        require(b.allowance(address(router), address(ramses)) == 0);
        require(c.allowance(address(router), address(ramses)) == 0);
        require(weth.allowance(address(router), address(ramses)) == 0);
    }
    function testRamsesBindings() public view {
        RouteRamsesExecutor r = RouteRamsesExecutor(payable(address(router)));
        require(r.ramsesRouter() == address(ramses) && r.ramsesFactory() == address(factory));
        require(r.allowedAdapter(address(ramses)) && r.fastV2Router() == address(dex1));
    }
    function testRamsesActualOutputAndDonations() public {
        a.mint(address(router), 7); b.mint(address(router), 8);
        uint256 beforeIn = a.balanceOf(user); uint256 beforeOut = b.balanceOf(user);
        vm.prank(user); uint256 out = router.swap(address(a), address(b), 1 ether, 3 ether, user, block.timestamp, rplan(1 ether, address(b)));
        require(out == 3 ether && beforeIn - a.balanceOf(user) == 1 ether && b.balanceOf(user) - beforeOut == out);
        require(a.balanceOf(address(router)) == 7 && b.balanceOf(address(router)) == 8); cleared();
    }
    function testRamsesNativeInput() public {
        uint256 beforeOut = b.balanceOf(user);
        vm.prank(user); uint256 out = router.swap{value: 1 ether}(address(0), address(b), 1 ether, 3 ether, user, block.timestamp, rplan(1 ether, address(b)));
        require(out == 3 ether && b.balanceOf(user) - beforeOut == out && address(router).balance == 0 && weth.balanceOf(address(router)) == 0); cleared();
    }
    function testRamsesNativeOutput() public {
        uint256 beforeOut = user.balance;
        vm.prank(user); uint256 out = router.swap(address(a), address(0), 1 ether, 3 ether, user, block.timestamp, rplan(1 ether, address(weth)));
        require(out == 3 ether && user.balance - beforeOut == out && address(router).balance == 0); cleared();
    }
    function testRamsesPartialInputRollsBack() public {
        ramses.setFill(5000); uint256 beforeIn = a.balanceOf(user);
        vm.prank(user); vm.expectRevert(RouteExecutor.UnsupportedToken.selector);
        router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, rplan(1 ether, address(b)));
        require(a.balanceOf(user) == beforeIn); cleared();
    }
    function testRamsesZeroOutputRollsBack() public {
        ramses.setZeroOutput(); vm.prank(user); vm.expectRevert(RouteExecutor.SlippageExceeded.selector);
        router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, rplan(1 ether, address(b))); cleared();
    }
    function testRamsesMinimumRollsBack() public {
        uint256 beforeIn = a.balanceOf(user); vm.prank(user); vm.expectRevert(RouteExecutor.SlippageExceeded.selector);
        router.swap(address(a), address(b), 1 ether, 3 ether + 1, user, block.timestamp, rplan(1 ether, address(b)));
        require(a.balanceOf(user) == beforeIn); cleared();
    }
    function testRamsesRejectsWrongFields() public {
        for (uint256 i; i < 6; i++) {
            RouteExecutor.Branch[] memory p = rplan(1 ether, address(b));
            if (i == 0) p[0].legs[0].fee = 1000;
            if (i == 1) p[0].legs[0].tickSpacing = -1;
            if (i == 2) p[0].legs[0].tickSpacing = 0;
            if (i == 3) p[0].legs[0].tickSpacing = 32768;
            if (i == 4) p[0].legs[0].hooks = address(1);
            if (i == 5) p[0].legs[0].nativePool = true;
            vm.prank(user); vm.expectRevert(RouteExecutor.InvalidRoute.selector);
            router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, p);
        }
    }
    function testRamsesRouterReentryBlocked() public {
        ramses.setCallback(address(router), abi.encodeCall(router.swap, (address(a), address(b), 1 ether, 1, user, block.timestamp, rplan(1 ether, address(b)))));
        vm.prank(user); router.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, rplan(1 ether, address(b)));
        require(ramses.reentryPrevented()); cleared();
    }
    function testRamsesNativeRecipientReentryBlocked() public {
        FastNativeRecipient receiver = new FastNativeRecipient();
        receiver.bind(address(router), abi.encodeCall(router.swap, (address(a), address(b), 1 ether, 1, user, block.timestamp, rplan(1 ether, address(b)))));
        vm.prank(user); router.swap(address(a), address(0), 1 ether, 3 ether, address(receiver), block.timestamp, rplan(1 ether, address(weth)));
        require(receiver.prevented() && address(receiver).balance == 3 ether); cleared();
    }
    function testRamsesRejectingNativeRecipientRollsBack() public {
        RejectNative receiver = new RejectNative(); uint256 beforeIn = a.balanceOf(user);
        vm.prank(user); vm.expectRevert(RouteExecutor.NativeTransferFailed.selector);
        router.swap(address(a), address(0), 1 ether, 1, address(receiver), block.timestamp, rplan(1 ether, address(weth)));
        require(a.balanceOf(user) == beforeIn); cleared();
    }
    function testRamsesTaxedRecipientOutputRejected() public {
        TaxToken tax = new TaxToken(); tax.mint(address(ramses), 100 ether);
        vm.prank(user); vm.expectRevert(RouteExecutor.UnsupportedToken.selector);
        router.swap(address(a), address(tax), 1 ether, 1, user, block.timestamp, rplan(1 ether, address(tax))); cleared();
    }
    function testRamsesMixedV2AndAdapter() public {
        // Ramses -> fast V2, then the same edges in a separate split branch using fallback.
        dex1.setRate(address(c), address(b), 2e18);
        RouteExecutor.Branch[] memory p = new RouteExecutor.Branch[](2);
        p[0] = rplan(1 ether, address(b))[0]; p[0].legs = new RouteExecutor.Leg[](2);
        p[0].legs[0] = rleg(address(c)); p[0].legs[1] = leg(address(v1), address(b));
        p[1] = direct(2 ether)[0]; p[1].legs[0].adapter = address(v2);
        c.mint(address(router), 17);
        vm.prank(user); require(router.swap(address(a), address(b), 3 ether, 12 ether, user, block.timestamp, p) == 12 ether);
        require(c.balanceOf(address(router)) == 17 && c.allowance(address(router), address(dex1)) == 0); cleared();
    }
    function testRamsesMixedFastV3() public {
        FastMockV3 dex3 = new FastMockV3(); uint24[] memory fees = new uint24[](1); fees[0] = 500;
        V3Adapter v3 = new V3Adapter("v3", address(dex3), address(dex3), fees);
        address[] memory adapters = new address[](3); adapters[0] = address(v1); adapters[1] = address(v3); adapters[2] = address(ramses);
        router = RouteExecutor(payable(address(_makeExecutor(address(weth), adapters, address(0), address(v3), address(v1), address(ramses), address(factory)))));
        vm.prank(user); a.approve(address(router), 1 ether); b.mint(address(dex3), 100 ether);
        RouteExecutor.Branch[] memory p = rplan(1 ether, address(b)); p[0].legs = new RouteExecutor.Leg[](2);
        p[0].legs[0] = rleg(address(c)); p[0].legs[1] = leg(address(v3), address(b)); p[0].legs[1].fee = 500;
        vm.prank(user); require(router.swap(address(a), address(b), 1 ether, 9 ether, user, block.timestamp, p) == 9 ether);
        require(c.allowance(address(router), address(dex3)) == 0 && c.balanceOf(address(router)) == 0); cleared();
    }
    function testRamsesConstructorBindingFailures() public {
        address[] memory adapters = new address[](2); adapters[0] = address(v1); adapters[1] = address(ramses);
        RamsesFactoryMock wrong = new RamsesFactoryMock(address(v1));
        vm.expectRevert(RouteExecutor.InvalidRoute.selector);
        _makeExecutor(address(weth), adapters, address(0), address(0), address(v1), address(ramses), address(wrong));
        vm.expectRevert(RouteExecutor.InvalidRoute.selector);
        _makeExecutor(address(a), adapters, address(0), address(0), address(v1), address(ramses), address(factory));
        vm.expectRevert(RouteExecutor.InvalidRoute.selector);
        _makeExecutor(address(weth), adapters, address(ramses), address(0), address(v1), address(ramses), address(factory));
    }
    function testFuzzRamsesSplitExactInput(uint96 input, uint8 fraction) public {
        uint256 amount = uint256(input) + 100; uint256 left = amount * (uint256(fraction) % 99 + 1) / 100;
        RouteExecutor.Branch[] memory p = new RouteExecutor.Branch[](2); p[0] = rplan(left, address(b))[0]; p[1] = direct(amount - left)[0];
        uint256 beforeIn = a.balanceOf(user); uint256 beforeOut = b.balanceOf(user);
        vm.prank(user); uint256 out = router.swap(address(a), address(b), amount, 1, user, block.timestamp, p);
        require(out == left * 3 + (amount - left) * 2 && beforeIn - a.balanceOf(user) == amount && b.balanceOf(user) - beforeOut == out); cleared();
    }
}
