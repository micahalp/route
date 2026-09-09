// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteLeanMetaExecutor} from "../RouteLeanMetaExecutor.sol";
import {RouteMetaExecutor} from "../RouteMetaExecutor.sol";
import {Token, Vm} from "./Route.t.sol";
import {MockUpstream} from "./RouteMetaExecutor.t.sol";

contract ForwardingNativeRecipient {
    address payable immutable destination;

    constructor(address payable target) {
        destination = target;
    }

    receive() external payable {
        (bool sent,) = destination.call{value: msg.value}("");
        require(sent);
    }
}

contract LeanMetaCompatibilityTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token token;
    MockUpstream upstream;
    RouteLeanMetaExecutor lean;
    RouteMetaExecutor current;
    address user = address(0xBEEF);
    address destination = address(0xCAFE);
    ForwardingNativeRecipient recipient;

    function setUp() public {
        token = new Token("Input");
        upstream = new MockUpstream();
        lean = new RouteLeanMetaExecutor(address(upstream), MockUpstream.swap.selector);
        current = new RouteMetaExecutor(address(upstream), MockUpstream.swap.selector);
        recipient = new ForwardingNativeRecipient(payable(destination));
        token.mint(user, 10 ether);
        vm.deal(address(upstream), 10 ether);
        vm.prank(user);
        token.approve(address(lean), 1 ether);
        vm.prank(user);
        token.approve(address(current), 1 ether);
    }

    function testLeanNativeForwardingRejectionIsAtomic() public {
        bytes memory data = abi.encodeCall(
            MockUpstream.swap, (address(token), address(0), 1 ether, 2 ether, address(recipient))
        );
        vm.prank(user);
        vm.expectRevert(RouteLeanMetaExecutor.SlippageExceeded.selector);
        lean.swap(
            address(token), address(0), 1 ether, 2 ether, address(recipient), block.timestamp, data
        );
        require(destination.balance == 0 && address(recipient).balance == 0);
        require(token.balanceOf(user) == 10 ether && token.balanceOf(address(upstream)) == 0);
        require(token.allowance(user, address(lean)) == 1 ether);
        require(token.allowance(address(lean), address(upstream)) == 0);
    }

    function testExistingNativePathPreservesForwardingRecipientAndDonations() public {
        token.mint(address(current), 7);
        vm.deal(address(current), 8);
        bytes memory data = abi.encodeCall(
            MockUpstream.swap, (address(token), address(0), 1 ether, 2 ether, address(current))
        );
        vm.prank(user);
        require(
            current.swap(
                address(token),
                address(0),
                1 ether,
                2 ether,
                address(recipient),
                block.timestamp,
                data
            ) == 2 ether
        );
        require(destination.balance == 2 ether && address(recipient).balance == 0);
        require(token.balanceOf(user) == 9 ether && token.balanceOf(address(current)) == 7);
        require(address(current).balance == 8);
        require(
            token.allowance(user, address(current)) == 0
                && token.allowance(address(current), address(upstream)) == 0
        );
    }

    function testTokenDeliveryToContractRecipientRemainsSupported() public {
        Token output = new Token("Output");
        output.mint(address(upstream), 2 ether);
        bytes memory data = abi.encodeCall(
            MockUpstream.swap,
            (address(token), address(output), 1 ether, 2 ether, address(recipient))
        );
        vm.prank(user);
        require(
            lean.swap(
                address(token),
                address(output),
                1 ether,
                2 ether,
                address(recipient),
                block.timestamp,
                data
            ) == 2 ether
        );
        require(output.balanceOf(address(recipient)) == 2 ether);
        require(
            token.balanceOf(user) == 9 ether
                && token.allowance(address(lean), address(upstream)) == 0
        );
    }
}
