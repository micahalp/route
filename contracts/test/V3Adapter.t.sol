// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Token} from "./Route.t.sol";
import {V3Adapter, IV3Quoter, IV3Router} from "../adapters/V3Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockV3 {
    bool public partialFill;
    function setPartial() external { partialFill = true; }
    function quoteExactInputSingle(IV3Quoter.Params calldata p) external pure returns (uint256, uint160, uint32, uint256) {
        require(p.fee != 10000, "missing pool");
        return (p.amountIn * (p.fee == 500 ? 3 : 2), 1, 0, 1);
    }
    function exactInputSingle(IV3Router.Params calldata p) external payable returns (uint256) {
        require(IERC20(p.tokenIn).transferFrom(msg.sender, address(this), partialFill ? p.amountIn / 2 : p.amountIn));
        uint256 out = p.amountIn * 3;
        require(out >= p.amountOutMinimum);
        require(IERC20(p.tokenOut).transfer(p.recipient, out));
        return out;
    }
}
contract V3AdapterTest {
    Token a; Token b; MockV3 dex; V3Adapter adapter;
    function setUp() public {
        a = new Token("A"); b = new Token("B"); dex = new MockV3();
        uint24[] memory fees = new uint24[](4); fees[0]=100; fees[1]=500; fees[2]=3000; fees[3]=10000;
        adapter = new V3Adapter("V3", address(dex), address(dex), fees);
        a.mint(address(this), 100 ether); b.mint(address(dex), 1000 ether);
        a.approve(address(adapter), 10 ether);
    }
    function testSelectsBestTierAndSkipsRevertingPool() public {
        (uint256 out, uint24 fee) = adapter.quote(address(a), address(b), 1 ether);
        require(out == 3 ether && fee == 500);
    }
    function testExactInputClearsApprovalAndPreservesDonations() public {
        a.mint(address(adapter), 1 ether); b.mint(address(adapter), 1 ether);
        require(adapter.swap(address(a), address(b), 10 ether, 30 ether, 500) == 30 ether);
        require(a.balanceOf(address(adapter)) == 1 ether && b.balanceOf(address(adapter)) == 1 ether);
        require(a.allowance(address(adapter), address(dex)) == 0);
    }
    function testPartialFillRollsBack() public {
        dex.setPartial();
        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.swap, (address(a), address(b), 10 ether, 1, 500)));
        require(!ok && a.balanceOf(address(this)) == 100 ether && b.balanceOf(address(this)) == 0);
    }
    function testUnconfiguredFeeRollsBack() public {
        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.swap, (address(a), address(b), 10 ether, 1, 900)));
        require(!ok && a.balanceOf(address(this)) == 100 ether);
    }
}
