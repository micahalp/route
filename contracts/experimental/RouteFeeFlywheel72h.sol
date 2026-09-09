// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IFlywheelEscrow {
    function claim() external;
    function claim(uint256 amount) external;
    function claimToken(address token) external;
}
interface IFlywheelFactory {
    function transferCreatorFeeRecipient(address token, address recipient) external;
}
interface IFlywheelExecutor {
    struct Leg { address adapter; address tokenOut; uint24 fee; int24 tickSpacing; address hooks; bool nativePool; }
    struct Branch { uint256 amountIn; Leg[] legs; }
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut,
        address recipient, uint256 deadline, Branch[] calldata branches) external payable returns (uint256);
}

/// @notice Experimental Pons native-fee claimant. Not deployed or activated.
/// @dev Treasury-approved price floors are limit prices, not a market oracle.
/// Deployer has no privileges. No arbitrary target, recipient, approval or delegatecall.
contract RouteFeeFlywheel72h is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    address public immutable treasury;
    address public immutable operator;
    address public immutable token;
    address public immutable escrow;
    address public immutable factory;
    address public immutable executor;
    uint256 public immutable chainId;
    uint256 public constant BUY_BPS = 6500;
    uint256 public constant MAX_POLICY_DURATION = 3 days;
    bool public paused = true;
    uint256 public sequence;
    uint256 public lastRun;
    struct Policy {
        uint256 minClaim;
        uint256 maxClaim;
        uint256 remainingClaimsBudget;
        uint256 minTokensPerEth; // token base units per 1 ETH spent
        uint256 minInterval;
        uint256 expiresAt;
    }
    Policy public policy;
    error Unauthorized();
    error InvalidConfiguration();
    error Inactive();
    error InvalidBatch();
    error SlippageExceeded();
    error NativeTransferFailed();
    event PolicySet(Policy policy);
    event Paused();
    event Executed(uint256 indexed sequence, uint256 claimed, uint256 boughtWith, uint256 tokensOut, uint256 treasuryEth);
    event FeesHandedToTreasury();
    event Recovered(address indexed asset, uint256 amount);

    constructor(address safe_, address operator_, address token_, address escrow_, address factory_, address executor_) {
        if (safe_.code.length == 0 || operator_ == address(0) || token_.code.length == 0 ||
            escrow_.code.length == 0 || factory_.code.length == 0 || executor_.code.length == 0 ||
            safe_ == executor_ || safe_ == escrow_) revert InvalidConfiguration();
        treasury = safe_; operator = operator_; token = token_; escrow = escrow_;
        factory = factory_; executor = executor_; chainId = block.chainid;
    }
    modifier onlyTreasury() { if (msg.sender != treasury) revert Unauthorized(); _; }
    receive() external payable { if (msg.sender != escrow) revert Unauthorized(); }

    /// @notice Safe authorizes a bounded, expiring campaign; caller cannot lower its floor.
    function setPolicy(Policy calldata next) external onlyTreasury nonReentrant {
        if (next.minClaim < 2 || next.maxClaim < next.minClaim ||
            next.remainingClaimsBudget < next.minClaim || next.minTokensPerEth == 0 ||
            next.minInterval == 0 || next.expiresAt <= block.timestamp ||
            next.expiresAt > block.timestamp + MAX_POLICY_DURATION) revert InvalidConfiguration();
        policy = next; paused = false;
        emit PolicySet(next);
    }
    function pause() external onlyTreasury nonReentrant { paused = true; emit Paused(); }

    /// @notice Claim, buy and pay treasury atomically. Failure rolls the claim back too.
    /// @param expectedClaim Exact batch amount quoted offchain; other escrow credits remain unspent.
    function execute(uint256 expectedSequence, uint256 expectedClaim, uint256 minOut, uint256 deadline,
        IFlywheelExecutor.Branch[] calldata branches) external nonReentrant returns (uint256 received) {
        if (msg.sender != operator) revert Unauthorized();
        Policy memory p = policy;
        if (paused || block.chainid != chainId || block.timestamp > p.expiresAt) revert Inactive();
        if (expectedSequence != sequence || deadline < block.timestamp || deadline > p.expiresAt ||
            expectedClaim < p.minClaim || expectedClaim > p.maxClaim || expectedClaim > p.remainingClaimsBudget ||
            (lastRun != 0 && block.timestamp < lastRun + p.minInterval)) revert InvalidBatch();
        uint256 buyAmount = Math.mulDiv(expectedClaim, BUY_BPS, 10_000);
        uint256 floor = Math.mulDiv(buyAmount, p.minTokensPerEth, 1 ether, Math.Rounding.Ceil);
        if (minOut < floor || minOut == 0) revert SlippageExceeded();
        policy.remainingClaimsBudget -= expectedClaim;
        ++sequence; lastRun = block.timestamp;
        uint256 beforeEth = address(this).balance;
        IFlywheelEscrow(escrow).claim(expectedClaim);
        if (address(this).balance != beforeEth + expectedClaim) revert InvalidBatch();
        uint256 beforeTokens = IERC20(token).balanceOf(treasury);
        IFlywheelExecutor(executor).swap{value: buyAmount}(
            address(0), token, buyAmount, minOut, treasury, deadline, branches);
        received = IERC20(token).balanceOf(treasury) - beforeTokens;
        if (received < minOut) revert SlippageExceeded();
        uint256 treasuryAmount = expectedClaim - buyAmount; // rounding dust always goes to Safe
        _send(treasuryAmount);
        if (address(this).balance != beforeEth) revert InvalidBatch();
        emit Executed(sequence - 1, expectedClaim, buyAmount, received, treasuryAmount);
    }

    /// @notice Recover to the fixed Safe only, while paused. Also handles old vest ERC-20 claims.
    function recover(address asset, bool claimFirst) external onlyTreasury nonReentrant {
        if (!paused) revert Inactive();
        uint256 amount;
        if (asset == address(0)) {
            if (claimFirst) IFlywheelEscrow(escrow).claim();
            amount = address(this).balance; _send(amount);
        } else {
            if (claimFirst) IFlywheelEscrow(escrow).claimToken(asset);
            amount = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransfer(treasury, amount);
        }
        emit Recovered(asset, amount);
    }
    /// @notice Safe can exit the automation without stranding future creator income.
    function handoverFeesToTreasury() external onlyTreasury nonReentrant {
        if (!paused) revert Inactive();
        IFlywheelFactory(factory).transferCreatorFeeRecipient(token, treasury);
        emit FeesHandedToTreasury();
    }
    function _send(uint256 amount) private {
        (bool ok,) = payable(treasury).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }
}

