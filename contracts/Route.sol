// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRouteAdapter} from "./interfaces/IRouteAdapter.sol";

interface IWrappedNative is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice Immutable exact-input aggregator. Quotes and route selection run entirely onchain.
/// @dev No owner, fees, upgrades, arbitrary calldata, or persistent approvals. No fee-on-transfer/rebasing tokens.
contract Route is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Leg {
        address adapter;
        uint24 fee;
    }

    struct Quote {
        uint256 amountOut;
        address intermediate;
        Leg first;
        Leg second;
    }
    IWrappedNative public immutable wrappedNative;
    address[] public adapters;
    address[] public connectors;
    uint256 public constant ADAPTER_QUOTE_GAS = 1_850_000;

    error InvalidConfiguration();
    error InvalidPair();
    error InvalidAmount();
    error InvalidRecipient();
    error DeadlineExpired();
    error InvalidValue();
    error NoRoute();
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error UnsupportedToken();
    error NativeTransferFailed();

    event Swapped(
        address indexed sender,
        address indexed recipient,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address intermediate,
        address firstAdapter,
        uint24 firstFee,
        address secondAdapter,
        uint24 secondFee
    );

    constructor(address wrapped, address[] memory venues, address[] memory bridges) {
        if (
            wrapped.code.length == 0 || venues.length == 0 || venues.length > 6
                || bridges.length > 3
        ) {
            revert InvalidConfiguration();
        }
        for (uint256 i; i < venues.length; ++i) {
            if (venues[i].code.length == 0) {
                revert InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (venues[j] == venues[i]) {
                    revert InvalidConfiguration();
                }
            }
        }
        for (uint256 i; i < bridges.length; ++i) {
            if (bridges[i].code.length == 0) {
                revert InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (bridges[j] == bridges[i]) {
                    revert InvalidConfiguration();
                }
            }
        }
        wrappedNative = IWrappedNative(wrapped);
        adapters = venues;
        connectors = bridges;
    }

    receive() external payable {
        if (msg.sender != address(wrappedNative)) {
            revert InvalidValue();
        }
    }

    function configuration()
        external
        view
        returns (address wrapped, address[] memory venues, address[] memory bridges)
    {
        return (address(wrappedNative), adapters, connectors);
    }

    /// @notice Call via eth_call for a free simulation. V3 quoters prevent a Solidity view modifier.
    function quote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        nonReentrant
        returns (Quote memory)
    {
        (address input, address output) = _pair(tokenIn, tokenOut, amountIn);
        return _find(input, output, amountIn);
    }

    /// @notice A zero token address denotes native ETH. The chosen path is recomputed in this transaction.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }
        if (recipient == address(0) || recipient == address(this)) {
            revert InvalidRecipient();
        }
        if (minOut == 0) {
            revert InvalidAmount();
        }
        (address input, address output) = _pair(tokenIn, tokenOut, amountIn);
        if (msg.value != (tokenIn == address(0) ? amountIn : 0)) {
            revert InvalidValue();
        }
        uint256 inputBefore = IERC20(input).balanceOf(address(this));
        uint256 outputBefore = IERC20(output).balanceOf(address(this));
        if (tokenIn == address(0)) {
            wrappedNative.deposit{value: amountIn}();
        } else {
            IERC20(input).safeTransferFrom(msg.sender, address(this), amountIn);
        }
        if (IERC20(input).balanceOf(address(this)) != inputBefore + amountIn) {
            revert UnsupportedToken();
        }

        Quote memory best = _find(input, output, amountIn);
        if (best.amountOut < minOut) {
            revert SlippageExceeded(best.amountOut, minOut);
        }
        if (best.intermediate == address(0)) {
            _execute(best.first, input, output, amountIn, minOut);
        } else {
            uint256 bridgeBefore = IERC20(best.intermediate).balanceOf(address(this));
            uint256 bridgeAmount = _execute(best.first, input, best.intermediate, amountIn, 1);
            _execute(best.second, best.intermediate, output, bridgeAmount, minOut);
            if (IERC20(best.intermediate).balanceOf(address(this)) != bridgeBefore) {
                revert UnsupportedToken();
            }
        }
        if (IERC20(input).balanceOf(address(this)) != inputBefore) {
            revert UnsupportedToken();
        }
        amountOut = IERC20(output).balanceOf(address(this)) - outputBefore;
        if (amountOut < minOut) {
            revert SlippageExceeded(amountOut, minOut);
        }
        if (tokenOut == address(0)) {
            wrappedNative.withdraw(amountOut);
            (bool sent,) = recipient.call{value: amountOut}("");
            if (!sent) {
                revert NativeTransferFailed();
            }
        } else {
            uint256 recipientBefore = IERC20(output).balanceOf(recipient);
            IERC20(output).safeTransfer(recipient, amountOut);
            if (IERC20(output).balanceOf(recipient) != recipientBefore + amountOut) {
                revert UnsupportedToken();
            }
        }
        emit Swapped(
            msg.sender,
            recipient,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            best.intermediate,
            best.first.adapter,
            best.first.fee,
            best.second.adapter,
            best.second.fee
        );
    }

    function _pair(address tokenIn, address tokenOut, uint256 amountIn)
        private
        view
        returns (address input, address output)
    {
        input = tokenIn == address(0) ? address(wrappedNative) : tokenIn;
        output = tokenOut == address(0) ? address(wrappedNative) : tokenOut;
        if (input == output || input.code.length == 0 || output.code.length == 0) {
            revert InvalidPair();
        }
        if (amountIn == 0) {
            revert InvalidAmount();
        }
    }

    function _find(address input, address output, uint256 amountIn)
        private
        returns (Quote memory best)
    {
        (best.amountOut, best.first) = _edge(input, output, amountIn);
        for (uint256 i; i < connectors.length; ++i) {
            address bridge = connectors[i];
            if (bridge == input || bridge == output) {
                continue;
            }
            (uint256 firstOut, Leg memory first) = _edge(input, bridge, amountIn);
            if (firstOut == 0) {
                continue;
            }
            (uint256 lastOut, Leg memory second) = _edge(bridge, output, firstOut);
            if (lastOut > best.amountOut) {
                best = Quote(lastOut, bridge, first, second);
            }
        }
        if (best.amountOut == 0) {
            revert NoRoute();
        }
    }

    function _edge(address input, address output, uint256 amountIn)
        private
        returns (uint256 bestOut, Leg memory leg)
    {
        for (uint256 i; i < adapters.length; ++i) {
            try IRouteAdapter(adapters[i]).quote{gas: ADAPTER_QUOTE_GAS}(
                input, output, amountIn
            ) returns (
                uint256 candidate, uint24 fee
            ) {
                if (candidate > bestOut) {
                    bestOut = candidate;
                    leg = Leg(adapters[i], fee);
                }
            } catch {}
        }
    }

    function _execute(
        Leg memory leg,
        address input,
        address output,
        uint256 amountIn,
        uint256 minOut
    ) private returns (uint256 amountOut) {
        uint256 beforeOutput = IERC20(output).balanceOf(address(this));
        IERC20(input).forceApprove(leg.adapter, amountIn);
        IRouteAdapter(leg.adapter).swap(input, output, amountIn, minOut, leg.fee);
        IERC20(input).forceApprove(leg.adapter, 0);
        amountOut = IERC20(output).balanceOf(address(this)) - beforeOutput;
        if (amountOut < minOut) {
            revert SlippageExceeded(amountOut, minOut);
        }
    }
}
