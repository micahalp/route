// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {DirectV3Adapter, IDirectV3Pool} from "../experimental/DirectV3Adapter.sol";
import {IV3Quoter} from "../adapters/V3Adapter.sol";
import {Token, TaxToken, Vm} from "./Route.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DirectFactoryMock {
    address public pool;

    function setPool(address value) external {
        pool = value;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

contract DirectQuoterMock {
    address public immutable factory;
    bool public fail;

    constructor(address f) {
        factory = f;
    }

    function setFail(bool value) external {
        fail = value;
    }

    function quoteExactInputSingle(IV3Quoter.Params calldata p)
        external
        view
        returns (uint256, uint160, uint32, uint256)
    {
        require(!fail);
        return (p.amountIn * (p.fee == 500 ? 2 : 1), 0, 0, 1);
    }
}

contract DirectPoolMock is IDirectV3Pool {
    address public input;
    address public output;
    bool public pancake;
    uint256 public mode;

    constructor(address a, address b, bool p) {
        input = a;
        output = b;
        pancake = p;
    }

    function setMode(uint256 value) external {
        mode = value;
    }

    function swap(address to, bool direction, int256 amount, uint160, bytes calldata)
        external
        returns (int256 d0, int256 d1)
    {
        uint256 out = uint256(amount) * 2;
        int256 owed = mode == 1 ? amount - 1 : mode == 2 ? amount + 1 : amount;
        d0 = direction ? owed : -int256(out);
        d1 = direction ? -int256(out) : owed;
        IERC20(output).transfer(to, out);
        if (mode != 3) {
            _callback(msg.sender, d0, d1);
            if (mode == 4) {
                _callback(msg.sender, d0, d1);
            }
        }
        if (mode == 5) {
            if (direction) {
                d1 -= 1;
            } else {
                d0 -= 1;
            }
        }
    }

    function _callback(address a, int256 d0, int256 d1) private {
        if (pancake) {
            DirectV3Adapter(a).pancakeV3SwapCallback(d0, d1, "");
        } else {
            DirectV3Adapter(a).uniswapV3SwapCallback(d0, d1, "");
        }
    }
}

contract DirectV3AdapterTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token input;
    Token output;
    DirectFactoryMock factory;
    DirectQuoterMock quoter;
    DirectPoolMock pool;
    DirectV3Adapter adapter;

    function setUp() public {
        input = new Token("IN");
        output = new Token("OUT");
        factory = new DirectFactoryMock();
        quoter = new DirectQuoterMock(address(factory));
        pool = new DirectPoolMock(address(input), address(output), false);
        factory.setPool(address(pool));
        adapter = new DirectV3Adapter(
            "Sushi family test", address(factory), address(quoter), _fees(), false
        );
        input.mint(address(this), 1e24);
        output.mint(address(pool), 1e24);
        input.approve(address(adapter), 100);
    }

    function _fees() private pure returns (uint24[] memory fees) {
        fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 3000;
    }

    function _swap() private returns (uint256) {
        return adapter.swap(address(input), address(output), 100, 200, 500);
    }

    function testExactInputOutputNoAllowancesAndDonations() public {
        input.mint(address(adapter), 17);
        output.mint(address(adapter), 19);
        uint256 beforeInput = input.balanceOf(address(this));
        require(_swap() == 200);
        require(input.balanceOf(address(this)) == beforeInput - 100);
        require(output.balanceOf(address(this)) == 200);
        require(input.balanceOf(address(adapter)) == 17 && output.balanceOf(address(adapter)) == 19);
        require(input.allowance(address(this), address(adapter)) == 0);
        require(input.allowance(address(adapter), address(pool)) == 0);
        vm.expectRevert(DirectV3Adapter.CallbackRejected.selector);
        adapter.uniswapV3SwapCallback(100, -200, "");
    }

    function testPancakeCallback() public {
        pool = new DirectPoolMock(address(input), address(output), true);
        factory.setPool(address(pool));
        adapter = new DirectV3Adapter(
            "Pancake family test", address(factory), address(quoter), _fees(), true
        );
        output.mint(address(pool), 1000);
        input.approve(address(adapter), 100);
        require(_swap() == 200);
    }

    function testOppositeTokenOrder() public {
        (input, output) = (output, input);
        pool = new DirectPoolMock(address(input), address(output), false);
        factory.setPool(address(pool));
        input.mint(address(this), 100);
        output.mint(address(pool), 200);
        input.approve(address(adapter), 100);
        require(_swap() == 200);
    }

    function testQuoteChoosesBestSupportedFee() public {
        (uint256 out, uint24 fee) = adapter.quote(address(input), address(output), 100);
        require(out == 200 && fee == 500);
        quoter.setFail(true);
        (out, fee) = adapter.quote(address(input), address(output), 100);
        require(out == 0 && fee == 0);
    }

    function testRejectUnsupportedFee() public {
        vm.expectRevert(DirectV3Adapter.InvalidSwap.selector);
        adapter.swap(address(input), address(output), 100, 1, 10000);
    }

    function testMinimumRollsBackInput() public {
        uint256 beforeInput = input.balanceOf(address(this));
        vm.expectRevert(DirectV3Adapter.InvalidSwap.selector);
        adapter.swap(address(input), address(output), 100, 201, 500);
        require(
            input.balanceOf(address(this)) == beforeInput
                && input.allowance(address(this), address(adapter)) == 100
        );
    }

    function testRejectPartialInput() public {
        pool.setMode(1);
        vm.expectRevert(DirectV3Adapter.CallbackRejected.selector);
        _swap();
    }

    function testRejectExcessInput() public {
        pool.setMode(2);
        vm.expectRevert(DirectV3Adapter.CallbackRejected.selector);
        _swap();
    }

    function testRejectMissingCallback() public {
        pool.setMode(3);
        vm.expectRevert(DirectV3Adapter.CallbackRejected.selector);
        _swap();
    }

    function testRejectRepeatedCallback() public {
        pool.setMode(4);
        vm.expectRevert(DirectV3Adapter.CallbackRejected.selector);
        _swap();
    }

    function testRejectFalseOutputDelta() public {
        pool.setMode(5);
        vm.expectRevert(DirectV3Adapter.InvalidSwap.selector);
        _swap();
    }

    function testRejectWrongCallbackFamily() public {
        pool = new DirectPoolMock(address(input), address(output), true);
        factory.setPool(address(pool));
        output.mint(address(pool), 200);
        vm.expectRevert(DirectV3Adapter.CallbackRejected.selector);
        _swap();
    }

    function testRejectArbitraryCallback() public {
        vm.expectRevert(DirectV3Adapter.CallbackRejected.selector);
        adapter.uniswapV3SwapCallback(100, -200, "");
        vm.expectRevert(DirectV3Adapter.CallbackRejected.selector);
        adapter.pancakeV3SwapCallback(100, -200, "");
    }

    function testRejectMissingPool() public {
        factory.setPool(address(0));
        vm.expectRevert(DirectV3Adapter.InvalidSwap.selector);
        _swap();
    }

    function testRejectWrongQuoterFactory() public {
        vm.expectRevert(DirectV3Adapter.InvalidConfiguration.selector);
        new DirectV3Adapter("bad", address(pool), address(quoter), _fees(), false);
    }

    function testRejectDuplicateFee() public {
        uint24[] memory fees = _fees();
        fees[1] = fees[0];
        vm.expectRevert(DirectV3Adapter.InvalidConfiguration.selector);
        new DirectV3Adapter("bad", address(factory), address(quoter), fees, false);
    }

    function testRejectTaxedInput() public {
        TaxToken tax = new TaxToken();
        tax.mint(address(this), 1000);
        tax.approve(address(adapter), 100);
        vm.expectRevert(DirectV3Adapter.UnsupportedToken.selector);
        adapter.swap(address(tax), address(output), 100, 1, 500);
    }

    function testFuzzExactInput(uint64 amount) public {
        if (amount == 0) {
            return;
        }
        input.approve(address(adapter), amount);
        require(
            adapter.swap(address(input), address(output), amount, uint256(amount) * 2, 500)
                == uint256(amount) * 2
        );
    }
}
