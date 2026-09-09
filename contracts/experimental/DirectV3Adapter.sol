// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IRouteAdapter} from "../interfaces/IRouteAdapter.sol";
import {IV3Quoter} from "../adapters/V3Adapter.sol";

interface IDirectV3Factory { function getPool(address, address, uint24) external view returns (address); }
interface IDirectV3Quoter is IV3Quoter { function factory() external view returns (address); }
interface IDirectV3Pool {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
}

/// @notice Experimental, NOT activated. Fixed-factory exact-input V3 pool execution.
/// @dev One reusable implementation for independently verified Uniswap-style or Pancake-style
/// pools. No upstream router, arbitrary call, persistent allowance, owner, upgrade or Route fee.
/// The outer Route executor supplies recipient/deadline and handles native wrapping.
contract DirectV3Adapter is IRouteAdapter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    string public override name;
    address public immutable factory;
    address public immutable quoter;
    bool public immutable pancakeCallback;
    uint24[] public feeTiers;
    address private transient expectedPool;
    address private transient expectedInput;
    uint256 private transient expectedAmount;
    bool private transient expectedDirection;
    error InvalidConfiguration();
    error InvalidSwap();
    error CallbackRejected();
    error UnsupportedToken();

    constructor(string memory label, address poolFactory, address quoteContract, uint24[] memory fees, bool pancake) {
        if (bytes(label).length == 0 || poolFactory.code.length == 0 || quoteContract.code.length == 0 ||
            fees.length == 0 || fees.length > 4 || IDirectV3Quoter(quoteContract).factory() != poolFactory)
            revert InvalidConfiguration();
        for (uint256 i; i < fees.length; ++i) {
            if (fees[i] == 0 || fees[i] >= 1_000_000) revert InvalidConfiguration();
            for (uint256 j; j < i; ++j) if (fees[j] == fees[i]) revert InvalidConfiguration();
        }
        name = label; factory = poolFactory; quoter = quoteContract; feeTiers = fees; pancakeCallback = pancake;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external nonReentrant
        returns (uint256 amountOut, uint24 fee)
    {
        if (tokenIn == tokenOut || amountIn == 0 || amountIn > uint256(type(int256).max)) return (0, 0);
        for (uint256 i; i < feeTiers.length; ++i) {
            try IV3Quoter(quoter).quoteExactInputSingle{gas: 400_000}(
                IV3Quoter.Params(tokenIn, tokenOut, amountIn, feeTiers[i], 0)
            ) returns (uint256 out, uint160, uint32, uint256) {
                if (out > amountOut) { amountOut = out; fee = feeTiers[i]; }
            } catch {}
        }
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint24 fee)
        external nonReentrant returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut || tokenIn == address(0) || tokenOut == address(0) ||
            amountIn == 0 || amountIn > uint256(type(int256).max)) revert InvalidSwap();
        bool supported;
        for (uint256 i; i < feeTiers.length; ++i) if (feeTiers[i] == fee) supported = true;
        if (!supported) revert InvalidSwap();
        address pool = IDirectV3Factory(factory).getPool(tokenIn, tokenOut, fee);
        if (pool.code.length == 0) revert InvalidSwap();
        IERC20 input = IERC20(tokenIn); IERC20 output = IERC20(tokenOut);
        uint256 inputBefore = input.balanceOf(address(this));
        uint256 outputBefore = output.balanceOf(address(this));
        uint256 callerInputBefore = input.balanceOf(msg.sender);
        input.safeTransferFrom(msg.sender, address(this), amountIn);
        if (input.balanceOf(address(this)) != inputBefore + amountIn) revert UnsupportedToken();
        bool direction = tokenIn < tokenOut;
        expectedPool = pool; expectedInput = tokenIn; expectedAmount = amountIn; expectedDirection = direction;
        (int256 delta0, int256 delta1) = IDirectV3Pool(pool).swap(address(this), direction, int256(amountIn),
            direction ? 4295128740 : 1461446703485210103287273052203988822378723970341, "");
        if (expectedPool != address(0) || expectedAmount != 0) revert CallbackRejected();
        delete expectedInput; delete expectedDirection;
        int256 spent = direction ? delta0 : delta1;
        int256 received = direction ? delta1 : delta0;
        if (spent != int256(amountIn) || received >= 0 || received == type(int256).min) revert InvalidSwap();
        if (input.balanceOf(address(this)) != inputBefore) revert UnsupportedToken();
        amountOut = output.balanceOf(address(this)) - outputBefore;
        if (amountOut != uint256(-received) || amountOut == 0 || amountOut < minOut) revert InvalidSwap();
        uint256 recipientBefore = output.balanceOf(msg.sender);
        output.safeTransfer(msg.sender, amountOut);
        if (output.balanceOf(msg.sender) != recipientBefore + amountOut ||
            output.balanceOf(address(this)) != outputBefore || input.balanceOf(address(this)) != inputBefore ||
            input.balanceOf(msg.sender) + amountIn != callerInputBefore) revert UnsupportedToken();
    }

    function uniswapV3SwapCallback(int256 delta0, int256 delta1, bytes calldata) external {
        if (pancakeCallback) revert CallbackRejected();
        _pay(delta0, delta1);
    }
    function pancakeV3SwapCallback(int256 delta0, int256 delta1, bytes calldata) external {
        if (!pancakeCallback) revert CallbackRejected();
        _pay(delta0, delta1);
    }
    function _pay(int256 delta0, int256 delta1) private {
        if (msg.sender != expectedPool || expectedPool == address(0)) revert CallbackRejected();
        int256 owed = expectedDirection ? delta0 : delta1;
        int256 other = expectedDirection ? delta1 : delta0;
        if (owed <= 0 || uint256(owed) != expectedAmount || other >= 0) revert CallbackRejected();
        IERC20 input = IERC20(expectedInput);
        // Consume authorization before the token transfer: repeated callbacks and token reentry fail.
        delete expectedPool; delete expectedAmount;
        uint256 beforeBalance = input.balanceOf(msg.sender);
        input.safeTransfer(msg.sender, uint256(owed));
        if (input.balanceOf(msg.sender) != beforeBalance + uint256(owed)) revert UnsupportedToken();
    }
}
