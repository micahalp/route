// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteMetaExecutor} from "../RouteMetaExecutor.sol";
import {Token, Vm} from "./Route.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockUpstream {
    receive() external payable {}

    function swap(address input, address output, uint256 amount, uint256 payout, address recipient)
        external
        payable
    {
        if (input == address(0)) {
            require(msg.value == amount);
        } else {
            require(IERC20(input).transferFrom(msg.sender, address(this), amount));
        }
        if (output == address(0)) {
            (bool ok,) = recipient.call{value: payout}("");
            require(ok);
        } else {
            require(IERC20(output).transfer(recipient, payout));
        }
    }
}

contract RouteMetaExecutorTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token a;
    Token b;
    MockUpstream upstream;
    RouteMetaExecutor guard;
    address user = address(0xBEEF);

    function setUp() public {
        a = new Token("A");
        b = new Token("B");
        upstream = new MockUpstream();
        guard = new RouteMetaExecutor(address(upstream), MockUpstream.swap.selector);
        a.mint(user, 100 ether);
        b.mint(address(upstream), 100 ether);
        vm.prank(user);
        a.approve(address(guard), type(uint256).max);
        vm.deal(user, 100 ether);
        vm.deal(address(upstream), 100 ether);
    }

    function payload(uint256 amount, uint256 output, address recipient)
        internal
        view
        returns (bytes memory)
    {
        return
            abi.encodeCall(MockUpstream.swap, (address(a), address(b), amount, output, recipient));
    }

    function testGuardedSwapAndApprovals() public {
        vm.prank(user);
        require(
            guard.swap(
                address(a),
                address(b),
                1 ether,
                2 ether,
                user,
                block.timestamp,
                payload(1 ether, 2 ether, address(guard))
            ) == 2 ether
        );
        require(a.allowance(address(guard), address(upstream)) == 0);
    }

    function testUpstreamCannotLowerOuterMinimum() public {
        vm.prank(user);
        vm.expectRevert(RouteMetaExecutor.SlippageExceeded.selector);
        guard.swap(
            address(a),
            address(b),
            1 ether,
            2 ether,
            user,
            block.timestamp,
            payload(1 ether, 1 ether, address(guard))
        );
    }

    function testUpstreamCannotRedirectOutput() public {
        vm.prank(user);
        vm.expectRevert(RouteMetaExecutor.SlippageExceeded.selector);
        guard.swap(
            address(a),
            address(b),
            1 ether,
            2 ether,
            user,
            block.timestamp,
            payload(1 ether, 2 ether, address(0xBAD))
        );
    }

    function testUpstreamCannotOverspend() public {
        a.mint(address(guard), 10 ether);
        vm.prank(user);
        vm.expectRevert(RouteMetaExecutor.UpstreamReverted.selector);
        guard.swap(
            address(a),
            address(b),
            1 ether,
            2 ether,
            user,
            block.timestamp,
            payload(2 ether, 2 ether, address(guard))
        );
    }

    function testPartialInputRejected() public {
        vm.prank(user);
        vm.expectRevert(RouteMetaExecutor.UnsupportedToken.selector);
        guard.swap(
            address(a),
            address(b),
            1 ether,
            2 ether,
            user,
            block.timestamp,
            payload(0.5 ether, 2 ether, address(guard))
        );
    }

    function testWrongSelectorRejected() public {
        vm.prank(user);
        vm.expectRevert(RouteMetaExecutor.InvalidSwap.selector);
        guard.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, hex"12345678");
    }

    function testDeadlineEnforcedOutsideUpstream() public {
        vm.warp(100);
        vm.prank(user);
        vm.expectRevert(RouteMetaExecutor.DeadlineExpired.selector);
        guard.swap(
            address(a), address(b), 1 ether, 1, user, 99, payload(1 ether, 2 ether, address(guard))
        );
    }

    function testDonationsStayUntouched() public {
        a.mint(address(guard), 7);
        b.mint(address(guard), 8);
        vm.prank(user);
        guard.swap(
            address(a),
            address(b),
            1 ether,
            1,
            user,
            block.timestamp,
            payload(1 ether, 2 ether, address(guard))
        );
        require(a.balanceOf(address(guard)) == 7 && b.balanceOf(address(guard)) == 8);
    }

    function testNativeInput() public {
        bytes memory data = abi.encodeCall(
            MockUpstream.swap, (address(0), address(b), 1 ether, 2 ether, address(guard))
        );
        vm.prank(user);
        require(
            guard.swap{value: 1 ether}(
                address(0), address(b), 1 ether, 2 ether, user, block.timestamp, data
            ) == 2 ether
        );
    }

    function testNativeOutput() public {
        bytes memory data = abi.encodeCall(
            MockUpstream.swap, (address(a), address(0), 1 ether, 2 ether, address(guard))
        );
        uint256 beforeBalance = user.balance;
        vm.prank(user);
        guard.swap(address(a), address(0), 1 ether, 2 ether, user, block.timestamp, data);
        require(user.balance == beforeBalance + 2 ether);
    }
}
