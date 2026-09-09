// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {BaseAdapter} from "./BaseAdapter.sol";

interface ICLFactory {
    function getPool(address, address, uint24) external view returns (address);
}

interface ICLRouter {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(Params calldata) external payable returns (uint256);
}

/// @notice GIGA's deadline-bearing concentrated-liquidity router (not Router02 ABI).
contract CLAdapter is BaseAdapter {
    ICLFactory public immutable factory;

    constructor(address router, address factory_) BaseAdapter("GIGA CL", router) {
        if (factory_.code.length == 0) {
            revert InvalidConfiguration();
        }
        factory = ICLFactory(factory_);
    }

    // Quotes are supplied by the offchain engine using the canonical quoter.
    function quote(address, address, uint256) external pure returns (uint256, uint24) {
        return (0, 0);
    }

    function _execute(address input, address output, uint256 amount, uint256 minimum, uint24 fee)
        internal
        override
    {
        if (fee >= 1_000_000 || factory.getPool(input, output, fee) == address(0)) {
            revert InvalidSwap();
        }
        ICLRouter(dexRouter)
            .exactInputSingle(
                ICLRouter.Params(
                    input, output, fee, address(this), block.timestamp, amount, minimum, 0
                )
            );
    }
}
