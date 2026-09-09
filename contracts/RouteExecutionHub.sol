// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IRouteAdapter} from "./interfaces/IRouteAdapter.sol";
import {V4Adapter} from "./adapters/V4Adapter.sol";
import {RouteExecutor, IExecutorWrapped} from "./RouteExecutor.sol";

/// @notice Single-layer settlement for verified adapter plans and one immutable
/// upstream aggregator. Both paths charge 15 bps once on actual combined output.
/// @dev No upgrades, arbitrary targets, recovery functions or retained approvals.
/// Administration can only redirect future fees or transfer itself in two steps.
contract RouteExecutionHub is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    uint256 public constant FEE_BPS = 15;
    IExecutorWrapped public immutable wrappedNative;
    address public immutable v4Adapter;
    address public immutable aggregator;
    bytes4 public immutable swapSelector;
    mapping(address => bool) public allowedAdapter;
    address public feeRecipient;
    bool private acceptingNative;

    error InvalidRoute();
    error InvalidAmount();
    error DeadlineExpired();
    error UnsupportedToken();
    error SlippageExceeded();
    error UpstreamReverted();
    error NativeTransferFailed();
    error InvalidFeeRecipient();
    error RenounceDisabled();
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event FeePaid(
        address indexed sender,
        address indexed recipient,
        address indexed token,
        uint256 grossAmountOut,
        uint256 feeAmount
    );
    event Swapped(
        address indexed sender,
        address indexed recipient,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 routeHash
    );
    event Swapped(
        address indexed sender,
        address indexed recipient,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(
        address wrapped,
        address[] memory adapters,
        address v4,
        address upstream,
        bytes4 selector,
        address admin,
        address treasury
    ) Ownable(admin) {
        if (
            wrapped.code.length == 0 || upstream.code.length == 0 || adapters.length == 0
                || adapters.length > 16 || selector == bytes4(0)
        ) {
            revert InvalidRoute();
        }
        wrappedNative = IExecutorWrapped(wrapped);
        aggregator = upstream;
        swapSelector = selector;
        for (uint256 i; i < adapters.length; ++i) {
            if (adapters[i].code.length == 0 || allowedAdapter[adapters[i]]) {
                revert InvalidRoute();
            }
            allowedAdapter[adapters[i]] = true;
        }
        if (v4 != address(0) && !allowedAdapter[v4]) {
            revert InvalidRoute();
        }
        v4Adapter = v4;
        _setFeeRecipient(treasury);
    }

    receive() external payable {
        // Upstream executors can deliver native output themselves. This window
        // exists only inside the nonReentrant upstream swap, never while idle.
        if (msg.sender != address(wrappedNative) && !acceptingNative) {
            revert InvalidRoute();
        }
    }

    function setFeeRecipient(address treasury) external onlyOwner {
        _setFeeRecipient(treasury);
    }

    function _setFeeRecipient(address treasury) private {
        if (
            treasury == address(0) || treasury == address(this) || treasury == aggregator
                || treasury == address(wrappedNative) || allowedAdapter[treasury]
        ) {
            revert InvalidFeeRecipient();
        }
        emit FeeRecipientUpdated(feeRecipient, treasury);
        feeRecipient = treasury;
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function feeFor(uint256 gross) public pure returns (uint256) {
        return Math.mulDiv(gross, FEE_BPS, 10_000);
    }

    function grossForNet(uint256 net) public pure returns (uint256) {
        return net == 0 ? 0 : Math.mulDiv(net - 1, 10_000, 10_000 - FEE_BPS) + 1;
    }

    function _balance(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _check(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) private view {
        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }
        address input = tokenIn == address(0) ? address(wrappedNative) : tokenIn;
        address output = tokenOut == address(0) ? address(wrappedNative) : tokenOut;
        if (
            input == output || input.code.length == 0 || output.code.length == 0
                || recipient == address(0) || recipient == address(this)
        ) {
            revert InvalidRoute();
        }
        if (amountIn == 0 || minOut == 0 || msg.value != (tokenIn == address(0) ? amountIn : 0)) {
            revert InvalidAmount();
        }
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline,
        RouteExecutor.Branch[] calldata branches
    ) external payable nonReentrant returns (uint256 amountOut) {
        _check(tokenIn, tokenOut, amountIn, minOut, recipient, deadline);
        address treasury = feeRecipient;
        address input = tokenIn == address(0) ? address(wrappedNative) : tokenIn;
        address output = tokenOut == address(0) ? address(wrappedNative) : tokenOut;
        if (branches.length == 0 || branches.length > 3) {
            revert InvalidRoute();
        }
        uint256 sum;
        for (uint256 b; b < branches.length; ++b) {
            RouteExecutor.Branch calldata branch = branches[b];
            if (branch.amountIn == 0 || branch.legs.length == 0 || branch.legs.length > 3) {
                revert InvalidRoute();
            }
            sum += branch.amountIn;
            address previous = input;
            for (uint256 h; h < branch.legs.length; ++h) {
                RouteExecutor.Leg calldata leg = branch.legs[h];
                if (
                    !allowedAdapter[leg.adapter] || leg.tokenOut.code.length == 0
                        || leg.tokenOut == input || leg.tokenOut == previous
                ) {
                    revert InvalidRoute();
                }
                for (uint256 j; j < h; ++j) {
                    if (branch.legs[j].tokenOut == leg.tokenOut) {
                        revert InvalidRoute();
                    }
                }
                if (
                    leg.adapter != v4Adapter
                        && (leg.tickSpacing != 0 || leg.hooks != address(0) || leg.nativePool)
                ) {
                    revert InvalidRoute();
                }
                previous = leg.tokenOut;
            }
            if (previous != output) {
                revert InvalidRoute();
            }
        }
        if (sum != amountIn) {
            revert InvalidAmount();
        }
        uint256 beforeInput = IERC20(input).balanceOf(address(this));
        uint256 beforeOutput = IERC20(output).balanceOf(address(this));
        if (tokenIn == address(0)) {
            wrappedNative.deposit{value: amountIn}();
        } else {
            IERC20(input).safeTransferFrom(msg.sender, address(this), amountIn);
        }
        if (IERC20(input).balanceOf(address(this)) != beforeInput + amountIn) {
            revert UnsupportedToken();
        }
        for (uint256 b; b < branches.length; ++b) {
            address current = input;
            uint256 amount = branches[b].amountIn;
            for (uint256 h; h < branches[b].legs.length; ++h) {
                RouteExecutor.Leg calldata leg = branches[b].legs[h];
                uint256 startInput = IERC20(current).balanceOf(address(this));
                uint256 startOutput = IERC20(leg.tokenOut).balanceOf(address(this));
                IERC20(current).forceApprove(leg.adapter, amount);
                if (leg.adapter == v4Adapter) {
                    V4Adapter(payable(v4Adapter))
                        .swap(
                            current,
                            leg.tokenOut,
                            amount,
                            leg.fee,
                            leg.tickSpacing,
                            leg.hooks,
                            leg.nativePool
                        );
                } else {
                    IRouteAdapter(leg.adapter).swap(current, leg.tokenOut, amount, 1, leg.fee);
                }
                IERC20(current).forceApprove(leg.adapter, 0);
                if (IERC20(current).balanceOf(address(this)) != startInput - amount) {
                    revert UnsupportedToken();
                }
                amount = IERC20(leg.tokenOut).balanceOf(address(this)) - startOutput;
                if (amount == 0) {
                    revert SlippageExceeded();
                }
                current = leg.tokenOut;
            }
        }
        if (IERC20(input).balanceOf(address(this)) != beforeInput) {
            revert UnsupportedToken();
        }
        uint256 gross = IERC20(output).balanceOf(address(this)) - beforeOutput;
        if (tokenOut == address(0)) {
            wrappedNative.withdraw(gross);
        }
        amountOut = _payOutput(tokenOut, gross, minOut, recipient, treasury);
        if (IERC20(output).balanceOf(address(this)) != beforeOutput) {
            revert UnsupportedToken();
        }
        emit Swapped(
            msg.sender,
            recipient,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            keccak256(abi.encode(branches))
        );
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline,
        bytes calldata data
    ) external payable nonReentrant returns (uint256 amountOut) {
        _check(tokenIn, tokenOut, amountIn, minOut, recipient, deadline);
        if (data.length < 4 || data.length > 65536 || bytes4(data[:4]) != swapSelector) {
            revert InvalidRoute();
        }
        address treasury = feeRecipient;
        uint256 beforeInput = _balance(tokenIn) - msg.value;
        uint256 beforeOutput = _balance(tokenOut);
        if (tokenIn != address(0)) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            if (_balance(tokenIn) != beforeInput + amountIn) {
                revert UnsupportedToken();
            }
            IERC20(tokenIn).forceApprove(aggregator, amountIn);
        }
        acceptingNative = true;
        // Fixed target and selector, no delegatecall; ignore upstream return data.
        (bool ok,) = aggregator.call{value: msg.value}(data);
        acceptingNative = false;
        if (!ok) {
            revert UpstreamReverted();
        }
        if (tokenIn != address(0)) {
            IERC20(tokenIn).forceApprove(aggregator, 0);
        }
        if (_balance(tokenIn) != beforeInput) {
            revert UnsupportedToken();
        }
        uint256 gross = _balance(tokenOut) - beforeOutput;
        amountOut = _payOutput(tokenOut, gross, minOut, recipient, treasury);
        if (_balance(tokenOut) != beforeOutput) {
            revert UnsupportedToken();
        }
        emit Swapped(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _payOutput(
        address token,
        uint256 gross,
        uint256 minOut,
        address recipient,
        address treasury
    ) private returns (uint256 amountOut) {
        uint256 fee = feeFor(gross);
        amountOut = gross - fee;
        if (amountOut < minOut) {
            revert SlippageExceeded();
        }
        if (fee != 0) {
            _pay(token, treasury, fee);
        }
        _pay(token, recipient, amountOut);
        emit FeePaid(msg.sender, treasury, token, gross, fee);
    }

    function _pay(address token, address recipient, uint256 amount) private {
        if (token == address(0)) {
            (bool ok,) = recipient.call{value: amount}("");
            if (!ok) {
                revert NativeTransferFailed();
            }
        } else {
            uint256 beforeRecipient = IERC20(token).balanceOf(recipient);
            IERC20(token).safeTransfer(recipient, amount);
            if (IERC20(token).balanceOf(recipient) != beforeRecipient + amount) {
                revert UnsupportedToken();
            }
        }
    }
}
