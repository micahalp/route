// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {V3Adapter, IV3Router} from "../adapters/V3Adapter.sol";
import {Token, Wrapped, Vm} from "./Route.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoutePoolExecutor} from "../RoutePoolExecutor.sol";
import {RamsesMock, RamsesFactoryMock} from "./RouteRamsesExecutor.t.sol";

// Models the upstream PeripheryPayments.pay branch and permissionless refund.
contract NativeFirstV3 {
    Wrapped public immutable WETH9;
    bool public partialFill;

    constructor(Wrapped w) {
        WETH9 = w;
    }

    function setPartial() external {
        partialFill = true;
    }

    function refundETH() external payable {
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok);
    }

    function sweepToken(address token, address recipient) external {
        IERC20(token).transfer(recipient, IERC20(token).balanceOf(address(this)));
    }

    function exactInputSingle(IV3Router.Params calldata p) external payable returns (uint256) {
        uint256 payment = partialFill ? p.amountIn / 2 : p.amountIn;
        if (p.tokenIn == address(WETH9) && address(this).balance >= payment) {
            WETH9.deposit{value: payment}();
            WETH9.transfer(address(0xB001), payment);
        } else {
            IERC20(p.tokenIn).transferFrom(msg.sender, address(0xB001), payment);
        }
        uint256 out = p.amountIn * 2;
        require(out >= p.amountOutMinimum);
        IERC20(p.tokenOut).transfer(p.recipient, out);
        return out;
    }
}

contract SherlockIssue11Test {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token input;
    Token output;
    address recipient = address(0xCAFE);

    function setUp() public {
        input = new Token("IN");
        output = new Token("OUT");
        input.mint(address(this), 1 ether);
    }

    function testIssue11PoolFallbackDoesNotBypassNormalization() public {
        Wrapped weth = new Wrapped();
        NativeFirstV3 dex = new NativeFirstV3(weth);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        V3Adapter adapter = new V3Adapter("V3", address(dex), address(dex), fees);
        RamsesMock ram = new RamsesMock(address(weth));
        RamsesFactoryMock factory = new RamsesFactoryMock(address(ram));
        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter);
        adapters[1] = address(ram);
        RoutePoolExecutor pool = new RoutePoolExecutor(
            address(weth),
            adapters,
            address(0),
            address(adapter),
            address(0),
            address(ram),
            address(factory)
        );
        weth.mint(address(this), 1 ether);
        weth.approve(address(pool), 1 ether);
        weth.mint(address(pool), 7);
        output.mint(address(pool), 8);
        output.mint(address(dex), 2 ether);
        vm.deal(address(dex), 1 ether);
        RoutePoolExecutor.Branch[] memory branches = new RoutePoolExecutor.Branch[](1);
        branches[0].amountIn = 1 ether;
        branches[0].legs = new RoutePoolExecutor.Leg[](1);
        branches[0].legs[0] =
            RoutePoolExecutor.Leg(address(adapter), address(output), 500, 0, address(0), false);
        require(
            pool.swap(
                address(weth),
                address(output),
                1 ether,
                2 ether,
                recipient,
                block.timestamp,
                branches
            ) == 2 ether
        );
        require(weth.balanceOf(address(pool)) == 7 && output.balanceOf(address(pool)) == 8);
        require(weth.balanceOf(address(this)) == 0 && output.balanceOf(recipient) == 2 ether);
        require(weth.allowance(address(pool), address(adapter)) == 0);
        require(weth.allowance(address(pool), address(dex)) == 0);
        require(weth.balanceOf(address(dex)) == 1 ether && address(dex).balance == 0);
    }

    function testIssue11ResidualNativeCannotBlockWethSwap() public {
        _wethSwap(1 ether, false);
    }

    function testIssue11NonWethInputLeavesNativeUntouched() public {
        Wrapped weth = new Wrapped();
        NativeFirstV3 dex = new NativeFirstV3(weth);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        V3Adapter adapter = new V3Adapter("V3", address(dex), address(dex), fees);
        input.approve(address(adapter), 1 ether);
        output.mint(address(dex), 2 ether);
        vm.deal(address(dex), 1 ether);
        require(adapter.swap(address(input), address(output), 1 ether, 2 ether, 500) == 2 ether);
        require(address(dex).balance == 1 ether && weth.balanceOf(address(dex)) == 0);
        require(input.allowance(address(adapter), address(dex)) == 0);
    }

    function testFuzzIssue11ResidualNative(uint96 raw) public {
        _wethSwap(uint256(raw) % 10 ether, false);
    }

    function testIssue11PartialFillStillRejected() public {
        _wethSwap(1 ether, true);
    }

    function _wethSwap(uint256 residual, bool partialFill) private {
        Wrapped weth = new Wrapped();
        NativeFirstV3 router = new NativeFirstV3(weth);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        V3Adapter adapter = new V3Adapter("V3", address(router), address(router), fees);
        weth.mint(address(this), 1 ether);
        weth.approve(address(adapter), 1 ether);
        weth.mint(address(adapter), 7);
        output.mint(address(adapter), 8);
        output.mint(address(router), 2 ether);
        vm.deal(address(adapter), 9);
        vm.deal(address(router), residual);
        if (partialFill) {
            router.setPartial();
        }
        (bool ok, bytes memory result) = address(adapter)
            .call(
                abi.encodeCall(
                    adapter.swap, (address(weth), address(output), 1 ether, 2 ether, 500)
                )
            );
        if (partialFill) {
            require(!ok && weth.balanceOf(address(this)) == 1 ether);
            require(address(router).balance == residual);
        } else {
            require(ok, "ISSUE11: residual ETH blocked swap");
            require(abi.decode(result, (uint256)) == 2 ether);
            require(
                weth.balanceOf(address(this)) == 0 && output.balanceOf(address(this)) == 2 ether
            );
            require(weth.balanceOf(address(router)) == residual);
            require(address(router).balance == 0);
            router.sweepToken(address(weth), recipient);
            require(weth.balanceOf(recipient) == residual);
        }
        require(weth.balanceOf(address(adapter)) == 7 && output.balanceOf(address(adapter)) == 8);
        require(
            address(adapter).balance == 9 && weth.allowance(address(adapter), address(router)) == 0
        );
    }
}
