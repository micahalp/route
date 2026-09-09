// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteLeanMetaExecutor} from "../RouteLeanMetaExecutor.sol";
import {Token, TaxToken, Vm} from "./Route.t.sol";
import {MockUpstream} from "./RouteMetaExecutor.t.sol";

contract LeanReentrantRecipient {
    RouteLeanMetaExecutor guard;
    bool public blocked;
    bool public reject;
    constructor(RouteLeanMetaExecutor target, bool shouldReject) { guard = target; reject = shouldReject; }
    receive() external payable {
        require(!reject, "recipient rejected");
        try guard.swap(address(0), address(1), 1, 1, address(this), block.timestamp, hex"12345678") {
            revert("reentry succeeded");
        } catch (bytes memory reason) { require(bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()"))); blocked = true; }
    }
}

contract RouteLeanMetaExecutorTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token a; Token b; MockUpstream upstream; RouteLeanMetaExecutor guard;
    address user = address(0xBEEF);
    address recipient = address(0xCAFE);
    function setUp() public {
        a = new Token("A"); b = new Token("B"); upstream = new MockUpstream();
        guard = new RouteLeanMetaExecutor(address(upstream), MockUpstream.swap.selector);
        a.mint(user, 100 ether); b.mint(address(upstream), 100 ether);
        vm.prank(user); a.approve(address(guard), type(uint256).max);
        vm.deal(user, 100 ether); vm.deal(address(upstream), 100 ether);
    }
    function payload(uint256 amount, uint256 output, address receiver) internal view returns (bytes memory) {
        return abi.encodeCall(MockUpstream.swap, (address(a), address(b), amount, output, receiver));
    }
    function execute(uint256 amount, uint256 minimum, address receiver, bytes memory data) internal returns(uint256) {
        vm.prank(user);
        return guard.swap(address(a), address(b), amount, minimum, receiver, block.timestamp, data);
    }
    function testExactSpendDirectRecipientAndNoAllowance() public {
        require(execute(1 ether, 2 ether, recipient, payload(1 ether, 2 ether, recipient)) == 2 ether);
        require(a.balanceOf(user) == 99 ether && b.balanceOf(recipient) == 2 ether);
        require(a.balanceOf(address(guard)) == 0 && b.balanceOf(address(guard)) == 0);
        require(a.allowance(address(guard), address(upstream)) == 0);
    }
    function testRecipientCanBeSender() public {
        require(execute(1 ether, 2 ether, user, payload(1 ether, 2 ether, user)) == 2 ether);
    }
    function testMinimumIndependentOfProvider() public {
        vm.expectRevert(RouteLeanMetaExecutor.SlippageExceeded.selector);
        execute(1 ether, 2 ether, recipient, payload(1 ether, 1 ether, recipient));
    }
    function testRedirectedOutputRejected() public {
        vm.expectRevert(RouteLeanMetaExecutor.SlippageExceeded.selector);
        execute(1 ether, 2 ether, recipient, payload(1 ether, 2 ether, address(0xBAD)));
    }
    function testOutputSentToGuardRejected() public {
        vm.expectRevert(RouteLeanMetaExecutor.UnsupportedToken.selector);
        execute(1 ether, 2 ether, recipient, payload(1 ether, 2 ether, address(guard)));
    }
    function testPartialInputRejected() public {
        vm.expectRevert(RouteLeanMetaExecutor.UnsupportedToken.selector);
        execute(1 ether, 2 ether, recipient, payload(.5 ether, 2 ether, recipient));
    }
    function testCannotSpendDonatedInput() public {
        a.mint(address(guard), 5 ether);
        vm.expectRevert(RouteLeanMetaExecutor.UpstreamReverted.selector);
        execute(1 ether, 2 ether, recipient, payload(2 ether, 2 ether, recipient));
    }
    function testDonationsNotCountedOrConsumed() public {
        a.mint(address(guard), 7); b.mint(address(guard), 8); b.mint(recipient, 9);
        require(execute(1 ether, 2 ether, recipient, payload(1 ether, 2 ether, recipient)) == 2 ether);
        require(a.balanceOf(address(guard)) == 7 && b.balanceOf(address(guard)) == 8);
        require(b.balanceOf(recipient) == 2 ether + 9);
    }
    function testRecipientDonationCannotSatisfyMinimum() public {
        b.mint(recipient, 5 ether);
        vm.expectRevert(RouteLeanMetaExecutor.SlippageExceeded.selector);
        execute(1 ether, 2 ether, recipient, payload(1 ether, 1 ether, recipient));
    }
    function testWrongSelectorRejected() public {
        vm.expectRevert(RouteLeanMetaExecutor.InvalidSwap.selector);
        execute(1 ether, 2 ether, recipient, hex"12345678");
    }
    function testExpiredRejected() public {
        vm.warp(100); vm.prank(user); vm.expectRevert(RouteLeanMetaExecutor.DeadlineExpired.selector);
        guard.swap(address(a), address(b), 1 ether, 2 ether, recipient, 99, payload(1 ether, 2 ether, recipient));
    }
    function testZeroMinimumRejected() public {
        vm.expectRevert(RouteLeanMetaExecutor.InvalidSwap.selector);
        execute(1 ether, 0, recipient, payload(1 ether, 2 ether, recipient));
    }
    function testSelfRecipientRejected() public {
        vm.expectRevert(RouteLeanMetaExecutor.InvalidSwap.selector);
        execute(1 ether, 2 ether, address(guard), payload(1 ether, 2 ether, address(guard)));
    }
    function testUpstreamRecipientRejected() public {
        vm.expectRevert(RouteLeanMetaExecutor.InvalidSwap.selector);
        execute(1 ether, 2 ether, address(upstream), payload(1 ether, 2 ether, address(upstream)));
    }
    function testZeroRecipientRejected() public {
        vm.expectRevert(RouteLeanMetaExecutor.InvalidSwap.selector);
        execute(1 ether, 2 ether, address(0), payload(1 ether, 2 ether, address(0)));
    }
    function testNativeInput() public {
        bytes memory data = abi.encodeCall(MockUpstream.swap, (address(0), address(b), 1 ether, 2 ether, recipient));
        vm.prank(user);
        require(guard.swap{value: 1 ether}(address(0), address(b), 1 ether, 2 ether, recipient, block.timestamp, data) == 2 ether);
        require(user.balance == 99 ether && b.balanceOf(recipient) == 2 ether);
    }
    function testNativeOutput() public {
        bytes memory data = abi.encodeCall(MockUpstream.swap, (address(a), address(0), 1 ether, 2 ether, user));
        vm.prank(user);
        require(guard.swap(address(a), address(0), 1 ether, 2 ether, user, block.timestamp, data) == 2 ether);
        require(user.balance == 102 ether && a.balanceOf(user) == 99 ether);
    }
    function testWrongNativeValueRejected() public {
        bytes memory data = abi.encodeCall(MockUpstream.swap, (address(0), address(b), 1 ether, 2 ether, recipient));
        vm.prank(user); vm.expectRevert(RouteLeanMetaExecutor.InvalidSwap.selector);
        guard.swap{value: 2 ether}(address(0), address(b), 1 ether, 2 ether, recipient, block.timestamp, data);
    }
    function testTaxedInputRevertsAtomically() public {
        TaxToken taxed = new TaxToken(); taxed.mint(user, 2 ether);
        vm.prank(user); taxed.approve(address(guard), 1 ether);
        bytes memory data = abi.encodeCall(MockUpstream.swap, (address(taxed), address(b), 1 ether, 2 ether, recipient));
        vm.prank(user); vm.expectRevert(RouteLeanMetaExecutor.UnsupportedToken.selector);
        guard.swap(address(taxed), address(b), 1 ether, 2 ether, recipient, block.timestamp, data);
        require(taxed.balanceOf(user) == 2 ether && taxed.balanceOf(address(guard)) == 0);
        require(b.balanceOf(recipient) == 0);
    }
    function testRecipientReentryBlocked() public {
        LeanReentrantRecipient receiver = new LeanReentrantRecipient(guard, false);
        bytes memory data = abi.encodeCall(MockUpstream.swap, (address(a), address(0), 1 ether, 2 ether, address(receiver)));
        vm.prank(user);
        require(guard.swap(address(a), address(0), 1 ether, 2 ether, address(receiver), block.timestamp, data) == 2 ether);
        require(receiver.blocked() && address(receiver).balance == 2 ether);
        require(a.allowance(address(guard), address(upstream)) == 0);
    }
    function testRejectingRecipientRollsBackInputAndApproval() public {
        LeanReentrantRecipient receiver = new LeanReentrantRecipient(guard, true);
        bytes memory data = abi.encodeCall(MockUpstream.swap, (address(a), address(0), 1 ether, 2 ether, address(receiver)));
        vm.prank(user); vm.expectRevert(RouteLeanMetaExecutor.UpstreamReverted.selector);
        guard.swap(address(a), address(0), 1 ether, 2 ether, address(receiver), block.timestamp, data);
        require(a.balanceOf(user) == 100 ether && a.balanceOf(address(upstream)) == 0);
        require(a.allowance(address(guard), address(upstream)) == 0);
    }
    function testEmptyDataRejected() public {
        vm.expectRevert(RouteLeanMetaExecutor.InvalidSwap.selector);
        execute(1 ether, 2 ether, recipient, hex"");
    }
    function testSameTokenRejected() public {
        vm.prank(user); vm.expectRevert(RouteLeanMetaExecutor.InvalidSwap.selector);
        guard.swap(address(a), address(a), 1 ether, 2 ether, recipient, block.timestamp, payload(1 ether, 2 ether, recipient));
    }
    function testInvalidConstructor() public {
        vm.expectRevert(RouteLeanMetaExecutor.InvalidSwap.selector);
        new RouteLeanMetaExecutor(address(0xBAD), MockUpstream.swap.selector);
        vm.expectRevert(RouteLeanMetaExecutor.InvalidSwap.selector);
        new RouteLeanMetaExecutor(address(upstream), bytes4(0));
    }
    function testFuzzExactOutput(uint96 rawInput, uint96 rawOutput) public {
        uint256 amount = uint256(rawInput) % 10 ether + 1;
        uint256 output = uint256(rawOutput) % 10 ether + 1;
        require(execute(amount, output, recipient, payload(amount, output, recipient)) == output);
        require(a.balanceOf(user) == 100 ether - amount && b.balanceOf(recipient) == output);
        require(a.allowance(address(guard), address(upstream)) == 0);
    }
}
