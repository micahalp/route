// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IJitV2Factory {
    function getPair(address, address) external view returns (address);
}

interface IJitV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IJitWrapped is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @notice EXPERIMENTAL, NOT DEPLOYED. Two-path execution-time selection for a
/// verified canonical 0.30% Uniswap-V2 factory only. Not arbitrary V2 forks.
/// @dev Immutable factory/wrapped token; no owner, fees, approvals or generic calls.
/// Deployment must independently verify factory, pair bytecode and wrapped token.
contract RouteJitV2Executor is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IJitV2Factory public immutable factory;
    IJitWrapped public immutable wrappedNative;

    struct Plan {
        address first;
        address second;
        address bridge;
        uint256 middleOut;
        uint256 amountOut;
        uint256 index;
    }
    error InvalidRoute();
    error InvalidAmount();
    error InvalidRecipient();
    error DeadlineExpired();
    error NoRoute();
    error SlippageExceeded();
    error UnsupportedToken();
    error NativeTransferFailed();
    event Swapped(
        address indexed sender,
        address indexed recipient,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 selectedPath
    );

    constructor(address canonicalFactory, address wrapped) {
        if (canonicalFactory.code.length == 0 || wrapped.code.length == 0) revert InvalidRoute();
        factory = IJitV2Factory(canonicalFactory);
        wrappedNative = IJitWrapped(wrapped);
    }

    receive() external payable {
        if (msg.sender != address(wrappedNative)) revert InvalidRoute();
    }

    function _normalized(address token) private view returns (address) {
        return token == address(0) ? address(wrappedNative) : token;
    }

    function _check(address input, address output, uint256 amount, address[] calldata bridges) private view {
        if (
            input == output || input.code.length == 0 || output.code.length == 0 || bridges.length == 0
                || bridges.length > 2
        ) revert InvalidRoute();
        if (amount == 0 || amount > type(uint112).max) revert InvalidAmount();
        for (uint256 i; i < bridges.length; ++i) {
            if (
                bridges[i] != address(0) && (bridges[i] == input || bridges[i] == output || bridges[i].code.length == 0)
            ) revert InvalidRoute();
            if (i == 1 && bridges[0] == bridges[1]) revert InvalidRoute();
        }
    }

    function _edge(address input, address output, uint256 amount) private view returns (address pair, uint256 out) {
        pair = factory.getPair(input, output);
        if (pair.code.length == 0) return (address(0), 0);
        try IJitV2Pair(pair).getReserves() returns (uint112 r0, uint112 r1, uint32) {
            (uint256 reserveIn, uint256 reserveOut) =
                input < output ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            if (reserveIn == 0 || reserveOut == 0) return (pair, 0);
            uint256 withFee = amount * 997;
            out = withFee * reserveOut / (reserveIn * 1000 + withFee);
        } catch {
            return (pair, 0);
        }
    }

    function _plan(address input, address output, uint256 amount, address bridge, uint256 index)
        private
        view
        returns (Plan memory plan)
    {
        plan.bridge = bridge;
        plan.index = index;
        if (bridge == address(0)) {
            (plan.first, plan.amountOut) = _edge(input, output, amount);
        } else {
            (plan.first, plan.middleOut) = _edge(input, bridge, amount);
            if (plan.middleOut > 0) (plan.second, plan.amountOut) = _edge(bridge, output, plan.middleOut);
            if (plan.first == plan.second) plan.amountOut = 0;
        }
    }

    function _select(address input, address output, uint256 amount, address[] calldata bridges, uint256 minImprovement)
        private
        view
        returns (Plan memory best)
    {
        best = _plan(input, output, amount, bridges[0], 0);
        if (bridges.length == 2) {
            Plan memory other = _plan(input, output, amount, bridges[1], 1);
            if (
                other.amountOut > best.amountOut
                    && (best.amountOut == 0 || other.amountOut - best.amountOut >= minImprovement)
            ) best = other;
        }
        if (best.amountOut == 0) revert NoRoute();
    }

    /// @param bridges Zero means direct; nonzero means one connector token.
    /// @param minImprovement Output-token units required to replace viable path 0.
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address[] calldata bridges,
        uint256 minImprovement
    ) external view returns (uint256 amountOut, uint256 selectedPath) {
        address input = _normalized(tokenIn);
        address output = _normalized(tokenOut);
        _check(input, output, amount, bridges);
        Plan memory plan = _select(input, output, amount, bridges, minImprovement);
        return (plan.amountOut, plan.index);
    }

    function _swap(address pair, address input, address output, uint256 out, address recipient) private {
        IJitV2Pair(pair).swap(input < output ? 0 : out, input < output ? out : 0, recipient, "");
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 minimum,
        address recipient,
        uint256 deadline,
        address[] calldata bridges,
        uint256 minImprovement
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (minimum == 0 || msg.value != (tokenIn == address(0) ? amount : 0)) revert InvalidAmount();
        address input = _normalized(tokenIn);
        address output = _normalized(tokenOut);
        _check(input, output, amount, bridges);
        uint256 beforeNative = address(this).balance - msg.value;
        uint256 beforeInput = IERC20(input).balanceOf(address(this));
        uint256 beforeOutput = IERC20(output).balanceOf(address(this));
        if (tokenIn == address(0)) wrappedNative.deposit{value: amount}();
        else IERC20(input).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(input).balanceOf(address(this)) != beforeInput + amount) revert UnsupportedToken();

        // Selection uses current reserves INSIDE the signed swap transaction.
        Plan memory plan = _select(input, output, amount, bridges, minImprovement);
        if (plan.amountOut < minimum) revert SlippageExceeded();
        address receiver = tokenOut == address(0) ? address(this) : recipient;
        uint256 beforeReceiver = IERC20(output).balanceOf(receiver);
        uint256 beforePair = IERC20(input).balanceOf(plan.first);
        IERC20(input).safeTransfer(plan.first, amount);
        if (IERC20(input).balanceOf(plan.first) != beforePair + amount) revert UnsupportedToken();
        if (plan.bridge == address(0)) {
            _swap(plan.first, input, output, plan.amountOut, receiver);
        } else {
            uint256 beforeMiddle = IERC20(plan.bridge).balanceOf(plan.second);
            _swap(plan.first, input, plan.bridge, plan.middleOut, plan.second);
            if (IERC20(plan.bridge).balanceOf(plan.second) != beforeMiddle + plan.middleOut) revert UnsupportedToken();
            _swap(plan.second, plan.bridge, output, plan.amountOut, receiver);
        }
        if (IERC20(input).balanceOf(address(this)) != beforeInput) revert UnsupportedToken();
        uint256 afterReceiver = IERC20(output).balanceOf(receiver);
        if (afterReceiver < beforeReceiver || afterReceiver - beforeReceiver != plan.amountOut) {
            revert UnsupportedToken();
        }
        amountOut = plan.amountOut;
        if (tokenOut == address(0)) {
            wrappedNative.withdraw(amountOut);
            (bool sent,) = recipient.call{value: amountOut}("");
            if (!sent) revert NativeTransferFailed();
        }
        if (IERC20(output).balanceOf(address(this)) != beforeOutput || address(this).balance != beforeNative) {
            revert UnsupportedToken();
        }
        emit Swapped(msg.sender, recipient, tokenIn, tokenOut, amount, amountOut, plan.index);
    }
}
