// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteV3CallbackProbe} from "../experimental/RouteV3CallbackProbe.sol";
import {Token, TaxToken, Wrapped, Vm, RejectNative} from "./Route.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract V3CallbackPoolFixture {
    address public immutable token0;
    address public immutable token1;
    uint256 public mode;
    bytes public reentryData;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function setReentry(bytes calldata data) external {
        reentryData = data;
    }

    function swap(address recipient, bool zeroForOne, int256 amount, uint160, bytes calldata)
        external
        returns (int256, int256)
    {
        RouteV3CallbackProbe target = RouteV3CallbackProbe(payable(msg.sender));
        if (mode == 1) {
            return (0, 0);
        }
        if (mode == 8) {
            bytes memory payload = reentryData.length == 0
                ? abi.encodeCall(
                    target.swap, (token0, token1, 500, 1, 1, recipient, block.timestamp)
                )
                : reentryData;
            (bool ok, bytes memory reason) = msg.sender.call(payload);
            require(!ok && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        }
        int256 owed = mode == 2 ? amount + 1 : mode == 3 ? amount - 1 : amount;
        int256 sent = mode == 5 ? amount : -amount * 2;
        (int256 d0, int256 d1) = zeroForOne ? (owed, sent) : (sent, owed);
        if (mode == 6) {
            (d0, d1) = (d1, d0);
        }
        if (mode != 9) {
            IERC20(zeroForOne ? token1 : token0).transfer(recipient, uint256(amount) * 2);
        }
        target.uniswapV3SwapCallback(d0, d1, mode == 7 ? bytes("invalid") : bytes(""));
        if (mode == 4) {
            target.uniswapV3SwapCallback(d0, d1, "");
        }
        // Deliberately dishonest return values must not determine user output.
        return (type(int256).max, type(int256).max);
    }
}

contract V3CallbackFactoryFixture {
    mapping(bytes32 => address) private pools;

    function add(address a, address b) external returns (V3CallbackPoolFixture p) {
        p = new V3CallbackPoolFixture(a, b);
        pools[keccak256(abi.encode(a, b, uint24(500)))] = address(p);
        pools[keccak256(abi.encode(b, a, uint24(500)))] = address(p);
        Token(a).mint(address(p), 1e35);
        Token(b).mint(address(p), 1e35);
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(a, b, fee))];
    }
}

contract CallbackReentryToken is Token {
    address target;
    bytes payload;
    bool public blocked;
    constructor() Token("REENTER") {}

    function configure(address t, bytes memory p) external {
        target = t;
        payload = p;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0) && target != address(0)) {
            (bool ok, bytes memory reason) = target.call(payload);
            require(!ok && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")));
            blocked = true;
        }
    }
}

contract V3CallbackProbeTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token a;
    Token b;
    Wrapped wrapped;
    V3CallbackFactoryFixture factory;
    V3CallbackPoolFixture pool;
    RouteV3CallbackProbe probe;
    address user = address(0xBEEF);
    address recipient = address(0xCAFE);

    function setUp() public {
        a = new Token("A");
        b = new Token("B");
        wrapped = new Wrapped();
        factory = new V3CallbackFactoryFixture();
        pool = factory.add(address(a), address(b));
        factory.add(address(wrapped), address(b));
        factory.add(address(a), address(wrapped));
        probe = new RouteV3CallbackProbe(address(factory), address(wrapped));
        a.mint(user, 1e32);
        b.mint(user, 1e32);
        vm.deal(user, 100 ether);
        vm.deal(address(wrapped), 100 ether);
        vm.prank(user);
        a.approve(address(probe), type(uint256).max);
        vm.prank(user);
        b.approve(address(probe), type(uint256).max);
    }

    function run(uint256 amount, uint256 minOut) private returns (uint256) {
        vm.prank(user);
        return probe.swap(address(a), address(b), 500, amount, minOut, recipient, block.timestamp);
    }

    function testExactInputOutputAndNoPoolApproval() public {
        uint256 beforeInput = a.balanceOf(user);
        require(run(1 ether, 2 ether) == 2 ether);
        require(a.balanceOf(user) == beforeInput - 1 ether && b.balanceOf(recipient) == 2 ether);
        require(a.balanceOf(address(probe)) == 0 && b.balanceOf(address(probe)) == 0);
        require(a.allowance(address(probe), address(pool)) == 0);
    }

    function testReverseDirection() public {
        vm.prank(user);
        require(
            probe.swap(address(b), address(a), 500, 1 ether, 2 ether, recipient, block.timestamp)
                == 2 ether
        );
    }

    function testDonationsPreservedAndSequentialContextCleared() public {
        a.mint(address(probe), 77);
        b.mint(address(probe), 88);
        require(run(1 ether, 2 ether) == 2 ether);
        require(run(2 ether, 4 ether) == 4 ether);
        require(a.balanceOf(address(probe)) == 77 && b.balanceOf(address(probe)) == 88);
        vm.expectRevert(RouteV3CallbackProbe.CallbackRejected.selector);
        probe.uniswapV3SwapCallback(1, -2, "");
    }

    function testNativeInput() public {
        vm.prank(user);
        require(
            probe.swap{value: 1 ether}(
                address(0), address(b), 500, 1 ether, 2 ether, recipient, block.timestamp
            ) == 2 ether
        );
    }

    function testNativeOutput() public {
        vm.prank(user);
        require(
            probe.swap(address(a), address(0), 500, 1 ether, 2 ether, recipient, block.timestamp)
                == 2 ether
        );
        require(recipient.balance == 2 ether);
    }

    function testRejectingNativeRecipient() public {
        RejectNative no = new RejectNative();
        vm.prank(user);
        vm.expectRevert(RouteV3CallbackProbe.NativeTransferFailed.selector);
        probe.swap(address(a), address(0), 500, 1 ether, 2 ether, address(no), block.timestamp);
    }

    function testForgedCallback() public {
        vm.prank(address(pool));
        vm.expectRevert(RouteV3CallbackProbe.CallbackRejected.selector);
        probe.uniswapV3SwapCallback(1, -2, "");
    }

    function testMissingCallback() public {
        pool.setMode(1);
        vm.expectRevert(RouteV3CallbackProbe.CallbackRejected.selector);
        run(1 ether, 1);
    }

    function testOverpayment() public {
        pool.setMode(2);
        vm.expectRevert(RouteV3CallbackProbe.CallbackRejected.selector);
        run(1 ether, 1);
    }

    function testPartialFill() public {
        pool.setMode(3);
        vm.expectRevert(RouteV3CallbackProbe.CallbackRejected.selector);
        run(1 ether, 1);
    }

    function testRepeatedCallback() public {
        pool.setMode(4);
        vm.expectRevert(RouteV3CallbackProbe.CallbackRejected.selector);
        run(1 ether, 1);
    }

    function testBothPositiveDeltas() public {
        pool.setMode(5);
        vm.expectRevert(RouteV3CallbackProbe.CallbackRejected.selector);
        run(1 ether, 1);
    }

    function testWrongPaymentDirection() public {
        pool.setMode(6);
        vm.expectRevert(RouteV3CallbackProbe.CallbackRejected.selector);
        run(1 ether, 1);
    }

    function testUnexpectedCallbackData() public {
        pool.setMode(7);
        vm.expectRevert(RouteV3CallbackProbe.CallbackRejected.selector);
        run(1 ether, 1);
    }

    function testPoolReentrancyBlocked() public {
        pool.setMode(8);
        require(run(1 ether, 1) == 2 ether);
    }

    function testNoOutputRejected() public {
        pool.setMode(9);
        vm.expectRevert(RouteV3CallbackProbe.UnsupportedToken.selector);
        run(1 ether, 1);
    }

    function testMinimumRevertsAtomically() public {
        uint256 beforeInput = a.balanceOf(user);
        vm.expectRevert(RouteV3CallbackProbe.SlippageExceeded.selector);
        run(1 ether, 3 ether);
        require(a.balanceOf(user) == beforeInput);
    }

    function testZeroMinimumRejected() public {
        vm.expectRevert(RouteV3CallbackProbe.InvalidAmount.selector);
        run(1 ether, 0);
    }

    function testExpired() public {
        vm.warp(100);
        vm.prank(user);
        vm.expectRevert(RouteV3CallbackProbe.Expired.selector);
        probe.swap(address(a), address(b), 500, 1, 1, recipient, 99);
    }

    function testUnknownFeePoolRejected() public {
        vm.prank(user);
        vm.expectRevert(RouteV3CallbackProbe.InvalidRoute.selector);
        probe.swap(address(a), address(b), 3000, 1, 1, recipient, block.timestamp);
    }

    function testTaxedInputRejected() public {
        TaxToken t = new TaxToken();
        factory.add(address(t), address(b));
        t.mint(user, 1 ether);
        vm.prank(user);
        t.approve(address(probe), 1 ether);
        vm.prank(user);
        vm.expectRevert(RouteV3CallbackProbe.UnsupportedToken.selector);
        probe.swap(address(t), address(b), 500, 1 ether, 1, recipient, block.timestamp);
    }

    function testTaxedOutputRejected() public {
        TaxToken t = new TaxToken();
        factory.add(address(a), address(t));
        vm.prank(user);
        vm.expectRevert(RouteV3CallbackProbe.UnsupportedToken.selector);
        probe.swap(address(a), address(t), 500, 1 ether, 1, recipient, block.timestamp);
    }

    function testUnexpectedNativeValue() public {
        vm.prank(user);
        vm.expectRevert(RouteV3CallbackProbe.InvalidAmount.selector);
        probe.swap{value: 1}(address(a), address(b), 500, 1, 1, recipient, block.timestamp);
    }

    function testSameNormalizedTokenRejected() public {
        vm.prank(user);
        vm.expectRevert(RouteV3CallbackProbe.InvalidRoute.selector);
        probe.swap(address(wrapped), address(0), 500, 1, 1, recipient, block.timestamp);
    }

    function testInvalidRecipient() public {
        vm.prank(user);
        vm.expectRevert(RouteV3CallbackProbe.InvalidRoute.selector);
        probe.swap(address(a), address(b), 500, 1, 1, address(probe), block.timestamp);
    }

    function testTokenReentrancyBlocked() public {
        CallbackReentryToken t = new CallbackReentryToken();
        factory.add(address(t), address(b));
        t.mint(user, 1 ether);
        vm.prank(user);
        t.approve(address(probe), 1 ether);
        t.configure(
            address(probe),
            abi.encodeCall(
                probe.swap, (address(t), address(b), 500, 1, 1, recipient, block.timestamp)
            )
        );
        vm.prank(user);
        require(
            probe.swap(address(t), address(b), 500, 1 ether, 1, recipient, block.timestamp)
                == 2 ether
        );
        require(t.blocked());
    }

    function testFuzzExactInput(uint96 raw) public {
        uint256 amount = uint256(raw) + 1;
        require(run(amount, amount * 2) == amount * 2);
    }
}
