// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IV4Wrapped is IERC20 { function deposit() external payable; function withdraw(uint256) external; }
interface IRoutePoolManager {
    struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// @notice Exact-input V4 adapter. Native pools are normalized to WETH at its boundary.
/// @dev Hookless pools only in this release. Hook code needs separate review before enabling.
contract V4Adapter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IRoutePoolManager public immutable poolManager;
    IV4Wrapped public immutable wrappedNative;
    bytes32 private pending;
    error InvalidSwap();
    error UnauthorizedCallback();
    error UnsupportedToken();
    constructor(address manager, address wrapped) {
        if (manager.code.length == 0 || wrapped.code.length == 0) revert InvalidSwap();
        poolManager = IRoutePoolManager(manager); wrappedNative = IV4Wrapped(wrapped);
    }
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(wrappedNative)) revert UnauthorizedCallback();
    }
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, int24 tickSpacing, address hooks, bool nativePool)
        external nonReentrant returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut || tokenIn == address(0) || tokenOut == address(0) || amountIn == 0 || amountIn > uint256(uint128(type(int128).max)) || hooks != address(0) || fee >= 1_000_000 || tickSpacing <= 0) revert InvalidSwap();
        address input = nativePool && tokenIn == address(wrappedNative) ? address(0) : tokenIn;
        address output = nativePool && tokenOut == address(wrappedNative) ? address(0) : tokenOut;
        if (nativePool && input != address(0) && output != address(0)) revert InvalidSwap();
        uint256 beforeInput = IERC20(tokenIn).balanceOf(address(this));
        uint256 beforeOutput = IERC20(tokenOut).balanceOf(address(this));
        uint256 beforeNative = address(this).balance;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(tokenIn).balanceOf(address(this)) != beforeInput + amountIn) revert UnsupportedToken();
        if (input == address(0)) wrappedNative.withdraw(amountIn);
        IRoutePoolManager.PoolKey memory key = IRoutePoolManager.PoolKey(input < output ? input : output, input < output ? output : input, fee, tickSpacing, hooks);
        bytes memory data = abi.encode(key, input, output, amountIn);
        pending = keccak256(data);
        amountOut = abi.decode(poolManager.unlock(data), (uint256));
        if (pending != bytes32(0)) revert UnauthorizedCallback();
        if (output == address(0)) wrappedNative.deposit{value: amountOut}();
        if (address(this).balance != beforeNative || IERC20(tokenIn).balanceOf(address(this)) != beforeInput || IERC20(tokenOut).balanceOf(address(this)) != beforeOutput + amountOut) revert UnsupportedToken();
        uint256 beforeRecipient = IERC20(tokenOut).balanceOf(msg.sender);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        if (IERC20(tokenOut).balanceOf(msg.sender) != beforeRecipient + amountOut) revert UnsupportedToken();
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || pending == bytes32(0) || keccak256(data) != pending) revert UnauthorizedCallback();
        pending = bytes32(0);
        (IRoutePoolManager.PoolKey memory key, address input, address output, uint256 amountIn) = abi.decode(data, (IRoutePoolManager.PoolKey, address, address, uint256));
        bool zeroForOne = input == key.currency0;
        int256 delta = poolManager.swap(key, IRoutePoolManager.SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341), "");
        int128 d0 = int128(delta >> 128); int128 d1 = int128(delta);
        int128 paid = zeroForOne ? d0 : d1; int128 received = zeroForOne ? d1 : d0;
        if (paid >= 0 || received <= 0 || uint256(-int256(paid)) != amountIn) revert InvalidSwap();
        if (input == address(0)) { if (poolManager.settle{value: amountIn}() != amountIn) revert UnsupportedToken(); }
        else {
            poolManager.sync(input);
            IERC20(input).safeTransfer(address(poolManager), amountIn);
            if (poolManager.settle() != amountIn) revert UnsupportedToken();
        }
        uint256 amountOut = uint256(uint128(received));
        poolManager.take(output, address(this), amountOut);
        return abi.encode(amountOut);
    }
}
