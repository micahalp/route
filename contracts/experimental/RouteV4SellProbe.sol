// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRoutePoolManager} from "../adapters/V4Adapter.sol";

/// @notice LOCAL RESEARCH ONLY: one fixed ERC20 -> native V4 pool.
/// @dev Not an approved integration. Outer code hashes do not verify delegated
/// hook behavior. No admin, fee, arbitrary path, native input or JIT selection.
contract RouteV4SellProbe is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IRoutePoolManager public immutable poolManager;
    IERC20 public immutable tokenIn;
    address public immutable hook;
    bytes32 public immutable poolId;
    bytes32 public immutable managerHash;
    bytes32 public immutable hookHash;
    bytes32 private pending;
    error InvalidSwap();
    error DeadlineExpired();
    error UnauthorizedCallback();
    error UnsupportedToken();
    error SlippageExceeded();
    event Swapped(
        address indexed sender,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address manager, address token, address hooks, bytes32 expectedPoolId) {
        if (manager.code.length == 0 || token.code.length == 0 || hooks.code.length == 0) {
            revert InvalidSwap();
        }
        poolManager = IRoutePoolManager(manager);
        tokenIn = IERC20(token);
        hook = hooks;
        poolId = keccak256(abi.encode(address(0), token, uint24(0x800000), int24(1), hooks));
        if (poolId != expectedPoolId) {
            revert InvalidSwap();
        }
        managerHash = manager.codehash;
        hookHash = hooks.codehash;
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) {
            revert UnauthorizedCallback();
        }
    }

    function swap(uint256 amountIn, uint256 minimum, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }
        if (
            amountIn == 0 || amountIn > uint256(uint128(type(int128).max)) || minimum == 0
                || recipient == address(0) || recipient == address(this)
                || recipient == address(poolManager) || address(poolManager).codehash != managerHash
                || hook.codehash != hookHash
        ) {
            revert InvalidSwap();
        }
        uint256 beforePayer = tokenIn.balanceOf(msg.sender);
        uint256 beforeHeld = tokenIn.balanceOf(address(this));
        uint256 beforeNative = address(this).balance;
        bytes memory data = abi.encode(msg.sender, amountIn, minimum);
        pending = keccak256(data);
        amountOut = abi.decode(poolManager.unlock(data), (uint256));
        if (pending != bytes32(0)) {
            revert UnauthorizedCallback();
        }
        if (amountOut < minimum) {
            revert SlippageExceeded();
        }
        if (
            beforePayer < amountIn || tokenIn.balanceOf(msg.sender) != beforePayer - amountIn
                || tokenIn.balanceOf(address(this)) != beforeHeld
                || address(this).balance != beforeNative + amountOut
        ) {
            revert UnsupportedToken();
        }
        (bool ok,) = recipient.call{value: amountOut}("");
        if (!ok) {
            revert InvalidSwap();
        }
        if (address(this).balance != beforeNative) {
            revert UnsupportedToken();
        }
        emit Swapped(msg.sender, recipient, amountIn, amountOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (
            msg.sender != address(poolManager) || pending == bytes32(0)
                || keccak256(data) != pending
        ) {
            revert UnauthorizedCallback();
        }
        pending = bytes32(0);
        (address payer, uint256 amountIn, uint256 minimum) =
            abi.decode(data, (address, uint256, uint256));
        IRoutePoolManager.PoolKey memory key =
            IRoutePoolManager.PoolKey(address(0), address(tokenIn), 0x800000, 1, hook);
        int256 delta = poolManager.swap(
            key,
            IRoutePoolManager.SwapParams(
                false, -int256(amountIn), 1461446703485210103287273052203988822378723970341
            ),
            ""
        );
        int128 received = int128(delta >> 128);
        int128 paid = int128(delta);
        if (paid >= 0 || received <= 0 || uint256(-int256(paid)) != amountIn) {
            revert InvalidSwap();
        }
        uint256 amountOut = uint256(uint128(received));
        if (amountOut < minimum) {
            revert SlippageExceeded();
        }
        // Pull exactly once from the payer into the canonical manager. No
        // intermediate token custody or approval from this contract is needed.
        poolManager.sync(address(tokenIn));
        tokenIn.safeTransferFrom(payer, address(poolManager), amountIn);
        if (poolManager.settle() != amountIn) {
            revert UnsupportedToken();
        }
        poolManager.take(address(0), address(this), amountOut);
        return abi.encode(amountOut);
    }
}
