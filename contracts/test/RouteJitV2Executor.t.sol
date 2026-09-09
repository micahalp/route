// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteJitV2Executor} from "../RouteJitV2Executor.sol";
import {Token, TaxToken, Wrapped, Vm} from "./Route.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract JitPairFixture {
    address public token0;
    address public token1;
    uint112 r0;
    uint112 r1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function sync() public {
        uint256 a = IERC20(token0).balanceOf(address(this));
        uint256 b = IERC20(token1).balanceOf(address(this));
        require(a <= type(uint112).max && b <= type(uint112).max);
        r0 = uint112(a);
        r1 = uint112(b);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, 0);
    }

    function swap(uint256 out0, uint256 out1, address to, bytes calldata data) external {
        require(data.length == 0 && (out0 > 0 || out1 > 0) && out0 < r0 && out1 < r1);
        if (out0 > 0) {
            IERC20(token0).transfer(to, out0);
        }
        if (out1 > 0) {
            IERC20(token1).transfer(to, out1);
        }
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 in0 = b0 > r0 - out0 ? b0 - (r0 - out0) : 0;
        uint256 in1 = b1 > r1 - out1 ? b1 - (r1 - out1) : 0;
        require(in0 > 0 || in1 > 0);
        require((b0 * 1000 - in0 * 3) * (b1 * 1000 - in1 * 3) >= uint256(r0) * r1 * 1000000, "K");
        sync();
    }
}

contract JitFactoryFixture {
    mapping(address => mapping(address => address)) public getPair;

    function add(Token a, Token b, uint256 reserveA, uint256 reserveB)
        external
        returns (JitPairFixture pair)
    {
        pair = new JitPairFixture(address(a), address(b));
        getPair[address(a)][address(b)] = address(pair);
        getPair[address(b)][address(a)] = address(pair);
        a.mint(address(pair), reserveA);
        b.mint(address(pair), reserveB);
        pair.sync();
    }
}

contract JitReentrantRecipient {
    RouteJitV2Executor guard;
    bool public blocked;

    constructor(RouteJitV2Executor target) {
        guard = target;
    }

    receive() external payable {
        address[] memory paths = new address[](1);
        try guard.swap(address(0), address(1), 1, 1, address(this), block.timestamp, paths, 0) {
            revert("reentry succeeded");
        } catch (bytes memory reason) {
            require(bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")));
            blocked = true;
        }
    }
}

contract JitRejectingRecipient {
    receive() external payable {
        revert("reject");
    }
}

contract RouteJitV2ExecutorTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token a;
    Token b;
    Token c;
    Wrapped wrapped;
    JitFactoryFixture factory;
    JitPairFixture direct;
    JitPairFixture first;
    JitPairFixture second;
    RouteJitV2Executor guard;
    address user = address(0xBEEF);
    address recipient = address(0xCAFE);

    function setUp() public {
        a = new Token("A");
        b = new Token("B");
        c = new Token("C");
        wrapped = new Wrapped();
        factory = new JitFactoryFixture();
        direct = factory.add(a, b, 1000 ether, 1000 ether);
        first = factory.add(a, c, 1000 ether, 1000 ether);
        second = factory.add(c, b, 1000 ether, 1000 ether);
        factory.add(a, wrapped, 1000 ether, 1000 ether);
        factory.add(wrapped, b, 1000 ether, 1000 ether);
        vm.deal(address(wrapped), 10000 ether);
        vm.deal(user, 100 ether);
        guard = new RouteJitV2Executor(address(factory), address(wrapped));
        a.mint(user, 100 ether);
        vm.prank(user);
        a.approve(address(guard), 10 ether);
    }

    function paths(bool adaptive) private view returns (address[] memory result) {
        result = new address[](adaptive ? 2 : 1);
        if (adaptive) {
            result[1] = address(c);
        }
    }

    function swap(address[] memory p, uint256 minimum, uint256 threshold)
        private
        returns (uint256)
    {
        vm.prank(user);
        return guard.swap(
            address(a), address(b), 10 ether, minimum, recipient, block.timestamp, p, threshold
        );
    }

    function assertClean() private view {
        require(
            a.balanceOf(address(guard)) == 0 && b.balanceOf(address(guard)) == 0
                && c.balanceOf(address(guard)) == 0
        );
        require(
            a.allowance(address(guard), address(direct)) == 0
                && a.allowance(user, address(guard)) == 0
        );
    }

    function testStaticDirectExactOutput() public {
        (uint256 quoted, uint256 index) =
            guard.quote(address(a), address(b), 10 ether, paths(false), 0);
        require(index == 0 && swap(paths(false), quoted, 0) == quoted);
        require(a.balanceOf(user) == 90 ether && b.balanceOf(recipient) == quoted);
        assertClean();
    }

    function testJitChangesPathAfterQuoteWithoutChangingSignedLimits() public {
        address[] memory p = paths(true);
        (uint256 oldQuote, uint256 oldIndex) = guard.quote(address(a), address(b), 10 ether, p, 0);
        require(oldIndex == 0);
        // Change the direct pool's reserves between quote time and execution.
        a.mint(address(direct), 1000 ether);
        direct.sync();
        (uint256 newQuote, uint256 newIndex) = guard.quote(address(a), address(b), 10 ether, p, 0);
        require(newIndex == 1 && newQuote >= oldQuote * 98 / 100);
        uint256 untouchedDirect = a.balanceOf(address(direct));
        require(swap(p, oldQuote * 98 / 100, 0) == newQuote);
        require(
            a.balanceOf(address(direct)) == untouchedDirect
                && a.balanceOf(address(first)) == 1010 ether
        );
        require(b.balanceOf(recipient) == newQuote);
        assertClean();
    }

    function testThresholdRetainsOriginalPath() public {
        a.mint(address(direct), 1000 ether);
        direct.sync();
        (uint256 baseline,) = guard.quote(address(a), address(b), 10 ether, paths(false), 0);
        (uint256 better,) = guard.quote(address(a), address(b), 10 ether, paths(true), 0);
        require(better > baseline);
        require(swap(paths(true), baseline, better - baseline + 1) == baseline);
    }

    function testThresholdEqualityAllowsSwitch() public {
        a.mint(address(direct), 1000 ether);
        direct.sync();
        (uint256 baseline,) = guard.quote(address(a), address(b), 10 ether, paths(false), 0);
        (uint256 better,) = guard.quote(address(a), address(b), 10 ether, paths(true), 0);
        require(swap(paths(true), better, better - baseline) == better);
    }

    function testOriginalStillBestKeepsIt() public {
        uint256 beforeFirst = a.balanceOf(address(first));
        swap(paths(true), 1, 0);
        require(a.balanceOf(address(first)) == beforeFirst);
        assertClean();
    }

    function testMinimumNeverRelaxedToAvoidRevert() public {
        address[] memory p = paths(true);
        vm.expectRevert(RouteJitV2Executor.SlippageExceeded.selector);
        swap(p, 11 ether, 0);
        require(a.balanceOf(user) == 100 ether && b.balanceOf(recipient) == 0);
        require(a.allowance(user, address(guard)) == 10 ether);
    }

    function testDeadlineEnforcedBeforeAnySpend() public {
        vm.warp(100);
        address[] memory p = paths(true);
        vm.prank(user);
        vm.expectRevert(RouteJitV2Executor.DeadlineExpired.selector);
        guard.swap(address(a), address(b), 10 ether, 1, recipient, 99, p, 0);
        require(a.balanceOf(user) == 100 ether);
    }

    function testMissingPrimaryUsesAuthorizedBackup() public {
        Token absent = new Token("MISSING");
        address[] memory p = new address[](2);
        p[0] = address(absent);
        (uint256 out, uint256 index) =
            guard.quote(address(a), address(b), 10 ether, p, type(uint256).max);
        require(index == 1 && swap(p, out, type(uint256).max) == out);
    }

    function testAllMissingReverts() public {
        Token absent = new Token("MISSING");
        address[] memory p = new address[](1);
        p[0] = address(absent);
        vm.expectRevert(RouteJitV2Executor.NoRoute.selector);
        swap(p, 1, 0);
    }

    function testDuplicatePathsRejected() public {
        address[] memory p = new address[](2);
        vm.expectRevert(RouteJitV2Executor.InvalidRoute.selector);
        swap(p, 1, 0);
    }

    function testTooManyPathsRejected() public {
        address[] memory p = new address[](3);
        vm.expectRevert(RouteJitV2Executor.InvalidRoute.selector);
        swap(p, 1, 0);
    }

    function testCycleRejected() public {
        address[] memory p = new address[](1);
        p[0] = address(a);
        vm.expectRevert(RouteJitV2Executor.InvalidRoute.selector);
        swap(p, 1, 0);
    }

    function testZeroMinimumRejected() public {
        address[] memory p = paths(true);
        vm.expectRevert(RouteJitV2Executor.InvalidAmount.selector);
        swap(p, 0, 0);
    }

    function testEmptyPathsRejected() public {
        address[] memory p = new address[](0);
        vm.expectRevert(RouteJitV2Executor.InvalidRoute.selector);
        swap(p, 1, 0);
    }

    function testNativeInputAndOutput() public {
        address[] memory p = paths(false);
        (uint256 out,) = guard.quote(address(0), address(b), 1 ether, p, 0);
        vm.prank(user);
        require(
            guard.swap{value: 1 ether}(
                address(0), address(b), 1 ether, out, recipient, block.timestamp, p, 0
            ) == out
        );
        (out,) = guard.quote(address(a), address(0), 10 ether, p, 0);
        vm.prank(user);
        require(
            guard.swap(address(a), address(0), 10 ether, out, recipient, block.timestamp, p, 0)
                == out
        );
        require(recipient.balance == out && user.balance == 99 ether);
        assertClean();
    }

    function testDonationsPreserved() public {
        a.mint(address(guard), 7);
        b.mint(address(guard), 8);
        c.mint(address(guard), 9);
        vm.deal(address(guard), 10);
        b.mint(recipient, 11);
        uint256 out = swap(paths(true), 1, 0);
        require(
            a.balanceOf(address(guard)) == 7 && b.balanceOf(address(guard)) == 8
                && c.balanceOf(address(guard)) == 9 && address(guard).balance == 10
        );
        require(b.balanceOf(recipient) == out + 11);
    }

    function testTaxedInputRejected() public {
        TaxToken tax = new TaxToken();
        factory.add(tax, b, 1000 ether, 1000 ether);
        tax.mint(user, 10 ether);
        vm.prank(user);
        tax.approve(address(guard), 10 ether);
        address[] memory p = paths(false);
        vm.prank(user);
        vm.expectRevert(RouteJitV2Executor.UnsupportedToken.selector);
        guard.swap(address(tax), address(b), 10 ether, 1, recipient, block.timestamp, p, 0);
        require(tax.balanceOf(user) == 10 ether);
    }

    function testTaxedOutputRejectedEvenWithLowMinimum() public {
        TaxToken tax = new TaxToken();
        factory.add(a, tax, 1000 ether, 1000 ether);
        address[] memory p = paths(false);
        vm.prank(user);
        vm.expectRevert(RouteJitV2Executor.UnsupportedToken.selector);
        guard.swap(address(a), address(tax), 10 ether, 1, recipient, block.timestamp, p, 0);
        require(a.balanceOf(user) == 100 ether);
    }

    function testTaxedIntermediateRejected() public {
        TaxToken tax = new TaxToken();
        factory.add(a, tax, 1000 ether, 1000 ether);
        factory.add(tax, b, 1000 ether, 1000 ether);
        address[] memory p = new address[](1);
        p[0] = address(tax);
        vm.expectRevert(RouteJitV2Executor.UnsupportedToken.selector);
        swap(p, 1, 0);
    }

    function testRecipientReentryBlocked() public {
        JitReentrantRecipient receiver = new JitReentrantRecipient(guard);
        address[] memory p = paths(false);
        vm.prank(user);
        guard.swap(address(a), address(0), 10 ether, 1, address(receiver), block.timestamp, p, 0);
        require(receiver.blocked());
        assertClean();
    }

    function testFuzzStaticQuoteExecutionParity(uint96 rawAmount) public {
        uint256 amount = uint256(rawAmount) % 10 ether + 1;
        address[] memory p = paths(false);
        if (amount == 1) {
            vm.expectRevert(RouteJitV2Executor.NoRoute.selector);
            guard.quote(address(a), address(b), amount, p, 0);
            return;
        }
        (uint256 quote,) = guard.quote(address(a), address(b), amount, p, 0);
        require(quote > 0);
        vm.prank(user);
        require(
            guard.swap(address(a), address(b), amount, quote, recipient, block.timestamp, p, 0)
                == quote
        );
        require(a.balanceOf(user) == 100 ether - amount && b.balanceOf(recipient) == quote);
    }

    function testDustCannotSpendOrReturnZeroOutput() public {
        address[] memory p = paths(true);
        vm.prank(user);
        vm.expectRevert(RouteJitV2Executor.NoRoute.selector);
        guard.swap(address(a), address(b), 1, 1, recipient, block.timestamp, p, 0);
        require(a.balanceOf(user) == 100 ether && a.allowance(user, address(guard)) == 10 ether);
    }

    function testAmountBounds() public {
        address[] memory p = paths(false);
        vm.expectRevert(RouteJitV2Executor.InvalidAmount.selector);
        guard.quote(address(a), address(b), 0, p, 0);
        vm.expectRevert(RouteJitV2Executor.InvalidAmount.selector);
        guard.quote(address(a), address(b), uint256(type(uint112).max) + 1, p, 0);
        (uint256 out,) = guard.quote(address(a), address(b), type(uint112).max, p, 0);
        require(out > 0 && out < 1000 ether);
    }

    function testInvalidRecipientsCannotSpend() public {
        address[] memory p = paths(false);
        vm.prank(user);
        vm.expectRevert(RouteJitV2Executor.InvalidRecipient.selector);
        guard.swap(address(a), address(b), 10 ether, 1, address(0), block.timestamp, p, 0);
        vm.prank(user);
        vm.expectRevert(RouteJitV2Executor.InvalidRecipient.selector);
        guard.swap(address(a), address(b), 10 ether, 1, address(guard), block.timestamp, p, 0);
        require(a.balanceOf(user) == 100 ether);
    }

    function testWrongNativeValueRejected() public {
        address[] memory p = paths(false);
        vm.prank(user);
        vm.expectRevert(RouteJitV2Executor.InvalidAmount.selector);
        guard.swap{value: 1}(address(a), address(b), 10 ether, 1, recipient, block.timestamp, p, 0);
        vm.prank(user);
        vm.expectRevert(RouteJitV2Executor.InvalidAmount.selector);
        guard.swap{value: 1}(address(0), address(b), 10 ether, 1, recipient, block.timestamp, p, 0);
        require(user.balance == 100 ether && a.balanceOf(user) == 100 ether);
    }

    function testRejectingNativeRecipientRollsBack() public {
        address[] memory p = paths(false);
        JitRejectingRecipient receiver = new JitRejectingRecipient();
        vm.prank(user);
        vm.expectRevert(RouteJitV2Executor.NativeTransferFailed.selector);
        guard.swap(address(a), address(0), 10 ether, 1, address(receiver), block.timestamp, p, 0);
        require(a.balanceOf(user) == 100 ether && a.allowance(user, address(guard)) == 10 ether);
    }

    function testSameNormalizedTokenRejected() public {
        address[] memory p = paths(false);
        vm.expectRevert(RouteJitV2Executor.InvalidRoute.selector);
        guard.quote(address(0), address(wrapped), 1 ether, p, 0);
    }

    function testUnauthorizedPathCannotRescueStaleMinimum() public {
        address[] memory p = paths(false);
        (uint256 original,) = guard.quote(address(a), address(b), 10 ether, p, 0);
        a.mint(address(direct), 1000 ether);
        direct.sync();
        vm.expectRevert(RouteJitV2Executor.SlippageExceeded.selector);
        swap(p, original * 98 / 100, 0);
        require(a.balanceOf(user) == 100 ether && a.balanceOf(address(first)) == 1000 ether);
    }

    function testGasStaticSinglePath() public {
        swap(paths(false), 1, 0);
    }

    function testGasAdaptiveTwoPathsUnchanged() public {
        swap(paths(true), 1, 0);
    }

    function testGasStaticAfterReserveChange() public {
        a.mint(address(direct), 1000 ether);
        direct.sync();
        swap(paths(false), 1, 0);
    }

    function testGasAdaptiveAfterReserveChange() public {
        a.mint(address(direct), 1000 ether);
        direct.sync();
        swap(paths(true), 1, 0);
    }
}
