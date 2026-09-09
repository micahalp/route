// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteRamsesExecutor} from "../RouteRamsesExecutor.sol";
import {V2Adapter} from "../adapters/V2Adapter.sol";
import {Token, TaxToken, Wrapped, MockDex, Vm, RejectNative} from "./Route.t.sol";
import {JitFactoryFixture, JitPairFixture} from "./RouteJitV2Executor.t.sol";
import {RamsesMock, RamsesFactoryMock} from "./RouteRamsesExecutor.t.sol";

// The test-only override injects mocks into the otherwise identical swap body.
// Production eligibility still requires exact chain/router/factory runtime pins.
contract PairRamsesHarness is RouteRamsesExecutor {
    address private immutable testFactory;
    constructor(address wrapped, address fast, address fallbackAdapter, address ram, address ramFactory, address pairs)
        RouteRamsesExecutor(wrapped, _adapters(fast, fallbackAdapter, ram), address(0), address(0), fast, ram, ramFactory)
    { testFactory = pairs; }
    function _adapters(address a, address b, address c) private pure returns (address[] memory result) {
        result = new address[](3); result[0] = a; result[1] = b; result[2] = c;
    }
    function _v2PairFactory() internal view override returns (address) { return testFactory; }
}
contract PairReentryToken is Token {
    address public target;
    bytes public payload;
    bool public blocked;
    constructor() Token("REENTRY") {}
    function configure(address t, bytes memory p) external { target = t; payload = p; }
    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0) && target != address(0)) {
            (bool ok, bytes memory reason) = target.call(payload);
            require(!ok && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")));
            blocked = true;
        }
    }
}
contract PairSelectiveTaxToken is Token {
    address public taxedReceiver;
    constructor() Token("PAIR-TAX") {}
    function setReceiver(address receiver) external { taxedReceiver = receiver; }
    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to == taxedReceiver) {
            super._update(from, address(0), amount / 100);
            amount -= amount / 100;
        }
        super._update(from, to, amount);
    }
}
contract RouteRamsesPairTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token a; Token b; Token c; Wrapped wrapped;
    JitFactoryFixture factory;
    MockDex unusedRouter; MockDex fallbackDex;
    V2Adapter fast; V2Adapter fallbackAdapter;
    RamsesMock ram; RamsesFactoryMock ramFactory;
    PairRamsesHarness guard;
    address user = address(0xBEEF); address recipient = address(0xCAFE);
    function setUp() public {
        a = new Token("A"); b = new Token("B"); c = new Token("C"); wrapped = new Wrapped();
        factory = new JitFactoryFixture();
        factory.add(a, b, 1000 ether, 1000 ether); factory.add(a, c, 1000 ether, 1000 ether); factory.add(c, b, 1000 ether, 1000 ether);
        factory.add(wrapped, b, 1000 ether, 1000 ether); factory.add(a, wrapped, 1000 ether, 1000 ether);
        unusedRouter = new MockDex(); unusedRouter.setFailure(true, true);
        fallbackDex = new MockDex(); fallbackDex.setRate(address(b), address(c), 2 ether); c.mint(address(fallbackDex), 1000 ether);
        fast = new V2Adapter("canonical fixture", address(unusedRouter)); fallbackAdapter = new V2Adapter("other V2", address(fallbackDex));
        ram = new RamsesMock(address(wrapped)); ramFactory = new RamsesFactoryMock(address(ram));
        b.mint(address(ram), 1000 ether); c.mint(address(ram), 1000 ether);
        guard = new PairRamsesHarness(address(wrapped), address(fast), address(fallbackAdapter), address(ram), address(ramFactory), address(factory));
        a.mint(user, 100 ether); vm.prank(user); a.approve(address(guard), 10 ether);
        vm.deal(user, 100 ether); vm.deal(address(wrapped), 10000 ether);
    }
    function leg(address adapter, address token) private pure returns (RouteRamsesExecutor.Leg memory) {
        return RouteRamsesExecutor.Leg(adapter, token, 0, 0, address(0), false);
    }
    function plan(uint256 amount, address output) private view returns (RouteRamsesExecutor.Branch[] memory p) {
        p = new RouteRamsesExecutor.Branch[](1); p[0].amountIn = amount; p[0].legs = new RouteRamsesExecutor.Leg[](1); p[0].legs[0] = leg(address(fast), output);
    }
    function quote(uint256 amount) private pure returns (uint256) { return amount * 997 * 1000 ether / (1000 ether * 1000 + amount * 997); }
    function clean() private view {
        require(a.balanceOf(address(guard)) == 0 && b.balanceOf(address(guard)) == 0 && c.balanceOf(address(guard)) == 0 && wrapped.balanceOf(address(guard)) == 0);
        require(a.allowance(address(guard), address(unusedRouter)) == 0 && a.allowance(address(guard), address(fast)) == 0);
        require(b.allowance(address(guard), address(fallbackAdapter)) == 0 && b.allowance(address(guard), address(ram)) == 0);
    }
    function testPairExactInputOutputNoRouterApproval() public {
        uint256 before = a.balanceOf(user); vm.prank(user);
        uint256 out = guard.swap(address(a), address(b), 10 ether, quote(10 ether), recipient, block.timestamp, plan(10 ether, address(b)));
        require(out == quote(10 ether) && b.balanceOf(recipient) == out && before - a.balanceOf(user) == 10 ether);
        require(a.allowance(user, address(guard)) == 0); clean();
    }
    function testPairTwoHopsAndDonationPreservation() public {
        a.mint(address(guard), 7); b.mint(address(guard), 8); c.mint(address(guard), 9);
        RouteRamsesExecutor.Branch[] memory p = plan(10 ether, address(b)); p[0].legs = new RouteRamsesExecutor.Leg[](2);
        p[0].legs[0] = leg(address(fast), address(c)); p[0].legs[1] = leg(address(fast), address(b));
        vm.prank(user); require(guard.swap(address(a), address(b), 10 ether, quote(quote(10 ether)), recipient, block.timestamp, p) == quote(quote(10 ether)));
        require(a.balanceOf(address(guard)) == 7 && b.balanceOf(address(guard)) == 8 && c.balanceOf(address(guard)) == 9);
    }
    function testPairNativeInput() public {
        vm.prank(user); require(guard.swap{value: 10 ether}(address(0), address(b), 10 ether, quote(10 ether), recipient, block.timestamp, plan(10 ether, address(b))) == quote(10 ether)); clean();
    }
    function testPairNativeOutput() public {
        uint256 before = recipient.balance; vm.prank(user);
        require(guard.swap(address(a), address(0), 10 ether, quote(10 ether), recipient, block.timestamp, plan(10 ether, address(wrapped))) == quote(10 ether));
        require(recipient.balance - before == quote(10 ether)); clean();
    }
    function testPairMixedFallbackAdapter() public {
        RouteRamsesExecutor.Branch[] memory p = plan(10 ether, address(c)); p[0].legs = new RouteRamsesExecutor.Leg[](2);
        p[0].legs[0] = leg(address(fast), address(b)); p[0].legs[1] = leg(address(fallbackAdapter), address(c));
        vm.prank(user); require(guard.swap(address(a), address(c), 10 ether, quote(10 ether) * 2, recipient, block.timestamp, p) == quote(10 ether) * 2); clean();
    }
    function testPairMixedRamses() public {
        RouteRamsesExecutor.Branch[] memory p = plan(10 ether, address(c)); p[0].legs = new RouteRamsesExecutor.Leg[](2);
        p[0].legs[0] = leg(address(fast), address(b)); p[0].legs[1] = leg(address(ram), address(c)); p[0].legs[1].tickSpacing = 100;
        vm.prank(user); require(guard.swap(address(a), address(c), 10 ether, quote(10 ether) * 3, recipient, block.timestamp, p) == quote(10 ether) * 3); clean();
    }
    function testPairSplitWithRamses() public {
        RouteRamsesExecutor.Branch[] memory p = new RouteRamsesExecutor.Branch[](2); p[0] = plan(4 ether, address(b))[0]; p[1] = plan(6 ether, address(b))[0];
        p[1].legs[0].adapter = address(ram); p[1].legs[0].tickSpacing = 100;
        vm.prank(user); require(guard.swap(address(a), address(b), 10 ether, quote(4 ether) + 18 ether, recipient, block.timestamp, p) == quote(4 ether) + 18 ether); clean();
    }
    function testPairMinimumRollsBack() public {
        uint256 before = a.balanceOf(user); vm.prank(user); vm.expectRevert(RouteRamsesExecutor.SlippageExceeded.selector);
        guard.swap(address(a), address(b), 10 ether, quote(10 ether) + 1, recipient, block.timestamp, plan(10 ether, address(b)));
        require(a.balanceOf(user) == before && a.allowance(user, address(guard)) == 10 ether); clean();
    }
    function testPairDeadlineRejected() public {
        vm.warp(100); vm.prank(user); vm.expectRevert(RouteRamsesExecutor.DeadlineExpired.selector);
        guard.swap(address(a), address(b), 10 ether, 1, recipient, 99, plan(10 ether, address(b)));
    }
    function testPairNonzeroFeeRejected() public {
        RouteRamsesExecutor.Branch[] memory p = plan(10 ether, address(b)); p[0].legs[0].fee = 1;
        vm.prank(user); vm.expectRevert(RouteRamsesExecutor.InvalidRoute.selector); guard.swap(address(a), address(b), 10 ether, 1, recipient, block.timestamp, p); clean();
    }
    function testPairMissingAndEmptyPoolRejected() public {
        Token missing = new Token("M"); vm.prank(user); vm.expectRevert(RouteRamsesExecutor.InvalidRoute.selector);
        guard.swap(address(a), address(missing), 10 ether, 1, recipient, block.timestamp, plan(10 ether, address(missing)));
        factory.add(a, missing, 0, 0); vm.prank(user); vm.expectRevert(RouteRamsesExecutor.SlippageExceeded.selector);
        guard.swap(address(a), address(missing), 10 ether, 1, recipient, block.timestamp, plan(10 ether, address(missing)));
    }
    function testPairTaxedInputRejected() public {
        TaxToken tax = new TaxToken(); factory.add(tax, b, 1000 ether, 1000 ether); tax.mint(user, 10 ether);
        vm.prank(user); tax.approve(address(guard), 10 ether); vm.prank(user); vm.expectRevert(RouteRamsesExecutor.UnsupportedToken.selector);
        guard.swap(address(tax), address(b), 10 ether, 1, recipient, block.timestamp, plan(10 ether, address(b)));
    }
    function testPairTaxedOutputRejected() public {
        TaxToken tax = new TaxToken(); factory.add(a, tax, 1000 ether, 1000 ether);
        vm.prank(user); vm.expectRevert(RouteRamsesExecutor.UnsupportedToken.selector);
        guard.swap(address(a), address(tax), 10 ether, 1, recipient, block.timestamp, plan(10 ether, address(tax))); clean();
    }
    function testPairTransferTaxRejectedAfterExactCallerReceipt() public {
        PairSelectiveTaxToken tax = new PairSelectiveTaxToken();
        JitPairFixture pair = factory.add(tax, b, 1000 ether, 1000 ether); tax.setReceiver(address(pair)); tax.mint(user, 10 ether);
        vm.prank(user); tax.approve(address(guard), 10 ether); vm.prank(user); vm.expectRevert(RouteRamsesExecutor.UnsupportedToken.selector);
        guard.swap(address(tax), address(b), 10 ether, 1, recipient, block.timestamp, plan(10 ether, address(b)));
        require(tax.balanceOf(user) == 10 ether && tax.balanceOf(address(guard)) == 0 && tax.balanceOf(address(pair)) == 1000 ether);
    }
    function testPairOversizedInputRejected() public {
        uint256 amount = uint256(type(uint112).max) + 1; a.mint(user, amount); vm.prank(user); a.approve(address(guard), amount);
        vm.prank(user); vm.expectRevert(RouteRamsesExecutor.InvalidAmount.selector);
        guard.swap(address(a), address(b), amount, 1, recipient, block.timestamp, plan(amount, address(b)));
    }
    function testPairRejectingNativeRecipientRollsBack() public {
        RejectNative receiver = new RejectNative(); uint256 before = a.balanceOf(user);
        vm.prank(user); vm.expectRevert(RouteRamsesExecutor.NativeTransferFailed.selector);
        guard.swap(address(a), address(0), 10 ether, 1, address(receiver), block.timestamp, plan(10 ether, address(wrapped)));
        require(a.balanceOf(user) == before && a.allowance(user, address(guard)) == 10 ether); clean();
    }
    function testPairTokenReentryBlocked() public {
        PairReentryToken token = new PairReentryToken(); factory.add(token, b, 1000 ether, 1000 ether); token.mint(user, 10 ether);
        token.configure(address(guard), abi.encodeCall(guard.swap, (address(token), address(b), 1, 1, recipient, block.timestamp, plan(1, address(b)))));
        vm.prank(user); token.approve(address(guard), 10 ether); vm.prank(user);
        require(guard.swap(address(token), address(b), 10 ether, 1, recipient, block.timestamp, plan(10 ether, address(b))) == quote(10 ether)); require(token.blocked());
    }
    function testUnrecognizedRouterCannotEnableProductionPairMath() public {
        // The mock-only override is deliberately not reflected by this getter.
        require(guard.fastV2PairFactory() == address(0));
        address[] memory adapters = new address[](2); adapters[0] = address(fast); adapters[1] = address(ram);
        RouteRamsesExecutor actual = new RouteRamsesExecutor(address(wrapped), adapters, address(0), address(0), address(fast), address(ram), address(ramFactory));
        require(actual.fastV2PairFactory() == address(0));
    }
    function testFuzzPairExactOutput(uint96 seed) public {
        uint256 amount = uint256(seed) % (10000 ether) + 2; a.mint(user, amount); vm.prank(user); a.approve(address(guard), amount);
        uint256 before = a.balanceOf(user); vm.prank(user);
        uint256 out = guard.swap(address(a), address(b), amount, quote(amount), recipient, block.timestamp, plan(amount, address(b)));
        require(out == quote(amount) && before - a.balanceOf(user) == amount && b.balanceOf(recipient) == out); clean();
    }
}
