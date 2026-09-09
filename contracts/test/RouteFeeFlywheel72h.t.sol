// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteFeeFlywheel72h, IFlywheelExecutor} from "../experimental/RouteFeeFlywheel72h.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface FlyVm {
    function deal(address, uint256) external;
    function prank(address) external;
    function warp(uint256) external;
    function expectRevert(bytes4) external;
}
contract FlyToken is ERC20 {
    constructor() ERC20("ROUTE fixture", "R") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
contract FlySafe { receive() external payable {} }
contract FlyEscrow {
    mapping(address => uint256) public owed;
    function credit(address to, uint256 amount) external { owed[to] += amount; }
    function claim() external {
        _claim(owed[msg.sender]);
    }
    function claim(uint256 amount) external { _claim(amount); }
    function _claim(uint256 amount) private {
        owed[msg.sender] -= amount;
        (bool ok,) = payable(msg.sender).call{value: amount}(""); require(ok);
    }
    function claimToken(address) external {}
}
contract FlyFactory {
    address public recipient;
    function transferCreatorFeeRecipient(address, address r) external { recipient = r; }
}
contract FlyExecutor is IFlywheelExecutor {
    uint256 public output = 100 ether;
    address public redirect;
    bool public reenter;
    function configure(uint256 out, address destination, bool reentry) external {
        output = out; redirect = destination; reenter = reentry;
    }
    function swap(address input, address token, uint256 amount, uint256, address recipient, uint256,
        Branch[] calldata branches) external payable returns (uint256) {
        require(input == address(0) && amount == msg.value);
        if (reenter) {
            (bool ok,) = msg.sender.call(abi.encodeCall(RouteFeeFlywheel72h.execute, (0, 1 ether, 1, block.timestamp, branches)));
            require(!ok, "reentry allowed");
        }
        FlyToken(token).mint(redirect == address(0) ? recipient : redirect, output);
        return type(uint256).max; // receipt balance must override dishonest return value
    }
}
contract RouteFeeFlywheel72hTest {
    FlyVm constant vm = FlyVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    FlySafe safe; FlyToken token; FlyEscrow escrow; FlyFactory factory; FlyExecutor executor;
    RouteFeeFlywheel72h wheel;
    address constant OPERATOR = address(0xB0B);
    function setUp() public {
        vm.warp(1000);
        safe = new FlySafe(); token = new FlyToken(); escrow = new FlyEscrow();
        factory = new FlyFactory(); executor = new FlyExecutor();
        wheel = new RouteFeeFlywheel72h(address(safe), OPERATOR, address(token), address(escrow), address(factory), address(executor));
        vm.deal(address(escrow), 1000 ether);
    }
    function terms() private view returns (RouteFeeFlywheel72h.Policy memory) {
        return RouteFeeFlywheel72h.Policy(2, 10 ether, 20 ether, 100 ether, 60, block.timestamp + 3600);
    }
    function activate() private { vm.prank(address(safe)); wheel.setPolicy(terms()); }
    function run(uint256 seq, uint256 amount, uint256 min) private {
        IFlywheelExecutor.Branch[] memory branches = new IFlywheelExecutor.Branch[](0);
        vm.prank(OPERATOR); wheel.execute(seq, amount, min, block.timestamp, branches);
    }
    function testStartsPausedAndDeployerCannotActivate() public {
        require(wheel.paused());
        vm.expectRevert(RouteFeeFlywheel72h.Unauthorized.selector); wheel.setPolicy(terms());
    }
    function testAtomicSplitAndReceipt() public {
        activate(); escrow.credit(address(wheel), 1 ether);
        run(0, 1 ether, 65 ether);
        require(address(safe).balance == 0.35 ether && address(executor).balance == 0.65 ether);
        require(token.balanceOf(address(safe)) == 100 ether && address(wheel).balance == 0);
        require(wheel.sequence() == 1 && escrow.owed(address(wheel)) == 0);
    }
    function testFuzzSplit(uint96 raw) public {
        uint256 amount = uint256(raw) % (10 ether - 2) + 2;
        activate(); escrow.credit(address(wheel), amount);
        executor.configure(2000 ether, address(0), false);
        run(0, amount, 1000 ether);
        require(address(executor).balance == amount * 6500 / 10000);
        require(address(safe).balance == amount - amount * 6500 / 10000);
    }
    function testLowFloorRejectedBeforeClaim() public {
        activate(); escrow.credit(address(wheel), 1 ether);
        vm.expectRevert(RouteFeeFlywheel72h.SlippageExceeded.selector); run(0, 1 ether, 1);
        require(escrow.owed(address(wheel)) == 1 ether);
    }
    function testRedirectRollsBackEverything() public {
        activate(); escrow.credit(address(wheel), 1 ether);
        executor.configure(100 ether, address(0xBAD), false);
        vm.expectRevert(RouteFeeFlywheel72h.SlippageExceeded.selector); run(0, 1 ether, 65 ether);
        require(escrow.owed(address(wheel)) == 1 ether && wheel.sequence() == 0);
        require(token.balanceOf(address(0xBAD)) == 0 && address(executor).balance == 0);
    }
    function testExtraEscrowCreditsCannotChangeBatch() public {
        activate(); escrow.credit(address(wheel), 2 ether);
        run(0, 1 ether, 65 ether);
        require(escrow.owed(address(wheel)) == 1 ether && wheel.sequence() == 1);
    }
    function testDuplicateAndEarlyExecutionRejected() public {
        activate(); escrow.credit(address(wheel), 1 ether); run(0, 1 ether, 65 ether);
        escrow.credit(address(wheel), 1 ether);
        vm.expectRevert(RouteFeeFlywheel72h.InvalidBatch.selector); run(0, 1 ether, 65 ether);
        vm.expectRevert(RouteFeeFlywheel72h.InvalidBatch.selector); run(1, 1 ether, 65 ether);
        vm.warp(block.timestamp + 60); run(1, 1 ether, 65 ether);
    }
    function testExpiry() public {
        activate(); vm.warp(block.timestamp + 3601);
        vm.expectRevert(RouteFeeFlywheel72h.Inactive.selector); run(0, 1 ether, 65 ether);
    }
    function test72HourPolicyAcceptedAndThenExpires() public {
        require(wheel.MAX_POLICY_DURATION() == 72 hours);
        RouteFeeFlywheel72h.Policy memory p = terms(); p.expiresAt = block.timestamp + 72 hours;
        vm.prank(address(safe)); wheel.setPolicy(p);
        vm.warp(block.timestamp + 48 hours);
        escrow.credit(address(wheel), 1 ether); run(0, 1 ether, 65 ether);
        vm.warp(p.expiresAt + 1);
        vm.expectRevert(RouteFeeFlywheel72h.Inactive.selector); run(1, 1 ether, 65 ether);
    }
    function testPolicyOver72HoursRejected() public {
        RouteFeeFlywheel72h.Policy memory p = terms(); p.expiresAt = block.timestamp + 72 hours + 1;
        vm.expectRevert(RouteFeeFlywheel72h.InvalidConfiguration.selector);
        vm.prank(address(safe)); wheel.setPolicy(p);
    }
    function testBudgetAndBatchLimit() public {
        RouteFeeFlywheel72h.Policy memory p = terms(); p.remainingClaimsBudget = 1 ether;
        vm.prank(address(safe)); wheel.setPolicy(p);
        vm.expectRevert(RouteFeeFlywheel72h.InvalidBatch.selector); run(0, 2 ether, 130 ether);
        vm.expectRevert(RouteFeeFlywheel72h.InvalidBatch.selector); run(0, 11 ether, 715 ether);
    }
    function testOperatorCannotRecoverOrRedirect() public {
        vm.expectRevert(RouteFeeFlywheel72h.Unauthorized.selector); vm.prank(OPERATOR); wheel.recover(address(0), true);
        vm.expectRevert(RouteFeeFlywheel72h.Unauthorized.selector); vm.prank(OPERATOR); wheel.handoverFeesToTreasury();
    }
    function testSafeRecoveryAndExit() public {
        escrow.credit(address(wheel), 1 ether);
        vm.prank(address(safe)); wheel.recover(address(0), true);
        require(address(safe).balance == 1 ether);
        vm.prank(address(safe)); wheel.handoverFeesToTreasury();
        require(factory.recipient() == address(safe));
    }
    function testRecoveryRequiresPauseAndDonationsDoNotChangeSplit() public {
        activate(); vm.deal(address(wheel), 7 ether); escrow.credit(address(wheel), 1 ether);
        run(0, 1 ether, 65 ether); require(address(wheel).balance == 7 ether);
        vm.expectRevert(RouteFeeFlywheel72h.Inactive.selector); vm.prank(address(safe)); wheel.recover(address(0), false);
        vm.prank(address(safe)); wheel.pause();
        vm.prank(address(safe)); wheel.recover(address(0), false);
        require(address(safe).balance == 7.35 ether);
    }
    function testReentryFails() public {
        activate(); escrow.credit(address(wheel), 1 ether); executor.configure(100 ether, address(0), true);
        run(0, 1 ether, 65 ether);
    }
}

