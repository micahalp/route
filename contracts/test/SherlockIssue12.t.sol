// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteLeanMetaExecutor} from "../RouteLeanMetaExecutor.sol";
import {Token, Vm} from "./Route.t.sol";

// A pre-existing entitlement, not freshly donated swap proceeds.
contract OwedRewards {
    Token immutable token;
    mapping(address => uint256) public owed;

    constructor(Token t) {
        token = t;
    }

    function fund(address recipient, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        owed[recipient] += amount;
    }

    function claim(address recipient) external {
        uint256 amount = owed[recipient];
        owed[recipient] = 0;
        token.transfer(recipient, amount);
    }
}

contract ClaimingUpstream {
    address constant thief = address(0xBAD);

    function swap(
        Token input,
        Token output,
        OwedRewards rewards,
        address recipient,
        address outputReceiver,
        uint256 genuineOutput
    ) external {
        input.transferFrom(msg.sender, thief, 1 ether);
        if (genuineOutput != 0) {
            output.transfer(outputReceiver, genuineOutput);
        }
        rewards.claim(recipient);
    }
}

contract SherlockIssue12Test {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token input;
    Token output;
    OwedRewards rewards;
    ClaimingUpstream upstream;
    RouteLeanMetaExecutor guard;
    address recipient = address(0xCAFE);

    function setUp() public {
        input = new Token("IN");
        output = new Token("OUT");
        rewards = new OwedRewards(output);
        upstream = new ClaimingUpstream();
        guard = new RouteLeanMetaExecutor(address(upstream), ClaimingUpstream.swap.selector);
        input.mint(address(this), 1 ether);
        input.approve(address(guard), 1 ether);
        output.mint(address(this), 2 ether);
        output.approve(address(rewards), 2 ether);
        rewards.fund(recipient, 2 ether);
        output.mint(address(upstream), 2 ether);
    }

    function testIssue12ClaimCannotReplaceSwapOutput() public {
        bytes memory data =
            abi.encodeCall(upstream.swap, (input, output, rewards, recipient, address(guard), 0));
        (bool ok,) = address(guard)
            .call(
                abi.encodeCall(
                    guard.swap,
                    (
                        address(input),
                        address(output),
                        1 ether,
                        2 ether,
                        recipient,
                        block.timestamp,
                        data
                    )
                )
            );
        require(!ok, "ISSUE12: unrelated entitlement passed minOut");
        require(rewards.owed(recipient) == 2 ether && output.balanceOf(recipient) == 0);
        require(input.balanceOf(address(this)) == 1 ether && input.balanceOf(address(0xBAD)) == 0);
    }

    function testIssue12PartialOutputPlusClaimCannotPass() public {
        bytes memory data =
            abi.encodeCall(upstream.swap, (input, output, rewards, recipient, recipient, 1 ether));
        (bool ok,) = address(guard)
            .call(
                abi.encodeCall(
                    guard.swap,
                    (
                        address(input),
                        address(output),
                        1 ether,
                        2 ether,
                        recipient,
                        block.timestamp,
                        data
                    )
                )
            );
        require(!ok, "ISSUE12: partialFill output plus entitlement passed");
        require(rewards.owed(recipient) == 2 ether);
    }

    function testIssue12GenuineOutputExcludesConcurrentClaim() public {
        bytes memory data = abi.encodeCall(
            upstream.swap, (input, output, rewards, recipient, address(guard), 2 ether)
        );
        uint256 amount = guard.swap(
            address(input), address(output), 1 ether, 2 ether, recipient, block.timestamp, data
        );
        require(amount == 2 ether && output.balanceOf(recipient) == 4 ether);
        require(output.balanceOf(address(guard)) == 0);
    }

    function testFuzzIssue12ShortfallCannotBeCoveredByClaim(uint96 raw) public {
        uint256 genuine = uint256(raw) % 2 ether;
        bytes memory data = abi.encodeCall(
            upstream.swap, (input, output, rewards, recipient, address(guard), genuine)
        );
        vm.expectRevert(RouteLeanMetaExecutor.SlippageExceeded.selector);
        guard.swap(
            address(input), address(output), 1 ether, 2 ether, recipient, block.timestamp, data
        );
        require(rewards.owed(recipient) == 2 ether && input.balanceOf(address(this)) == 1 ether);
    }
}
