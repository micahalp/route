// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseAdapter} from "./BaseAdapter.sol";

interface IV2Router {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function swapExactTokensForTokens(uint256 amountIn, uint256 minOut, address[] calldata path, address to, uint256 deadline)
        external returns (uint256[] memory);
}

/// @notice Works with verified Uniswap V2-compatible routers, including their own fee formula.
contract V2Adapter is BaseAdapter {
    constructor(string memory label, address router) BaseAdapter(label, router) {}

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut, uint24 fee) {
        if (tokenIn == tokenOut || amountIn == 0) return (0, 0);
        try IV2Router(dexRouter).getAmountsOut{gas: 150_000}(amountIn, _path(tokenIn, tokenOut)) returns (uint256[] memory amounts) {
            if (amounts.length == 2) amountOut = amounts[1];
        } catch {}
        fee = 0;
    }

    function _execute(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint24 fee) internal override {
        if (fee != 0) revert InvalidSwap();
        IV2Router(dexRouter).swapExactTokensForTokens(amountIn, minOut, _path(tokenIn, tokenOut), address(this), block.timestamp);
    }

    function _path(address a, address b) private pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = a;
        path[1] = b;
    }
}
