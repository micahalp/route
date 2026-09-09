// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {RouteExecutor} from "./RouteExecutor.sol";
import {RouteMetaExecutor} from "./RouteMetaExecutor.sol";

/// @notice Fixed 15 bps output fee over two immutable settlement engines.
/// @dev The owner can only redirect future fees or transfer administration.
/// No upgrades, arbitrary targets, withdrawals, input fees or retained approvals.
contract RouteFeeExecutor is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    uint256 public constant FEE_BPS = 15;
    RouteExecutor public immutable routeExecutor;
    RouteMetaExecutor public immutable metaExecutor;
    address public feeRecipient;

    error InvalidSwap();
    error DeadlineExpired();
    error UnsupportedToken();
    error SlippageExceeded();
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

    struct Settlement {
        uint256 inputBalance;
        uint256 outputBalance;
        address treasury;
    }

    constructor(address route, address meta, address admin, address treasury) Ownable(admin) {
        if (route.code.length == 0 || meta.code.length == 0 || route == meta) {
            revert InvalidSwap();
        }
        routeExecutor = RouteExecutor(payable(route));
        metaExecutor = RouteMetaExecutor(payable(meta));
        _setFeeRecipient(treasury);
    }

    receive() external payable {
        if (msg.sender != address(routeExecutor) && msg.sender != address(metaExecutor)) {
            revert InvalidSwap();
        }
    }

    function setFeeRecipient(address treasury) external onlyOwner {
        _setFeeRecipient(treasury);
    }

    function _setFeeRecipient(address treasury) private {
        if (
            treasury == address(0) || treasury == address(this)
                || treasury == address(routeExecutor) || treasury == address(metaExecutor)
        ) {
            revert InvalidFeeRecipient();
        }
        emit FeeRecipientUpdated(feeRecipient, treasury);
        feeRecipient = treasury;
    }

    // Keep administration recoverable through the two-step ownership handoff.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function allowedAdapter(address adapter) external view returns (bool) {
        return routeExecutor.allowedAdapter(adapter);
    }

    function wrappedNative() external view returns (address) {
        return address(routeExecutor.wrappedNative());
    }

    function feeFor(uint256 gross) public pure returns (uint256) {
        return Math.mulDiv(gross, FEE_BPS, 10_000);
    }

    /// @dev Smallest gross amount whose net (gross - floor(gross * 15 / 10000)) reaches net.
    function grossForNet(uint256 net) public pure returns (uint256) {
        return net == 0 ? 0 : Math.mulDiv(net - 1, 10_000, 10_000 - FEE_BPS) + 1;
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
        Settlement memory state = _start(
            tokenIn, tokenOut, amountIn, minOut, recipient, deadline, address(routeExecutor)
        );
        routeExecutor.swap{value: msg.value}(
            tokenIn, tokenOut, amountIn, grossForNet(minOut), address(this), deadline, branches
        );
        amountOut = _finish(state, tokenIn, tokenOut, minOut, recipient, address(routeExecutor));
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
        Settlement memory state = _start(
            tokenIn, tokenOut, amountIn, minOut, recipient, deadline, address(metaExecutor)
        );
        metaExecutor.swap{value: msg.value}(
            tokenIn, tokenOut, amountIn, grossForNet(minOut), address(this), deadline, data
        );
        amountOut = _finish(state, tokenIn, tokenOut, minOut, recipient, address(metaExecutor));
        emit Swapped(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _balance(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _start(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline,
        address engine
    ) private returns (Settlement memory state) {
        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }
        if (
            tokenIn == tokenOut || amountIn == 0 || minOut == 0 || recipient == address(0)
                || recipient == address(this) || recipient == address(routeExecutor)
                || recipient == address(metaExecutor)
                || msg.value != (tokenIn == address(0) ? amountIn : 0)
        ) {
            revert InvalidSwap();
        }
        if (
            (tokenIn != address(0) && tokenIn.code.length == 0)
                || (tokenOut != address(0) && tokenOut.code.length == 0)
        ) {
            revert InvalidSwap();
        }
        // Snapshot before any untrusted token, adapter or recipient interaction.
        state.treasury = feeRecipient;
        state.inputBalance = _balance(tokenIn) - msg.value;
        state.outputBalance = _balance(tokenOut);
        if (tokenIn != address(0)) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            if (_balance(tokenIn) != state.inputBalance + amountIn) {
                revert UnsupportedToken();
            }
            IERC20(tokenIn).forceApprove(engine, amountIn);
        }
    }

    function _finish(
        Settlement memory state,
        address tokenIn,
        address tokenOut,
        uint256 minOut,
        address recipient,
        address engine
    ) private returns (uint256 amountOut) {
        if (tokenIn != address(0)) {
            IERC20(tokenIn).forceApprove(engine, 0);
        }
        if (_balance(tokenIn) != state.inputBalance) {
            revert UnsupportedToken();
        }
        uint256 gross = _balance(tokenOut) - state.outputBalance;
        uint256 fee = feeFor(gross);
        amountOut = gross - fee;
        if (amountOut < minOut) {
            revert SlippageExceeded();
        }
        if (fee != 0) {
            _pay(tokenOut, state.treasury, fee);
        }
        _pay(tokenOut, recipient, amountOut);
        if (_balance(tokenOut) != state.outputBalance) {
            revert UnsupportedToken();
        }
        emit FeePaid(msg.sender, state.treasury, tokenOut, gross, fee);
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
