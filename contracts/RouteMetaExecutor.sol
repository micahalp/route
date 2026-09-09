// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice A constrained settlement guard for a fixed upstream aggregator.
/// @dev Even untrusted upstream calldata cannot relax the outer amount, minimum,
/// recipient or deadline. Only the caller's exact input is approved, then revoked.
contract RouteMetaExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable aggregator;
    bytes4 public immutable swapSelector;
    error InvalidSwap(); error DeadlineExpired(); error UnsupportedToken(); error SlippageExceeded(); error UpstreamReverted();
    event Swapped(address indexed sender, address indexed recipient, address indexed tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    constructor(address target, bytes4 selector) {
        if (target.code.length == 0 || selector == bytes4(0)) revert InvalidSwap();
        aggregator = target; swapSelector = selector;
    }
    receive() external payable {}
    function balance(address token) private view returns (uint256) { return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this)); }
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient, uint256 deadline, bytes calldata data)
        external payable nonReentrant returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (tokenIn == tokenOut || amountIn == 0 || minOut == 0 || recipient == address(0) || recipient == address(this) || data.length < 4 || data.length > 65536 || bytes4(data[:4]) != swapSelector) revert InvalidSwap();
        if ((tokenIn != address(0) && tokenIn.code.length == 0) || (tokenOut != address(0) && tokenOut.code.length == 0)) revert InvalidSwap();
        if (msg.value != (tokenIn == address(0) ? amountIn : 0)) revert InvalidSwap();
        uint256 beforeInput = balance(tokenIn) - msg.value;
        uint256 beforeOutput = balance(tokenOut);
        if (tokenIn != address(0)) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            if (balance(tokenIn) != beforeInput + amountIn) revert UnsupportedToken();
            IERC20(tokenIn).forceApprove(aggregator, amountIn);
        }
        // Fixed target and selector, never delegatecall. Ignore untrusted return data.
        (bool ok,) = aggregator.call{value: msg.value}(data);
        if (!ok) revert UpstreamReverted();
        if (tokenIn != address(0)) IERC20(tokenIn).forceApprove(aggregator, 0);
        if (balance(tokenIn) != beforeInput) revert UnsupportedToken();
        amountOut = balance(tokenOut) - beforeOutput;
        if (amountOut < minOut) revert SlippageExceeded();
        if (tokenOut == address(0)) { (bool sent,) = recipient.call{value: amountOut}(""); if (!sent) revert InvalidSwap(); }
        else {
            uint256 beforeRecipient = IERC20(tokenOut).balanceOf(recipient);
            IERC20(tokenOut).safeTransfer(recipient, amountOut);
            if (IERC20(tokenOut).balanceOf(recipient) != beforeRecipient + amountOut) revert UnsupportedToken();
        }
        emit Swapped(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
    }
}
