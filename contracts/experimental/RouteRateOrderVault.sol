// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOrderSwapAdapter} from "./RouteOrderVault.sol";

/// @notice Experimental exact-input ERC20 orders; no oracle, fees, admin or upgrades.
/// @dev Stop detection is explicitly entrusted to the per-order keeper. Trigger rate is
/// a recorded instruction, NOT an onchain price assertion. Floors are enforced onchain.
contract RouteRateOrderVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    enum Kind {
        LimitBuy,
        TakeProfit,
        StopLoss,
        Bracket
    }
    enum State {
        Missing,
        Pending,
        Entered,
        Completed,
        Cancelled
    }
    enum Leg {
        Entry,
        TakeProfit,
        StopLoss
    }

    struct Terms {
        Kind kind;
        address market;
        address settlement;
        uint256 amount;
        uint256 entryMinimum;
        // Settlement base units per market base unit, scaled 1e18.
        uint256 takeProfitRate;
        uint256 stopTriggerRate;
        uint256 stopMinimumRate;
        address keeper;
        uint64 expiresAt;
    }

    struct Order {
        address owner;
        State state;
        uint256 held;
        Terms terms;
    }
    IOrderSwapAdapter public immutable adapter;
    uint256 public nextId;
    mapping(uint256 => Order) private orders;
    error InvalidOrder();
    error NotOwner();
    error NotEligible();
    error UnauthorizedKeeper();
    error TransferMismatch();
    error MinimumNotMet();
    event Created(uint256 indexed id, address indexed owner);
    event Filled(uint256 indexed id, Leg leg, uint256 amountIn, uint256 amountOut);
    event Cancelled(uint256 indexed id, address token, uint256 amount);

    constructor(address swapAdapter) {
        if (swapAdapter.code.length == 0) {
            revert InvalidOrder();
        }
        adapter = IOrderSwapAdapter(swapAdapter);
    }

    function getOrder(uint256 id) external view returns (Order memory) {
        return orders[id];
    }

    function create(Terms calldata t) external nonReentrant returns (uint256 id) {
        if (
            t.market == t.settlement || t.market.code.length == 0 || t.settlement.code.length == 0
                || t.market == address(adapter) || t.settlement == address(adapter) || t.amount == 0
                || t.expiresAt <= block.timestamp || t.expiresAt > block.timestamp + 365 days
        ) {
            revert InvalidOrder();
        }
        bool buy = t.kind == Kind.LimitBuy || t.kind == Kind.Bracket;
        bool tp = t.kind == Kind.TakeProfit || t.kind == Kind.Bracket;
        bool sl = t.kind == Kind.StopLoss || t.kind == Kind.Bracket;
        if (
            (buy ? t.entryMinimum == 0 : t.entryMinimum != 0)
                || (tp ? t.takeProfitRate == 0 : t.takeProfitRate != 0)
                || (sl
                        ? t.keeper == address(0) || t.stopTriggerRate == 0 || t.stopMinimumRate == 0
                        || t.stopMinimumRate > t.stopTriggerRate
                        : t.keeper != address(0) || t.stopTriggerRate != 0 || t.stopMinimumRate != 0)
        ) {
            revert InvalidOrder();
        }
        if (t.kind == Kind.Bracket) {
            uint256 entryRate = Math.mulDiv(t.amount, 1e18, t.entryMinimum, Math.Rounding.Ceil);
            if (t.stopTriggerRate >= entryRate || t.takeProfitRate <= entryRate) {
                revert InvalidOrder();
            }
        }
        address token = buy ? t.settlement : t.market;
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), t.amount);
        if (IERC20(token).balanceOf(address(this)) != beforeBalance + t.amount) {
            revert TransferMismatch();
        }
        id = ++nextId;
        orders[id] = Order(msg.sender, State.Pending, t.amount, t);
        emit Created(id, msg.sender);
    }

    function cancel(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        if (o.owner != msg.sender) {
            revert NotOwner();
        }
        if (o.state != State.Pending && o.state != State.Entered) {
            revert NotEligible();
        }
        bool buy = o.terms.kind == Kind.LimitBuy || o.terms.kind == Kind.Bracket;
        address token = buy && o.state == State.Pending ? o.terms.settlement : o.terms.market;
        uint256 amount = o.held;
        o.state = State.Cancelled;
        o.held = 0;
        _deliver(token, o.owner, amount);
        emit Cancelled(id, token, amount);
    }

    function execution(uint256 id, Leg leg)
        public
        view
        returns (address input, address output, uint256 amount, uint256 minimum)
    {
        Order storage o = orders[id];
        Terms storage t = o.terms;
        if (
            (o.state != State.Pending && o.state != State.Entered) || block.timestamp >= t.expiresAt
        ) {
            revert NotEligible();
        }
        if (leg == Leg.Entry) {
            if (o.state != State.Pending || (t.kind != Kind.LimitBuy && t.kind != Kind.Bracket)) {
                revert NotEligible();
            }
            return (t.settlement, t.market, o.held, t.entryMinimum);
        }
        if (t.kind == Kind.Bracket ? o.state != State.Entered : o.state != State.Pending) {
            revert NotEligible();
        }
        uint256 rate;
        if (leg == Leg.TakeProfit) {
            if (t.kind != Kind.TakeProfit && t.kind != Kind.Bracket) {
                revert NotEligible();
            }
            rate = t.takeProfitRate;
        } else {
            if (t.kind != Kind.StopLoss && t.kind != Kind.Bracket) {
                revert NotEligible();
            }
            rate = t.stopMinimumRate;
        }
        return (t.market, t.settlement, o.held, Math.mulDiv(o.held, rate, 1e18, Math.Rounding.Ceil));
    }

    function execute(uint256 id, Leg leg, bytes calldata data)
        external
        nonReentrant
        returns (uint256 output)
    {
        if (data.length > 65536) {
            revert InvalidOrder();
        }
        Order storage o = orders[id];
        if (leg == Leg.StopLoss && msg.sender != o.terms.keeper) {
            revert UnauthorizedKeeper();
        }
        (address input, address out, uint256 amount, uint256 minimum) = execution(id, leg);
        uint256 beforeIn = IERC20(input).balanceOf(address(this));
        uint256 beforeOut = IERC20(out).balanceOf(address(this));
        o.state = State.Completed;
        o.held = 0;
        IERC20(input).forceApprove(address(adapter), amount);
        adapter.swap(input, out, amount, minimum, address(this), o.terms.expiresAt, data);
        IERC20(input).forceApprove(address(adapter), 0);
        if (IERC20(input).balanceOf(address(this)) != beforeIn - amount) {
            revert TransferMismatch();
        }
        output = IERC20(out).balanceOf(address(this)) - beforeOut;
        if (output < minimum) {
            revert MinimumNotMet();
        }
        if (leg == Leg.Entry && o.terms.kind == Kind.Bracket) {
            o.held = output;
            o.state = State.Entered;
        } else {
            _deliver(out, o.owner, output);
        }
        emit Filled(id, leg, amount, output);
    }

    function _deliver(address token, address owner, uint256 amount) private {
        uint256 beforeVault = IERC20(token).balanceOf(address(this));
        uint256 beforeOwner = IERC20(token).balanceOf(owner);
        IERC20(token).safeTransfer(owner, amount);
        if (
            IERC20(token).balanceOf(address(this)) != beforeVault - amount
                || IERC20(token).balanceOf(owner) != beforeOwner + amount
        ) {
            revert TransferMismatch();
        }
    }
}
