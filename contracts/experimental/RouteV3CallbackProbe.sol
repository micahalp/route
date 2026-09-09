// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IProbeV3Factory { function getPool(address, address, uint24) external view returns (address); }
interface IProbeV3Pool {
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
}
interface IProbeWrapped is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @notice Undeployed single-hop research fixture, NOT the Route production executor.
/// @dev Constructor factory provenance and EIP-1153 support must be independently
/// verified before any fork/deployment evidence. No admin, fee or arbitrary target.
contract RouteV3CallbackProbe is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IProbeV3Factory public immutable factory;
    IProbeWrapped public immutable wrapped;
    address private transient activePool;
    address private transient activeInput;
    uint256 private transient activeAmount;
    uint256 private transient activeOutputAmount;
    bool private transient activeZeroForOne;
    error InvalidRoute();
    error InvalidAmount();
    error Expired();
    error CallbackRejected();
    error UnsupportedToken();
    error SlippageExceeded();
    error NativeTransferFailed();

    constructor(address f, address w) {
        if (f.code.length == 0 || w.code.length == 0) revert InvalidRoute();
        factory = IProbeV3Factory(f); wrapped = IProbeWrapped(w);
    }
    receive() external payable { if (msg.sender != address(wrapped)) revert InvalidRoute(); }

    function swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn,
        uint256 minOut, address recipient, uint256 deadline) external payable nonReentrant returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired();
        address input = tokenIn == address(0) ? address(wrapped) : tokenIn;
        address output = tokenOut == address(0) ? address(wrapped) : tokenOut;
        if (input == output || input.code.length == 0 || output.code.length == 0 ||
            recipient == address(0) || recipient == address(this) || fee == 0 || fee >= 1_000_000) revert InvalidRoute();
        if (amountIn == 0 || amountIn > uint256(type(int256).max) || minOut == 0 ||
            msg.value != (tokenIn == address(0) ? amountIn : 0)) revert InvalidAmount();
        // The caller cannot provide a pool or callback payment destination.
        address pool = factory.getPool(input, output, fee);
        if (pool.code.length == 0) revert InvalidRoute();
        uint256 beforeInput = IERC20(input).balanceOf(address(this));
        uint256 beforeOutput = IERC20(output).balanceOf(address(this));
        if (tokenIn == address(0)) wrapped.deposit{value: amountIn}();
        else IERC20(input).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(input).balanceOf(address(this)) != beforeInput + amountIn) revert UnsupportedToken();
        activePool = pool; activeInput = input; activeAmount = amountIn; activeZeroForOne = input < output;
        IProbeV3Pool(pool).swap(address(this), input < output, int256(amountIn), input < output
            ? 4295128740 : 1461446703485210103287273052203988822378723970341, "");
        if (activePool != address(0) || activeAmount != 0) revert CallbackRejected();
        delete activeInput; delete activeZeroForOne;
        if (IERC20(input).balanceOf(address(this)) != beforeInput) revert UnsupportedToken();
        amountOut = IERC20(output).balanceOf(address(this)) - beforeOutput;
        if (amountOut != activeOutputAmount) revert UnsupportedToken();
        delete activeOutputAmount;
        if (amountOut < minOut) revert SlippageExceeded();
        if (tokenOut == address(0)) {
            wrapped.withdraw(amountOut);
            (bool ok,) = recipient.call{value: amountOut}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            uint256 beforeRecipient = IERC20(output).balanceOf(recipient);
            IERC20(output).safeTransfer(recipient, amountOut);
            if (IERC20(output).balanceOf(recipient) != beforeRecipient + amountOut) revert UnsupportedToken();
        }
        if (IERC20(output).balanceOf(address(this)) != beforeOutput) revert UnsupportedToken();
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != activePool || activePool == address(0) || data.length != 0) revert CallbackRejected();
        int256 owed = activeZeroForOne ? amount0Delta : amount1Delta;
        int256 received = activeZeroForOne ? amount1Delta : amount0Delta;
        if (owed <= 0 || received >= 0 || received == type(int256).min || uint256(owed) != activeAmount) revert CallbackRejected();
        activeOutputAmount = uint256(-received);
        address token = activeInput;
        // Consume the one-shot authorization before interacting with the token.
        delete activePool; delete activeAmount;
        uint256 beforePool = IERC20(token).balanceOf(msg.sender);
        IERC20(token).safeTransfer(msg.sender, uint256(owed));
        if (IERC20(token).balanceOf(msg.sender) != beforePool + uint256(owed)) revert UnsupportedToken();
    }
}
