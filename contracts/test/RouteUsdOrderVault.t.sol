// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteUsdOrderVault as Vault} from "../experimental/RouteUsdOrderVault.sol";
import {OrderTestAdapter,OrderTestFeed} from "./RouteOrderVault.t.sol";
import {Token,Vm} from "./Route.t.sol";

contract RouteUsdOrderVaultTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Vault vault; OrderTestAdapter adapter; OrderTestFeed feed; Token market; Token weth;
    address keeper=address(0xBEEF);
    function setUp() public {
        vm.warp(1000);market=new Token("M");weth=new Token("WETH");
        adapter=new OrderTestAdapter();feed=new OrderTestFeed();feed.set(2000 ether,1000);
        vault=new Vault(address(adapter),address(feed),60);
        market.mint(address(this),1000 ether);weth.mint(address(this),100 ether);
        market.approve(address(vault),type(uint256).max);weth.approve(address(vault),type(uint256).max);
    }
    function terms(Vault.Kind kind) internal view returns(Vault.Terms memory t) {
        t.kind=kind;t.market=address(market);t.settlement=address(weth);t.expiresAt=2000;
        bool buy=kind==Vault.Kind.LimitBuy||kind==Vault.Kind.Bracket;
        t.amount=buy?0.01 ether:100 ether;
        if(buy)t.entryUsd=0.1 ether;
        if(kind==Vault.Kind.TakeProfit||kind==Vault.Kind.Bracket)t.takeProfitUsd=0.113 ether;
        if(kind==Vault.Kind.StopLoss||kind==Vault.Kind.Bracket){t.stopUsd=0.09 ether;t.stopSlippageBps=50;t.keeper=keeper;}
    }
    function testUsdTakeProfitNotPoint113EthAndRepricesWhenEthMoves() public {
        uint256 id=vault.create(terms(Vault.Kind.TakeProfit));
        (,,,uint256 minimum)=vault.execution(id,Vault.Leg.TakeProfit);
        require(minimum==0.00565 ether); // 100 tokens * $0.113 / $2000.
        feed.set(4000 ether,1000);
        (,,,minimum)=vault.execution(id,Vault.Leg.TakeProfit);require(minimum==0.002825 ether);
        adapter.configure(minimum-1,false,false);vm.expectRevert(Vault.MinimumNotMet.selector);vault.execute(id,Vault.Leg.TakeProfit,"");
        adapter.configure(minimum,false,false);vault.execute(id,Vault.Leg.TakeProfit,"");
        require(vault.getOrder(id).state==Vault.State.Completed);
        require(weth.balanceOf(address(this))==100 ether+minimum);
    }
    function testEntryUsdTargetRemainsFixedWhenFundingTokenChangesPrice() public {
        uint256 id=vault.create(terms(Vault.Kind.LimitBuy));
        (,,,uint256 minimum)=vault.execution(id,Vault.Leg.Entry);require(minimum==200 ether);
        feed.set(3000 ether,1000);
        (,,,minimum)=vault.execution(id,Vault.Leg.Entry);require(minimum==300 ether);
        adapter.configure(200 ether,false,false);vm.expectRevert(Vault.MinimumNotMet.selector);vault.execute(id,Vault.Leg.Entry,"");
        adapter.configure(300 ether,false,false);vault.execute(id,Vault.Leg.Entry,"");
    }
    function testStopFloorUsesCurrentUsdPriceAndNamedKeeper() public {
        uint256 id=vault.create(terms(Vault.Kind.StopLoss));
        vm.expectRevert(Vault.UnauthorizedKeeper.selector);vault.execute(id,Vault.Leg.StopLoss,"");
        feed.set(1000 ether,1000);
        (,,,uint256 minimum)=vault.execution(id,Vault.Leg.StopLoss);require(minimum==0.008955 ether);
        adapter.configure(minimum-1,false,false);vm.prank(keeper);vm.expectRevert(Vault.MinimumNotMet.selector);vault.execute(id,Vault.Leg.StopLoss,"");
        adapter.configure(minimum,false,false);vm.prank(keeper);vault.execute(id,Vault.Leg.StopLoss,"");
    }
    function testBracketSizesExitToActualEntryAndInvalidatesSibling() public {
        uint256 id=vault.create(terms(Vault.Kind.Bracket));
        vm.expectRevert(Vault.NotEligible.selector);vault.execute(id,Vault.Leg.TakeProfit,"");
        adapter.configure(250 ether,false,false);vault.execute(id,Vault.Leg.Entry,"");
        require(vault.getOrder(id).held==250 ether);
        feed.set(4000 ether,1000);
        (,,,uint256 minimum)=vault.execution(id,Vault.Leg.TakeProfit);require(minimum==0.0070625 ether);
        adapter.configure(minimum,false,false);vault.execute(id,Vault.Leg.TakeProfit,"");
        vm.prank(keeper);vm.expectRevert(Vault.NotEligible.selector);vault.execute(id,Vault.Leg.StopLoss,"");
    }
    function testBracketStopInvalidatesProfit() public {
        uint256 id=vault.create(terms(Vault.Kind.Bracket));adapter.configure(200 ether,false,false);vault.execute(id,Vault.Leg.Entry,"");
        (,,,uint256 minimum)=vault.execution(id,Vault.Leg.StopLoss);adapter.configure(minimum,false,false);
        vm.prank(keeper);vault.execute(id,Vault.Leg.StopLoss,"");
        vm.expectRevert(Vault.NotEligible.selector);vault.execute(id,Vault.Leg.TakeProfit,"");
    }
    function testStaleFutureZeroFeedFailsClosedButCancellationWorks() public {
        uint256 id=vault.create(terms(Vault.Kind.LimitBuy));
        feed.set(2000 ether,939);vm.expectRevert(Vault.InvalidPrice.selector);vault.execution(id,Vault.Leg.Entry);
        vm.expectRevert(Vault.InvalidPrice.selector);vault.create(terms(Vault.Kind.LimitBuy));
        feed.set(2000 ether,1001);vm.expectRevert(Vault.InvalidPrice.selector);vault.execution(id,Vault.Leg.Entry);
        feed.set(0,1000);vm.expectRevert(Vault.InvalidPrice.selector);vault.execution(id,Vault.Leg.Entry);
        vault.cancel(id);require(weth.balanceOf(address(this))==100 ether);
    }
    function testPartialSpendRedirectAndReplayRejected() public {
        uint256 id=vault.create(terms(Vault.Kind.LimitBuy));
        adapter.configure(200 ether,true,false);vm.expectRevert(Vault.TransferMismatch.selector);vault.execute(id,Vault.Leg.Entry,"");
        adapter.configure(200 ether,false,true);vm.expectRevert(Vault.MinimumNotMet.selector);vault.execute(id,Vault.Leg.Entry,"");
        adapter.configure(200 ether,false,false);adapter.enableReentryProbe();vault.execute(id,Vault.Leg.Entry,"");
        require(weth.allowance(address(vault),address(adapter))==0);
        vm.expectRevert(Vault.NotEligible.selector);vault.execute(id,Vault.Leg.Entry,"");
    }
    function testExpiryAndCancelAfterEntry() public {
        uint256 id=vault.create(terms(Vault.Kind.Bracket));adapter.configure(200 ether,false,false);vault.execute(id,Vault.Leg.Entry,"");
        vm.warp(2000);feed.set(2000 ether,2000);
        vm.expectRevert(Vault.NotEligible.selector);vault.execute(id,Vault.Leg.TakeProfit,"");
        vault.cancel(id);require(market.balanceOf(address(this))==1200 ether);
    }
}
