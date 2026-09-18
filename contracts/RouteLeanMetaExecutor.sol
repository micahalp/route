// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Fee-free upstream settlement with executor-custodied output.
/// @dev Upstream calldata must deliver output here. Recipient inflows during the
/// upstream call never count toward minOut. Preserves donations and revokes approvals.
contract RouteLeanMetaExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable aggregator;
    bytes4 public immutable swapSelector;
    error InvalidSwap();
    error DeadlineExpired();
    error UnsupportedToken();
    error SlippageExceeded();
    error UpstreamReverted();
    event Swapped(
        address indexed sender,
        address indexed recipient,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address target, bytes4 selector) {
        if (target.code.length == 0 || selector == bytes4(0)) {
            revert InvalidSwap();
        }
        aggregator = target;
        swapSelector = selector;
    }

    receive() external payable {}

    function _balance(address token, address owner) private view returns (uint256) {
        return token == address(0) ? owner.balance : IERC20(token).balanceOf(owner);
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline,
        bytes calldata data
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }
        if (
            tokenIn == tokenOut || amountIn == 0 || minOut == 0 || recipient == address(0)
                || recipient == address(this) || recipient == aggregator || data.length < 4
                || data.length > 65536 || bytes4(data[:4]) != swapSelector
        ) {
            revert InvalidSwap();
        }
        if (
            (tokenIn != address(0) && tokenIn.code.length == 0)
                || (tokenOut != address(0) && tokenOut.code.length == 0)
        ) {
            revert InvalidSwap();
        }
        if (msg.value != (tokenIn == address(0) ? amountIn : 0)) {
            revert InvalidSwap();
        }

        uint256 beforeInput = _balance(tokenIn, address(this)) - msg.value;
        uint256 beforeOutput = _balance(tokenOut, address(this));
        if (tokenIn != address(0)) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            if (_balance(tokenIn, address(this)) != beforeInput + amountIn) {
                revert UnsupportedToken();
            }
            IERC20(tokenIn).forceApprove(aggregator, amountIn);
        }

        (bool ok,) = aggregator.call{value: msg.value}(data);
        if (!ok) {
            revert UpstreamReverted();
        }
        if (tokenIn != address(0)) {
            IERC20(tokenIn).forceApprove(aggregator, 0);
        }
        if (_balance(tokenIn, address(this)) != beforeInput) {
            revert UnsupportedToken();
        }
        uint256 afterOutput = _balance(tokenOut, address(this));
        if (afterOutput < beforeOutput) {
            revert SlippageExceeded();
        }
        amountOut = afterOutput - beforeOutput;
        if (amountOut < minOut) {
            revert SlippageExceeded();
        }
        if (tokenOut == address(0)) {
            (bool sent,) = recipient.call{value: amountOut}("");
            if (!sent) {
                revert InvalidSwap();
            }
        } else {
            uint256 beforeRecipient = IERC20(tokenOut).balanceOf(recipient);
            IERC20(tokenOut).safeTransfer(recipient, amountOut);
            if (IERC20(tokenOut).balanceOf(recipient) != beforeRecipient + amountOut) {
                revert UnsupportedToken();
            }
        }
        if (_balance(tokenOut, address(this)) != beforeOutput) {
            revert UnsupportedToken();
        }
        emit Swapped(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
    }
}
