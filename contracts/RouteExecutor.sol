// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRouteAdapter} from "./interfaces/IRouteAdapter.sol";
import {V4Adapter} from "./adapters/V4Adapter.sol";

interface IExecutorWrapped is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @notice Noncustodial settlement for offchain-computed, split, multihop routes.
/// @dev Immutable adapters; no owner, upgrades, arbitrary calls or retained allowances.
contract RouteExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;
    struct Leg { address adapter; address tokenOut; uint24 fee; int24 tickSpacing; address hooks; bool nativePool; }
    struct Branch { uint256 amountIn; Leg[] legs; }
    IExecutorWrapped public immutable wrappedNative;
    address public immutable v4Adapter;
    mapping(address => bool) public allowedAdapter;
    error InvalidRoute();
    error InvalidAmount();
    error DeadlineExpired();
    error UnsupportedToken();
    error SlippageExceeded();
    error NativeTransferFailed();
    event Swapped(address indexed sender, address indexed recipient, address indexed tokenIn, address tokenOut,
        uint256 amountIn, uint256 amountOut, bytes32 routeHash);

    constructor(address wrapped, address[] memory adapters, address v4) {
        if (wrapped.code.length == 0 || adapters.length == 0 || adapters.length > 16) revert InvalidRoute();
        wrappedNative = IExecutorWrapped(wrapped);
        for (uint256 i; i < adapters.length; ++i) {
            if (adapters[i].code.length == 0 || allowedAdapter[adapters[i]]) revert InvalidRoute();
            allowedAdapter[adapters[i]] = true;
        }
        if (v4 != address(0) && !allowedAdapter[v4]) revert InvalidRoute();
        v4Adapter = v4;
    }
    receive() external payable { if (msg.sender != address(wrappedNative)) revert InvalidRoute(); }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient,
        uint256 deadline, Branch[] calldata branches) external payable nonReentrant returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        address input = tokenIn == address(0) ? address(wrappedNative) : tokenIn;
        address output = tokenOut == address(0) ? address(wrappedNative) : tokenOut;
        if (input == output || input.code.length == 0 || output.code.length == 0 || recipient == address(0) || recipient == address(this)) revert InvalidRoute();
        if (amountIn == 0 || minOut == 0 || msg.value != (tokenIn == address(0) ? amountIn : 0)) revert InvalidAmount();
        if (branches.length == 0 || branches.length > 4) revert InvalidRoute();
        uint256 sum;
        for (uint256 b; b < branches.length; ++b) {
            Branch calldata branch = branches[b];
            if (branch.amountIn == 0 || branch.legs.length == 0 || branch.legs.length > 4) revert InvalidRoute();
            sum += branch.amountIn;
            address previous = input;
            for (uint256 h; h < branch.legs.length; ++h) {
                Leg calldata leg = branch.legs[h];
                if (!allowedAdapter[leg.adapter] || leg.tokenOut.code.length == 0 || leg.tokenOut == input || leg.tokenOut == previous) revert InvalidRoute();
                for (uint256 j; j < h; ++j) if (branch.legs[j].tokenOut == leg.tokenOut) revert InvalidRoute();
                if (leg.adapter != v4Adapter && (leg.tickSpacing != 0 || leg.hooks != address(0) || leg.nativePool)) revert InvalidRoute();
                previous = leg.tokenOut;
            }
            if (previous != output) revert InvalidRoute();
        }
        if (sum != amountIn) revert InvalidAmount();
        uint256 beforeInput = IERC20(input).balanceOf(address(this));
        uint256 beforeOutput = IERC20(output).balanceOf(address(this));
        if (tokenIn == address(0)) wrappedNative.deposit{value: amountIn}();
        else IERC20(input).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(input).balanceOf(address(this)) != beforeInput + amountIn) revert UnsupportedToken();
        for (uint256 b; b < branches.length; ++b) {
            address current = input;
            uint256 amount = branches[b].amountIn;
            for (uint256 h; h < branches[b].legs.length; ++h) {
                Leg calldata leg = branches[b].legs[h];
                uint256 startInput = IERC20(current).balanceOf(address(this));
                uint256 startOutput = IERC20(leg.tokenOut).balanceOf(address(this));
                IERC20(current).forceApprove(leg.adapter, amount);
                if (leg.adapter == v4Adapter) V4Adapter(payable(v4Adapter)).swap(current, leg.tokenOut, amount, leg.fee, leg.tickSpacing, leg.hooks, leg.nativePool);
                else IRouteAdapter(leg.adapter).swap(current, leg.tokenOut, amount, 1, leg.fee);
                IERC20(current).forceApprove(leg.adapter, 0);
                if (IERC20(current).balanceOf(address(this)) != startInput - amount) revert UnsupportedToken();
                amount = IERC20(leg.tokenOut).balanceOf(address(this)) - startOutput;
                if (amount == 0) revert SlippageExceeded();
                current = leg.tokenOut;
            }
        }
        if (IERC20(input).balanceOf(address(this)) != beforeInput) revert UnsupportedToken();
        amountOut = IERC20(output).balanceOf(address(this)) - beforeOutput;
        if (amountOut < minOut) revert SlippageExceeded();
        if (tokenOut == address(0)) {
            wrappedNative.withdraw(amountOut);
            (bool ok,) = recipient.call{value: amountOut}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            uint256 beforeRecipient = IERC20(output).balanceOf(recipient);
            IERC20(output).safeTransfer(recipient, amountOut);
            if (IERC20(output).balanceOf(recipient) != beforeRecipient + amountOut) revert UnsupportedToken();
        }
        emit Swapped(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut, keccak256(abi.encode(branches)));
    }
}
