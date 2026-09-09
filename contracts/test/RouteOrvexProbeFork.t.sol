// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteOrvexProbe, IOrvexWrapped} from "../experimental/RouteOrvexProbe.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface OrvexVm {
    function envString(string calldata) external returns (string memory);
    function envUint(string calldata) external returns (uint256);
    function createSelectFork(string calldata, uint256) external returns (uint256);
    function deal(address, uint256) external;
    function prank(address) external;
    function expectRevert(bytes4) external;
    function txGasPrice(uint256) external;
}
contract OrvexForceDonation { constructor(address payable target) payable { selfdestruct(target); } }
contract OrvexRejectRecipient { receive() external payable { revert(); } }
contract OrvexForwardRecipient {
    address payable immutable destination;
    constructor(address payable target) { destination = target; }
    receive() external payable { (bool ok,) = destination.call{value: msg.value}(""); require(ok); }
}
contract OrvexReentryRecipient {
    RouteOrvexProbe immutable probe;
    bool public blocked;
    constructor(RouteOrvexProbe target) { probe = target; }
    receive() external payable {
        (bool ok, bytes memory reason) = address(probe).call(abi.encodeCall(probe.swap,
            (address(0), probe.USDG(), uint256(1), uint256(1), address(this), block.timestamp)));
        require(!ok && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        (ok, reason) = address(probe).call(abi.encodeCall(probe.lockAcquired, (bytes(""))));
        require(!ok && bytes4(reason) == RouteOrvexProbe.CallbackRejected.selector);
        blocked = true;
    }
}

/// @dev Opt-in fixed real-chain fork; not included in the offline unit suite.
contract RouteOrvexProbeForkTest {
    OrvexVm constant vm = OrvexVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    RouteOrvexProbe probe;
    address constant recipient = address(0xBEEF);
    address weth; address usdg;
    receive() external payable {}
    function setUp() public {
        vm.createSelectFork(vm.envString("ROUTE_RPC_URL"), vm.envUint("ORVEX_FORK_BLOCK"));
        require(block.chainid == 4663);
        vm.txGasPrice(vm.envUint("ORVEX_FORK_GAS_PRICE"));
        probe = new RouteOrvexProbe(); weth = probe.WETH(); usdg = probe.USDG();
        vm.deal(address(this), 20 ether);
        // Real WETH deposit and real Orvex swap; no token/pool/code/storage overrides.
        IOrvexWrapped(weth).deposit{value: 2 ether}();
        probe.swap{value: 1 ether}(address(0), usdg, 1 ether, 1, address(this), block.timestamp);
        require(IERC20(usdg).balanceOf(address(this)) > 1000e6);
        IERC20(weth).transfer(address(probe), 17);
        IERC20(usdg).transfer(address(probe), 23);
        new OrvexForceDonation{value: 29}(payable(address(probe)));
    }
    function _donations() private view {
        require(IERC20(weth).balanceOf(address(probe)) == 17);
        require(IERC20(usdg).balanceOf(address(probe)) == 23);
        require(address(probe).balance == 29);
        require(IERC20(weth).allowance(address(probe), probe.VAULT()) == 0);
        require(IERC20(usdg).allowance(address(probe), probe.VAULT()) == 0);
    }
    function _balance(address token, address who) private view returns (uint256) {
        return token == address(0) ? who.balance : IERC20(token).balanceOf(who);
    }
    function _swap(address input, address output, uint256 amount, address to) private {
        if (input != address(0)) IERC20(input).approve(address(probe), amount);
        uint256 beforeInput = _balance(input, address(this));
        uint256 beforeOutput = _balance(output, to);
        uint256 out = probe.swap{value: input == address(0) ? amount : 0}(input, output, amount, 1, to, block.timestamp);
        require(out > 0 && _balance(input, address(this)) + amount == beforeInput);
        require(_balance(output, to) == beforeOutput + out);
        if (input != address(0)) require(IERC20(input).allowance(address(this), address(probe)) == 0);
        _donations();
    }
    function testNativeInputExactBalancesAndDonations() public { _swap(address(0), usdg, 0.01 ether, recipient); }
    function testWrappedInputExactBalancesAndDonations() public { _swap(weth, usdg, 0.01 ether, recipient); }
    function testNativeOutputExactBalancesAndDonations() public { _swap(usdg, address(0), 100e6, recipient); }
    function testWrappedOutputExactBalancesAndDonations() public { _swap(usdg, weth, 100e6, recipient); }
    function testCallerRecipientBothDirections() public { _swap(address(0), usdg, 0.01 ether, address(this)); _swap(usdg, address(0), 100e6, address(this)); }
    function testImpossibleMinimumRollsBack() public {
        IERC20(usdg).approve(address(probe), 100e6);
        uint256 beforeInput = IERC20(usdg).balanceOf(address(this));
        uint256 beforeOutput = recipient.balance;
        vm.expectRevert(RouteOrvexProbe.SlippageExceeded.selector);
        probe.swap(usdg, address(0), 100e6, type(uint128).max, recipient, block.timestamp);
        require(IERC20(usdg).balanceOf(address(this)) == beforeInput && recipient.balance == beforeOutput);
        require(IERC20(usdg).allowance(address(this), address(probe)) == 100e6); _donations();
        _swap(usdg, address(0), 100e6, recipient); // guard/context rolled back too
    }
    function testExpiredDeadline() public {
        vm.expectRevert(RouteOrvexProbe.DeadlineExpired.selector);
        probe.swap{value: 0.01 ether}(address(0), usdg, 0.01 ether, 1, recipient, block.timestamp - 1); _donations();
    }
    function testUnsolicitedAndVaultSpoofCallbacks() public {
        vm.expectRevert(RouteOrvexProbe.CallbackRejected.selector); probe.lockAcquired("");
        vm.prank(probe.VAULT()); vm.expectRevert(RouteOrvexProbe.CallbackRejected.selector); probe.lockAcquired(""); _donations();
    }
    function testRejectingNativeRecipientRollsBack() public {
        address target = address(new OrvexRejectRecipient());
        IERC20(usdg).approve(address(probe), 100e6);
        uint256 beforeInput = IERC20(usdg).balanceOf(address(this));
        vm.expectRevert(RouteOrvexProbe.NativeTransferFailed.selector);
        probe.swap(usdg, address(0), 100e6, 1, target, block.timestamp);
        require(IERC20(usdg).balanceOf(address(this)) == beforeInput); _donations();
    }
    function testForwardingNativeRecipientReceivesExactValue() public {
        address target = address(new OrvexForwardRecipient(payable(recipient)));
        IERC20(usdg).approve(address(probe), 100e6);
        uint256 beforeInput = IERC20(usdg).balanceOf(address(this));
        uint256 beforeOutput = recipient.balance;
        uint256 out = probe.swap(usdg, address(0), 100e6, 1, target, block.timestamp);
        require(IERC20(usdg).balanceOf(address(this)) + 100e6 == beforeInput && recipient.balance == beforeOutput + out);
        require(target.balance == 0); _donations();
    }
    function testNativeRecipientCannotReenterSwapOrCallback() public {
        OrvexReentryRecipient target = new OrvexReentryRecipient(probe);
        _swap(usdg, address(0), 100e6, address(target)); require(target.blocked());
    }
}
