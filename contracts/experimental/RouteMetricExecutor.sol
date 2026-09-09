// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IRouteMetricFactory { function isPool(address pool) external view returns (bool); }
interface IRouteMetricWrapped is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
interface IRouteMetricPool {
    struct Immutables {
        address factory; address token0; address token1;
        uint256 scale0; uint256 scale1; uint256 shares0; uint256 shares1; uint256 minimumLiquidity;
        address immutablePriceProvider; int256 lowestBin; int256 highestBin;
        address extension1; address extension2; address extension3; address extension4;
        address extension5; address extension6; address extension7;
        uint256 beforeAdd; uint256 afterAdd; uint256 beforeRemove; uint256 afterRemove;
        uint256 beforeSwap; uint256 afterSwap;
    }
    function getImmutables() external view returns (Immutables memory);
    function swap(address recipient, bool zeroForOne, int128 amount, uint128 priceLimit,
        bytes calldata callbackData, bytes calldata extensionData) external returns (int128, int128);
}

/// @notice Experimental single-pool settlement, NOT deployed or active in Route.
/// @dev Explicit pool address, not an overloaded fee field. Fixed factory/wrapped token;
/// no arbitrary calls, hooks, owner, upgrade, Route fee or executor approvals.
/// ERC20 input is paid straight from caller to pool; ERC20 output goes straight to recipient.
/// Native conversion uses only this swap's exact amount, never whole held balances.
/// Oracle/admin review, mixed routing and full-provider comparison remain release gates.
contract RouteMetricExecutor is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    address public immutable factory;
    IRouteMetricWrapped public immutable wrappedNative;
    address private transient callbackPool;
    address private transient callbackToken;
    address private transient callbackPayer;
    uint256 private transient callbackAmount;
    uint256 private transient callbackOutput;
    bool private transient callbackDirection;
    error InvalidRoute();
    error InvalidAmount();
    error DeadlineExpired();
    error CallbackRejected();
    error UnsupportedToken();
    error SlippageExceeded();
    error NativeTransferFailed();
    event Swapped(address indexed sender, address indexed recipient, address indexed pool,
        address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    constructor(address poolFactory, address wrapped) {
        if (poolFactory.code.length == 0 || wrapped.code.length == 0) revert InvalidRoute();
        factory = poolFactory; wrappedNative = IRouteMetricWrapped(wrapped);
    }
    receive() external payable { if (msg.sender != address(wrappedNative)) revert InvalidRoute(); }

    function swap(address pool, address tokenIn, address tokenOut, uint256 amountIn,
        uint256 minimum, address recipient, uint256 deadline) external payable nonReentrant returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max)) || minimum == 0) revert InvalidAmount();
        if (recipient == address(0) || recipient == address(this) || recipient == pool ||
            pool.code.length == 0 || !IRouteMetricFactory(factory).isPool(pool)) revert InvalidRoute();
        address input = tokenIn == address(0) ? address(wrappedNative) : tokenIn;
        address output = tokenOut == address(0) ? address(wrappedNative) : tokenOut;
        if (input == output || msg.value != (tokenIn == address(0) ? amountIn : 0)) revert InvalidAmount();
        IRouteMetricPool.Immutables memory p = IRouteMetricPool(pool).getImmutables();
        // Metric token order is explicit and need not be lexicographically sorted.
        if (p.factory != factory || p.token0 == p.token1 ||
            !((input == p.token0 && output == p.token1) || (input == p.token1 && output == p.token0)) ||
            p.extension1 != address(0) || p.extension2 != address(0) || p.extension3 != address(0) ||
            p.extension4 != address(0) || p.extension5 != address(0) || p.extension6 != address(0) || p.extension7 != address(0) ||
            p.beforeAdd != 0 || p.afterAdd != 0 || p.beforeRemove != 0 || p.afterRemove != 0 || p.beforeSwap != 0 || p.afterSwap != 0)
            revert InvalidRoute();
        uint256 nativeBefore = address(this).balance - msg.value;
        uint256 inputBefore = IERC20(input).balanceOf(address(this));
        uint256 outputBefore = IERC20(output).balanceOf(address(this));
        uint256 senderBefore = tokenIn == address(0) ? 0 : IERC20(input).balanceOf(msg.sender);
        address outputRecipient = tokenOut == address(0) ? address(this) : recipient;
        uint256 recipientBefore = IERC20(output).balanceOf(outputRecipient);
        if (tokenIn == address(0)) {
            wrappedNative.deposit{value: amountIn}();
            if (wrappedNative.balanceOf(address(this)) != inputBefore + amountIn) revert UnsupportedToken();
        }
        callbackPool = pool; callbackToken = input; callbackPayer = tokenIn == address(0) ? address(this) : msg.sender;
        callbackAmount = amountIn; callbackDirection = input == p.token0;
        (int128 d0, int128 d1) = IRouteMetricPool(pool).swap(outputRecipient, callbackDirection, int128(uint128(amountIn)),
            callbackDirection ? 0 : type(uint128).max, "", "");
        if (callbackPool != address(0) || callbackAmount != 0) revert CallbackRejected();
        int256 spent = callbackDirection ? int256(d0) : int256(d1);
        int256 received = callbackDirection ? int256(d1) : int256(d0);
        amountOut = IERC20(output).balanceOf(outputRecipient) - recipientBefore;
        if (spent != int256(amountIn) || received >= 0 || uint256(-received) != amountOut || callbackOutput != amountOut)
            revert InvalidAmount();
        if (amountOut < minimum) revert SlippageExceeded();
        delete callbackToken; delete callbackPayer; delete callbackDirection; delete callbackOutput;
        if (tokenOut == address(0)) {
            wrappedNative.withdraw(amountOut);
            (bool ok,) = recipient.call{value: amountOut}("");
            if (!ok) revert NativeTransferFailed();
        }
        if (IERC20(input).balanceOf(address(this)) != inputBefore || IERC20(output).balanceOf(address(this)) != outputBefore ||
            address(this).balance != nativeBefore || (tokenIn != address(0) && IERC20(input).balanceOf(msg.sender) + amountIn != senderBefore))
            revert UnsupportedToken();
        emit Swapped(msg.sender, recipient, pool, tokenIn, tokenOut, amountIn, amountOut);
    }

    function metricOmmSwapCallback(int256 delta0, int256 delta1, bytes calldata data) external {
        if (callbackPool == address(0) || msg.sender != callbackPool || data.length != 0) revert CallbackRejected();
        int256 owed = callbackDirection ? delta0 : delta1;
        int256 received = callbackDirection ? delta1 : delta0;
        if (owed <= 0 || uint256(owed) != callbackAmount || received >= 0 || received < -int256(type(int128).max)) revert CallbackRejected();
        IERC20 token = IERC20(callbackToken); address payer = callbackPayer;
        delete callbackPool; delete callbackAmount; callbackOutput = uint256(-received);
        uint256 beforePool = token.balanceOf(msg.sender);
        if (payer == address(this)) token.safeTransfer(msg.sender, uint256(owed));
        else token.safeTransferFrom(payer, msg.sender, uint256(owed));
        if (token.balanceOf(msg.sender) != beforePool + uint256(owed)) revert UnsupportedToken();
    }
}
