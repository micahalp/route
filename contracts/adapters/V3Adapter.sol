// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseAdapter} from "./BaseAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IV3NativePayments {
    function WETH9() external view returns (address);
    function refundETH() external payable;
}

interface IV3WrappedNative {
    function deposit() external payable;
}

interface IV3Quoter {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(Params calldata params)
        external
        returns (uint256, uint160, uint32, uint256);
}

interface IV3Router {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(Params calldata params) external payable returns (uint256);
}

/// @notice Uniswap V3 SwapRouter02 + QuoterV2. Not compatible with the older deadline-bearing router ABI.
contract V3Adapter is BaseAdapter {
    using SafeERC20 for IERC20;
    address public immutable quoter;
    uint24[] public feeTiers;

    receive() external payable {
        if (msg.sender != dexRouter) {
            revert InvalidSwap();
        }
    }

    // Keep unsolicited router funds at the router, denominated in WETH instead
    // of ETH. Refunding them to our caller could violate an outer exact-input
    // invariant. Router WETH remains recoverable through its public sweepToken.
    function _normalizeRouterNative(address tokenIn) private {
        if (dexRouter.balance == 0) {
            return;
        }
        if (IV3NativePayments(dexRouter).WETH9() != tokenIn) {
            return;
        }
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(tokenIn).balanceOf(address(this));
        IV3NativePayments(dexRouter).refundETH();
        uint256 refunded = address(this).balance - nativeBefore;
        if (refunded != 0) {
            IV3WrappedNative(tokenIn).deposit{value: refunded}();
            if (IERC20(tokenIn).balanceOf(address(this)) != tokenBefore + refunded) {
                revert UnsupportedToken();
            }
            IERC20(tokenIn).safeTransfer(dexRouter, refunded);
        }
        if (
            address(this).balance != nativeBefore || dexRouter.balance != 0
                || IERC20(tokenIn).balanceOf(address(this)) != tokenBefore
        ) {
            revert UnsupportedToken();
        }
    }

    constructor(string memory label, address router, address quoteContract, uint24[] memory fees)
        BaseAdapter(label, router)
    {
        if (quoteContract.code.length == 0 || fees.length == 0 || fees.length > 4) {
            revert InvalidConfiguration();
        }
        for (uint256 i; i < fees.length; ++i) {
            if (fees[i] == 0 || fees[i] >= 1_000_000) {
                revert InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (fees[j] == fees[i]) {
                    revert InvalidConfiguration();
                }
            }
        }
        quoter = quoteContract;
        feeTiers = fees;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        nonReentrant
        returns (uint256 amountOut, uint24 fee)
    {
        if (tokenIn == tokenOut || amountIn == 0) {
            return (0, 0);
        }
        for (uint256 i; i < feeTiers.length; ++i) {
            uint24 candidate = feeTiers[i];
            try IV3Quoter(quoter).quoteExactInputSingle{gas: 400_000}(
                IV3Quoter.Params(tokenIn, tokenOut, amountIn, candidate, 0)
            ) returns (
                uint256 result, uint160, uint32, uint256
            ) {
                if (result > amountOut) {
                    amountOut = result;
                    fee = candidate;
                }
            } catch {}
        }
    }

    function _execute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint24 fee
    ) internal override {
        bool supported;
        for (uint256 i; i < feeTiers.length; ++i) {
            if (feeTiers[i] == fee) {
                supported = true;
            }
        }
        if (!supported) {
            revert InvalidSwap();
        }
        _normalizeRouterNative(tokenIn);
        IV3Router(dexRouter)
            .exactInputSingle(
                IV3Router.Params(tokenIn, tokenOut, fee, address(this), amountIn, minOut, 0)
            );
    }
}
