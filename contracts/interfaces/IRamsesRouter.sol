// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev ABI-only interoperability with the verified Robinhood Ramses CL router.
/// Pool identity is signed tickSpacing, not a Uniswap fee tier.
interface IRamsesRouter {
    struct Params {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(Params calldata params) external payable returns (uint256 amountOut);
    function deployer() external view returns (address);
    function WETH9() external view returns (address);
}

interface IRamsesFactory {
    function ramsesV3PoolDeployer() external view returns (address);
}
