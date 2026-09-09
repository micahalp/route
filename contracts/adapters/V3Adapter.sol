// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseAdapter} from "./BaseAdapter.sol";

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
    address public immutable quoter;
    uint24[] public feeTiers;

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
        IV3Router(dexRouter)
            .exactInputSingle(
                IV3Router.Params(tokenIn, tokenOut, fee, address(this), amountIn, minOut, 0)
            );
    }
}
