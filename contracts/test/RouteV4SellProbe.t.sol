// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteV4SellProbe} from "../experimental/RouteV4SellProbe.sol";
import {Token, TaxToken, Vm, RejectNative} from "./Route.t.sol";
import {MockManager} from "./V4Execution.t.sol";

interface ProbeVm is Vm {
    function etch(address target, bytes calldata code) external;
}

contract ProbeHook {}

contract ProbeReentrantRecipient {
    RouteV4SellProbe immutable probe;
    bool public blocked;

    constructor(RouteV4SellProbe p) {
        probe = p;
    }

    receive() external payable {
        try probe.swap(1, 1, address(this), block.timestamp) {
            revert("reentered");
        } catch (bytes memory reason) {
            require(bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")));
            blocked = true;
        }
    }
}

contract RouteV4SellProbeTest {
    ProbeVm constant vm = ProbeVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token token;
    MockManager manager;
    ProbeHook hook;
    RouteV4SellProbe probe;
    address payer = address(0xBEEF);
    address recipient = address(0xCAFE);

    function key(address t) internal view returns (bytes32) {
        return keccak256(abi.encode(address(0), t, uint24(0x800000), int24(1), address(hook)));
    }

    function setUp() public {
        token = new Token("USD");
        manager = new MockManager();
        hook = new ProbeHook();
        probe = new RouteV4SellProbe(
            address(manager), address(token), address(hook), key(address(token))
        );
        token.mint(payer, 100 ether);
        vm.deal(address(manager), 100 ether);
        vm.prank(payer);
        token.approve(address(probe), 100 ether);
    }

    function execute(uint256 amount, uint256 minimum, address to) internal returns (uint256) {
        vm.prank(payer);
        return probe.swap(amount, minimum, to, block.timestamp);
    }

    function testExactInputAndNativeOutput() public {
        require(execute(1 ether, 2 ether, recipient) == 2 ether);
        require(token.balanceOf(payer) == 99 ether && recipient.balance == 2 ether);
        require(token.balanceOf(address(manager)) == 1 ether);
        require(token.balanceOf(address(probe)) == 0 && address(probe).balance == 0);
        require(token.allowance(address(probe), address(manager)) == 0);
        require(token.allowance(payer, address(probe)) == 99 ether);
    }

    function testFuzzExactAccounting(uint96 seed) public {
        uint256 amount = uint256(seed) % (40 ether) + 1;
        require(execute(amount, amount * 2, recipient) == amount * 2);
        require(token.balanceOf(payer) == 100 ether - amount && recipient.balance == amount * 2);
    }

    function testDonationsPreserved() public {
        token.mint(address(probe), 7);
        vm.deal(address(probe), 8);
        vm.deal(recipient, 9);
        execute(1 ether, 2 ether, recipient);
        require(
            token.balanceOf(address(probe)) == 7 && address(probe).balance == 8
                && recipient.balance == 2 ether + 9
        );
    }

    function testImpossibleMinimumRollsBack() public {
        vm.expectRevert(RouteV4SellProbe.SlippageExceeded.selector);
        execute(1 ether, 3 ether, recipient);
        require(token.balanceOf(payer) == 100 ether && recipient.balance == 0);
    }

    function testExpired() public {
        vm.warp(100);
        vm.prank(payer);
        vm.expectRevert(RouteV4SellProbe.DeadlineExpired.selector);
        probe.swap(1, 1, recipient, 99);
    }

    function testZeroMinimum() public {
        vm.expectRevert(RouteV4SellProbe.InvalidSwap.selector);
        execute(1, 0, recipient);
    }

    function testZeroInput() public {
        vm.expectRevert(RouteV4SellProbe.InvalidSwap.selector);
        execute(0, 1, recipient);
    }

    function testLargeInput() public {
        vm.expectRevert(RouteV4SellProbe.InvalidSwap.selector);
        execute(1 << 127, 1, recipient);
    }

    function testZeroRecipient() public {
        vm.expectRevert(RouteV4SellProbe.InvalidSwap.selector);
        execute(1, 1, address(0));
    }

    function testSelfRecipient() public {
        vm.expectRevert(RouteV4SellProbe.InvalidSwap.selector);
        execute(1, 1, address(probe));
    }

    function testManagerRecipient() public {
        vm.expectRevert(RouteV4SellProbe.InvalidSwap.selector);
        execute(1, 1, address(manager));
    }

    function testPartialFill() public {
        manager.behavior(true, false, false);
        vm.expectRevert(RouteV4SellProbe.InvalidSwap.selector);
        execute(1 ether, 1, recipient);
    }

    function testWrongCallbackCaller() public {
        vm.expectRevert(RouteV4SellProbe.UnauthorizedCallback.selector);
        probe.unlockCallback("");
    }

    function testInactiveCallback() public {
        vm.prank(address(manager));
        vm.expectRevert(RouteV4SellProbe.UnauthorizedCallback.selector);
        probe.unlockCallback("");
    }

    function testMutatedCallback() public {
        manager.behavior(false, true, false);
        vm.expectRevert(RouteV4SellProbe.UnauthorizedCallback.selector);
        execute(1, 1, recipient);
    }

    function testRepeatedCallback() public {
        manager.behavior(false, false, true);
        vm.expectRevert(RouteV4SellProbe.UnauthorizedCallback.selector);
        execute(1, 1, recipient);
    }

    function testTaxedPaymentRejected() public {
        TaxToken taxed = new TaxToken();
        taxed.mint(payer, 1 ether);
        RouteV4SellProbe p = new RouteV4SellProbe(
            address(manager), address(taxed), address(hook), key(address(taxed))
        );
        vm.prank(payer);
        taxed.approve(address(p), 1 ether);
        vm.prank(payer);
        vm.expectRevert(RouteV4SellProbe.UnsupportedToken.selector);
        p.swap(1 ether, 1, recipient, block.timestamp);
    }

    function testRejectingRecipientRollsBack() public {
        RejectNative target = new RejectNative();
        vm.expectRevert(RouteV4SellProbe.InvalidSwap.selector);
        execute(1 ether, 1, address(target));
        require(token.balanceOf(payer) == 100 ether);
    }

    function testReentrancyRejected() public {
        ProbeReentrantRecipient target = new ProbeReentrantRecipient(probe);
        execute(1 ether, 1, address(target));
        require(target.blocked());
    }

    function testHookCodeChangeRejected() public {
        vm.etch(address(hook), hex"00");
        vm.expectRevert(RouteV4SellProbe.InvalidSwap.selector);
        execute(1, 1, recipient);
    }

    function testManagerCodeChangeRejected() public {
        vm.etch(address(manager), hex"00");
        vm.expectRevert(RouteV4SellProbe.InvalidSwap.selector);
        execute(1, 1, recipient);
    }

    function testWrongPoolHashRejected() public {
        vm.expectRevert(RouteV4SellProbe.InvalidSwap.selector);
        new RouteV4SellProbe(address(manager), address(token), address(hook), bytes32(0));
    }
}
