// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {
    RouteOrderVault,
    IOrderPriceFeed,
    IOrderSwapAdapter
} from "../experimental/RouteOrderVault.sol";
import {Token, TaxToken, Vm} from "./Route.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OrderTestFeed is IOrderPriceFeed {
    uint256 public value = 10 ether;
    uint256 public updated;

    function set(uint256 v, uint256 at) external {
        value = v;
        updated = at;
    }

    function price(address) external view returns (uint256, uint256) {
        return (value, updated);
    }
}

contract OrderTestAdapter is IOrderSwapAdapter {
    uint256 public output = 20 ether;
    bool public partialSpend;
    bool public redirect;
    bool public probeReentry;

    function enableReentryProbe() external {
        probeReentry = true;
    }

    function configure(uint256 out, bool p, bool r) external {
        output = out;
        partialSpend = p;
        redirect = r;
    }

    function swap(
        address input,
        address out,
        uint256 amount,
        uint256,
        address recipient,
        uint256,
        bytes calldata
    ) external returns (uint256) {
        if (probeReentry) {
            (bool ok, bytes memory reason) = msg.sender
                .call(abi.encodeWithSignature("execute(uint256,uint8,bytes)", 1, 0, bytes("")));
            require(
                !ok && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")),
                "reentry not blocked"
            );
        }
        IERC20(input).transferFrom(msg.sender, address(this), partialSpend ? amount / 2 : amount);
        Token(out).mint(redirect ? address(0xBAD) : recipient, output);
        return type(uint256).max; // Never trust adapter return values.
    }
}

contract RouteOrderVaultTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    RouteOrderVault vault;
    OrderTestFeed feed;
    OrderTestAdapter adapter;
    Token market;
    Token cash;

    function setUp() public {
        vm.warp(1000);
        market = new Token("M");
        cash = new Token("C");
        feed = new OrderTestFeed();
        feed.set(10 ether, block.timestamp);
        adapter = new OrderTestAdapter();
        vault = new RouteOrderVault(address(feed), address(adapter), 60);
        market.mint(address(this), 100 ether);
        cash.mint(address(this), 100 ether);
        market.approve(address(vault), type(uint256).max);
        cash.approve(address(vault), type(uint256).max);
    }

    function terms(RouteOrderVault.Kind kind)
        internal
        view
        returns (RouteOrderVault.Terms memory t)
    {
        t.kind = kind;
        t.market = address(market);
        t.settlement = address(cash);
        t.amount = 10 ether;
        t.expiresAt = uint64(block.timestamp + 1000);
        if (kind == RouteOrderVault.Kind.LimitBuy || kind == RouteOrderVault.Kind.Bracket) {
            t.entryPrice = 10 ether;
            t.entryMinimum = 15 ether;
        }
        if (kind == RouteOrderVault.Kind.TakeProfit || kind == RouteOrderVault.Kind.Bracket) {
            t.takeProfitPrice = 12 ether;
            t.takeProfitRate = 2 ether;
        }
        if (kind == RouteOrderVault.Kind.StopLoss || kind == RouteOrderVault.Kind.Bracket) {
            t.stopPrice = 8 ether;
            t.stopRate = 0.5 ether;
        }
    }

    function testBracketActualProceedsAndAtomicSiblingInvalidation() public {
        uint256 id = vault.create(terms(RouteOrderVault.Kind.Bracket));
        vm.expectRevert(RouteOrderVault.NotEligible.selector);
        vault.execute(id, RouteOrderVault.Leg.TakeProfit, "");
        vault.execute(id, RouteOrderVault.Leg.Entry, "");
        require(vault.getOrder(id).held == 20 ether);
        require(vault.getOrder(id).state == RouteOrderVault.State.Entered);
        feed.set(12 ether, block.timestamp);
        adapter.configure(40 ether, false, false);
        vault.execute(id, RouteOrderVault.Leg.TakeProfit, "");
        require(cash.balanceOf(address(this)) == 130 ether);
        require(market.allowance(address(vault), address(adapter)) == 0);
        feed.set(7 ether, block.timestamp);
        vm.expectRevert(RouteOrderVault.NotEligible.selector);
        vault.execute(id, RouteOrderVault.Leg.StopLoss, "");
    }

    function testEntryCannotRepeatAndCancellationReturnsProceeds() public {
        uint256 id = vault.create(terms(RouteOrderVault.Kind.Bracket));
        vault.execute(id, RouteOrderVault.Leg.Entry, "");
        vm.expectRevert(RouteOrderVault.NotEligible.selector);
        vault.execute(id, RouteOrderVault.Leg.Entry, "");
        vm.prank(address(0xBAD));
        vm.expectRevert(RouteOrderVault.NotOwner.selector);
        vault.cancel(id);
        vault.cancel(id);
        require(market.balanceOf(address(this)) == 120 ether);
        vm.expectRevert(RouteOrderVault.NotEligible.selector);
        vault.cancel(id);
    }

    function testCancelBeforeEntryAndAfterExpiry() public {
        uint256 id = vault.create(terms(RouteOrderVault.Kind.LimitBuy));
        vm.warp(3000);
        vm.expectRevert(RouteOrderVault.NotEligible.selector);
        vault.execute(id, RouteOrderVault.Leg.Entry, "");
        vault.cancel(id);
        require(cash.balanceOf(address(this)) == 100 ether);
    }

    function testFreshPriceAndTriggerRequired() public {
        uint256 id = vault.create(terms(RouteOrderVault.Kind.TakeProfit));
        vm.expectRevert(RouteOrderVault.NotEligible.selector);
        vault.execute(id, RouteOrderVault.Leg.TakeProfit, "");
        feed.set(12 ether, block.timestamp - 61);
        vm.expectRevert(RouteOrderVault.StalePrice.selector);
        vault.execute(id, RouteOrderVault.Leg.TakeProfit, "");
        feed.set(12 ether, block.timestamp + 1);
        vm.expectRevert(RouteOrderVault.StalePrice.selector);
        vault.execute(id, RouteOrderVault.Leg.TakeProfit, "");
    }

    function testStopDoesNotWaiveMinimumAndFailedFillRollsBack() public {
        uint256 id = vault.create(terms(RouteOrderVault.Kind.StopLoss));
        feed.set(7 ether, block.timestamp);
        adapter.configure(4 ether, false, false);
        vm.expectRevert(RouteOrderVault.MinimumNotMet.selector);
        vault.execute(id, RouteOrderVault.Leg.StopLoss, "");
        require(
            vault.getOrder(id).held == 10 ether
                && vault.getOrder(id).state == RouteOrderVault.State.Pending
        );
        require(market.allowance(address(vault), address(adapter)) == 0);
        adapter.configure(5 ether, false, false);
        vault.execute(id, RouteOrderVault.Leg.StopLoss, "");
        require(cash.balanceOf(address(this)) == 105 ether);
    }

    function testPartialSpendAndOutputRedirectionRevert() public {
        uint256 id = vault.create(terms(RouteOrderVault.Kind.LimitBuy));
        adapter.configure(20 ether, true, false);
        vm.expectRevert(RouteOrderVault.TransferMismatch.selector);
        vault.execute(id, RouteOrderVault.Leg.Entry, "");
        adapter.configure(20 ether, false, true);
        vm.expectRevert(RouteOrderVault.MinimumNotMet.selector);
        vault.execute(id, RouteOrderVault.Leg.Entry, "");
    }

    function testOtherOrdersAndDonationsAreNotConsumed() public {
        uint256 a = vault.create(terms(RouteOrderVault.Kind.LimitBuy));
        uint256 b = vault.create(terms(RouteOrderVault.Kind.LimitBuy));
        cash.mint(address(vault), 5);
        market.mint(address(vault), 7);
        vault.execute(a, RouteOrderVault.Leg.Entry, "");
        vault.cancel(b);
        require(cash.balanceOf(address(vault)) == 5 && market.balanceOf(address(vault)) == 7);
    }

    function testInvalidBracketRejected() public {
        RouteOrderVault.Terms memory t = terms(RouteOrderVault.Kind.Bracket);
        t.stopPrice = t.entryPrice;
        vm.expectRevert(RouteOrderVault.InvalidOrder.selector);
        vault.create(t);
    }

    function testReentryBlockedDuringAdapterCall() public {
        uint256 id = vault.create(terms(RouteOrderVault.Kind.LimitBuy));
        adapter.enableReentryProbe();
        vault.execute(id, RouteOrderVault.Leg.Entry, "");
        require(vault.getOrder(id).state == RouteOrderVault.State.Completed);
    }

    function testTaxedDepositRejectedWithoutCreatingOrder() public {
        TaxToken taxed = new TaxToken();
        taxed.mint(address(this), 100 ether);
        taxed.approve(address(vault), type(uint256).max);
        RouteOrderVault.Terms memory t = terms(RouteOrderVault.Kind.LimitBuy);
        t.settlement = address(taxed);
        vm.expectRevert(RouteOrderVault.TransferMismatch.selector);
        vault.create(t);
        require(vault.nextId() == 0 && taxed.balanceOf(address(this)) == 100 ether);
    }

    function testZeroPriceAndExactExpiryFailClosed() public {
        RouteOrderVault.Terms memory t = terms(RouteOrderVault.Kind.LimitBuy);
        uint256 id = vault.create(t);
        feed.set(0, block.timestamp);
        vm.expectRevert(RouteOrderVault.StalePrice.selector);
        vault.execute(id, RouteOrderVault.Leg.Entry, "");
        vm.warp(t.expiresAt);
        feed.set(10 ether, block.timestamp);
        vm.expectRevert(RouteOrderVault.NotEligible.selector);
        vault.execute(id, RouteOrderVault.Leg.Entry, "");
    }

    function testBracketStopWinsAndTakeProfitCannotRunLater() public {
        uint256 id = vault.create(terms(RouteOrderVault.Kind.Bracket));
        vault.execute(id, RouteOrderVault.Leg.Entry, "");
        feed.set(7 ether, block.timestamp);
        adapter.configure(10 ether, false, false);
        vault.execute(id, RouteOrderVault.Leg.StopLoss, "");
        require(cash.balanceOf(address(this)) == 100 ether);
        feed.set(20 ether, block.timestamp);
        vm.expectRevert(RouteOrderVault.NotEligible.selector);
        vault.execute(id, RouteOrderVault.Leg.TakeProfit, "");
    }

    function testFuzzExitMinimumRoundsUp(uint96 quantity, uint96 rate) public {
        if (quantity == 0 || quantity > 100 ether || rate == 0) {
            return;
        }
        RouteOrderVault.Terms memory t = terms(RouteOrderVault.Kind.TakeProfit);
        t.amount = quantity;
        t.takeProfitRate = rate;
        uint256 id = vault.create(t);
        feed.set(12 ether, block.timestamp);
        (,, uint256 amount, uint256 minimum) = vault.execution(id, RouteOrderVault.Leg.TakeProfit);
        require(amount == quantity && minimum == (uint256(quantity) * rate + 1e18 - 1) / 1e18);
    }
}
