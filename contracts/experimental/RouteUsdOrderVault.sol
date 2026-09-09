// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOrderPriceFeed, IOrderSwapAdapter} from "./RouteOrderVault.sol";

/// @notice Experimental USD targets with chosen ERC20 settlement. No fees or admin.
/// @dev Requires a reviewed immutable USD feed for the SETTLEMENT token, not every
/// market token. Executable full-size output enforces entry/TP. Stop observation
/// remains entrusted to the named keeper; only its USD floor is enforced here.
contract RouteUsdOrderVault is ReentrancyGuard {
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
        // USD per whole market token, fixed-point 18 decimals, NEVER token ratios.
        uint256 entryUsd;
        uint256 takeProfitUsd;
        uint256 stopUsd;
        uint16 stopSlippageBps;
        address keeper;
        uint64 expiresAt;
    }

    struct Order {
        address owner;
        State state;
        uint256 held;
        uint8 marketDecimals;
        uint8 settlementDecimals;
        Terms terms;
    }
    IOrderSwapAdapter public immutable adapter;
    IOrderPriceFeed public immutable feed;
    uint256 public immutable maxAge;
    uint256 public nextId;
    mapping(uint256 => Order) private orders;
    error InvalidOrder();
    error InvalidPrice();
    error NotEligible();
    error NotOwner();
    error UnauthorizedKeeper();
    error TransferMismatch();
    error MinimumNotMet();
    event Created(uint256 indexed id, address indexed owner);
    event Filled(
        uint256 indexed id,
        Leg leg,
        uint256 amountIn,
        uint256 amountOut,
        uint256 settlementUsd
    );
    event Cancelled(uint256 indexed id, address token, uint256 amount);

    constructor(address swapAdapter, address usdFeed, uint256 age) {
        if (swapAdapter.code.length == 0 || usdFeed.code.length == 0 || age == 0 || age > 1 hours) {
            revert InvalidOrder();
        }
        adapter = IOrderSwapAdapter(swapAdapter);
        feed = IOrderPriceFeed(usdFeed);
        maxAge = age;
    }

    function getOrder(uint256 id) external view returns (Order memory) {
        return orders[id];
    }

    function settlementPrice(address token) public view returns (uint256 value) {
        uint256 at;
        (value, at) = feed.price(token);
        if (value == 0 || at == 0 || at > block.timestamp || block.timestamp - at > maxAge) {
            revert InvalidPrice();
        }
    }

    function create(Terms calldata t) external nonReentrant returns (uint256 id) {
        if (
            t.market == t.settlement || t.market.code.length == 0 || t.settlement.code.length == 0
                || t.market == address(this) || t.settlement == address(this)
                || t.market == address(adapter) || t.settlement == address(adapter) || t.amount == 0
                || t.expiresAt <= block.timestamp || t.expiresAt > block.timestamp + 365 days
        ) {
            revert InvalidOrder();
        }
        bool buy = t.kind == Kind.LimitBuy || t.kind == Kind.Bracket;
        bool tp = t.kind == Kind.TakeProfit || t.kind == Kind.Bracket;
        bool sl = t.kind == Kind.StopLoss || t.kind == Kind.Bracket;
        if (
            (buy ? t.entryUsd == 0 : t.entryUsd != 0)
                || (tp ? t.takeProfitUsd == 0 : t.takeProfitUsd != 0)
                || (sl
                        ? t.stopUsd == 0 || t.keeper == address(0) || t.stopSlippageBps == 0
                        || t.stopSlippageBps > 500
                        : t.stopUsd != 0 || t.keeper != address(0) || t.stopSlippageBps != 0)
        ) {
            revert InvalidOrder();
        }
        if (t.kind == Kind.Bracket && (t.stopUsd >= t.entryUsd || t.takeProfitUsd <= t.entryUsd)) {
            revert InvalidOrder();
        }
        uint8 md = IERC20Metadata(t.market).decimals();
        uint8 sd = IERC20Metadata(t.settlement).decimals();
        if (md > 36 || sd > 36) {
            revert InvalidOrder();
        }
        settlementPrice(t.settlement); // Unsupported/stale settlement cannot accept deposits.
        address token = buy ? t.settlement : t.market;
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), t.amount);
        if (IERC20(token).balanceOf(address(this)) != beforeBalance + t.amount) {
            revert TransferMismatch();
        }
        id = ++nextId;
        orders[id] = Order(msg.sender, State.Pending, t.amount, md, sd, t);
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
        return _execution(id, leg, settlementPrice(orders[id].terms.settlement));
    }

    function _execution(uint256 id, Leg leg, uint256 usd)
        private
        view
        returns (address, address, uint256, uint256 minimum)
    {
        Order storage o = orders[id];
        Terms storage t = o.terms;
        if (
            (o.state != State.Pending && o.state != State.Entered) || block.timestamp >= t.expiresAt
        ) {
            revert NotEligible();
        }
        if (
            IERC20Metadata(t.market).decimals() != o.marketDecimals
                || IERC20Metadata(t.settlement).decimals() != o.settlementDecimals
        ) {
            revert InvalidOrder();
        }
        uint256 mu = 10 ** o.marketDecimals;
        uint256 su = 10 ** o.settlementDecimals;
        if (leg == Leg.Entry) {
            if (o.state != State.Pending || (t.kind != Kind.LimitBuy && t.kind != Kind.Bracket)) {
                revert NotEligible();
            }
            // Conservative double-ceil cannot authorize a price above the USD limit.
            uint256 costUsd = Math.mulDiv(o.held, usd, su, Math.Rounding.Ceil);
            minimum = Math.mulDiv(costUsd, mu, t.entryUsd, Math.Rounding.Ceil);
            if (minimum == 0) {
                revert InvalidOrder();
            }
            return (t.settlement, t.market, o.held, minimum);
        }
        if (t.kind == Kind.Bracket ? o.state != State.Entered : o.state != State.Pending) {
            revert NotEligible();
        }
        uint256 price;
        if (leg == Leg.TakeProfit) {
            if (t.kind != Kind.TakeProfit && t.kind != Kind.Bracket) {
                revert NotEligible();
            }
            price = t.takeProfitUsd;
        } else {
            if (t.kind != Kind.StopLoss && t.kind != Kind.Bracket) {
                revert NotEligible();
            }
            price = Math.mulDiv(t.stopUsd, 10000 - t.stopSlippageBps, 10000, Math.Rounding.Ceil);
        }
        uint256 proceedsUsd = Math.mulDiv(o.held, price, mu, Math.Rounding.Ceil);
        minimum = Math.mulDiv(proceedsUsd, su, usd, Math.Rounding.Ceil);
        if (minimum == 0) {
            revert InvalidOrder();
        }
        return (t.market, t.settlement, o.held, minimum);
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
        uint256 usd = settlementPrice(o.terms.settlement);
        (address input, address out, uint256 amount, uint256 minimum) = _execution(id, leg, usd);
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
        // Recheck after the external adapter: a feed update cannot weaken the floor.
        uint256 afterMinimum = _minimumAfterSwap(o, leg, amount);
        if (output < minimum || output < afterMinimum) {
            revert MinimumNotMet();
        }
        if (leg == Leg.Entry && o.terms.kind == Kind.Bracket) {
            o.held = output;
            o.state = State.Entered;
        } else {
            _deliver(out, o.owner, output);
        }
        emit Filled(id, leg, amount, output, usd);
    }

    function _minimumAfterSwap(Order storage o, Leg leg, uint256 amount)
        private
        view
        returns (uint256 minimum)
    {
        uint256 usd = settlementPrice(o.terms.settlement);
        uint256 mu = 10 ** o.marketDecimals;
        uint256 su = 10 ** o.settlementDecimals;
        if (leg == Leg.Entry) {
            minimum = Math.mulDiv(
                Math.mulDiv(amount, usd, su, Math.Rounding.Ceil),
                mu,
                o.terms.entryUsd,
                Math.Rounding.Ceil
            );
        } else {
            uint256 price = leg == Leg.TakeProfit
                ? o.terms.takeProfitUsd
                : Math.mulDiv(
                    o.terms.stopUsd, 10000 - o.terms.stopSlippageBps, 10000, Math.Rounding.Ceil
                );
            minimum = Math.mulDiv(
                Math.mulDiv(amount, price, mu, Math.Rounding.Ceil), su, usd, Math.Rounding.Ceil
            );
        }
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
