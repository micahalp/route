// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRouteAdapter} from "../interfaces/IRouteAdapter.sol";

abstract contract BaseAdapter is IRouteAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;
    error InvalidConfiguration();
    error UnsupportedToken();
    error InvalidSwap();
    string public override name;
    address public immutable dexRouter;

    constructor(string memory label, address router) {
        if (router.code.length == 0 || bytes(label).length == 0) revert InvalidConfiguration();
        name = label;
        dexRouter = router;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint24 fee)
        external nonReentrant returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut || amountIn == 0) revert InvalidSwap();
        IERC20 input = IERC20(tokenIn);
        IERC20 output = IERC20(tokenOut);
        uint256 inputBefore = input.balanceOf(address(this));
        uint256 outputBefore = output.balanceOf(address(this));
        input.safeTransferFrom(msg.sender, address(this), amountIn);
        if (input.balanceOf(address(this)) != inputBefore + amountIn) revert UnsupportedToken();
        input.forceApprove(dexRouter, amountIn);
        _execute(tokenIn, tokenOut, amountIn, minOut, fee);
        input.forceApprove(dexRouter, 0);
        // Reject partial fills and do not spend balances donated by another user.
        if (input.balanceOf(address(this)) != inputBefore) revert UnsupportedToken();
        amountOut = output.balanceOf(address(this)) - outputBefore;
        if (amountOut == 0 || amountOut < minOut) revert InvalidSwap();
        uint256 recipientBefore = output.balanceOf(msg.sender);
        output.safeTransfer(msg.sender, amountOut);
        if (output.balanceOf(msg.sender) != recipientBefore + amountOut) revert UnsupportedToken();
    }

    function _execute(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint24 fee) internal virtual;
}
