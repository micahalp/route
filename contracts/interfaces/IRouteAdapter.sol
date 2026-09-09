// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IRouteAdapter {
    function name() external view returns (string memory);
    // Not view: concentrated-liquidity quoters simulate swaps and revert internally.
    function quote(address tokenIn, address tokenOut, uint256 amountIn)
        external returns (uint256 amountOut, uint24 fee);
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint24 fee)
        external returns (uint256 amountOut);
}
