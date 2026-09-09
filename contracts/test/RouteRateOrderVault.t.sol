// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteRateOrderVault as Vault} from "../experimental/RouteRateOrderVault.sol";
import {OrderTestAdapter} from "./RouteOrderVault.t.sol";
import {Token,TaxToken,Vm} from "./Route.t.sol";
contract RouteRateOrderVaultTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Vault vault;OrderTestAdapter adapter;Token market;Token cash;
    address keeper=address(0xBEEF);
    function setUp() public {
        vm.warp(1000);market=new Token("M");cash=new Token("C");adapter=new OrderTestAdapter();
        vault=new Vault(address(adapter));market.mint(address(this),100 ether);cash.mint(address(this),100 ether);
        market.approve(address(vault),type(uint256).max);cash.approve(address(vault),type(uint256).max);
    }
    function terms(Vault.Kind kind) internal view returns(Vault.Terms memory t) {
        t.kind=kind;t.market=address(market);t.settlement=address(cash);t.amount=10 ether;t.expiresAt=2000;
        if(kind==Vault.Kind.LimitBuy || kind==Vault.Kind.Bracket)t.entryMinimum=20 ether;
        if(kind==Vault.Kind.TakeProfit || kind==Vault.Kind.Bracket)t.takeProfitRate=1 ether;
        if(kind==Vault.Kind.StopLoss || kind==Vault.Kind.Bracket) {
            t.stopTriggerRate=0.4 ether;t.stopMinimumRate=0.3 ether;t.keeper=keeper;
        }
    }
    function testLimitNeedsOutputNotAnOracle() public {
        uint256 id=vault.create(terms(Vault.Kind.LimitBuy));adapter.configure(19 ether,false,false);
        vm.expectRevert(Vault.MinimumNotMet.selector);vault.execute(id,Vault.Leg.Entry,"");
        require(vault.getOrder(id).state==Vault.State.Pending);
        adapter.configure(20 ether,false,false);vault.execute(id,Vault.Leg.Entry,"");
        require(market.balanceOf(address(this))==120 ether && vault.getOrder(id).held==0);
    }
    function testPermissionlessTakeProfitAtAuthorizedRate() public {
        uint256 id=vault.create(terms(Vault.Kind.TakeProfit));adapter.configure(10 ether,false,false);
        vm.prank(address(123));vault.execute(id,Vault.Leg.TakeProfit,"");
        require(cash.balanceOf(address(this))==110 ether && cash.balanceOf(address(123))==0);
    }
    function testOnlyNamedKeeperCanTriggerStopEvenOwnerCannot() public {
        uint256 id=vault.create(terms(Vault.Kind.StopLoss));
        vm.expectRevert(Vault.UnauthorizedKeeper.selector);vault.execute(id,Vault.Leg.StopLoss,"");
        vm.prank(address(123));vm.expectRevert(Vault.UnauthorizedKeeper.selector);vault.execute(id,Vault.Leg.StopLoss,"");
        adapter.configure(3 ether,false,false);vm.prank(keeper);vault.execute(id,Vault.Leg.StopLoss,"");
        require(cash.balanceOf(address(this))==103 ether);
    }
    function testKeeperCannotWaiveFloorOrChangeRecipient() public {
        uint256 id=vault.create(terms(Vault.Kind.StopLoss));adapter.configure(2 ether,false,false);
        vm.prank(keeper);vm.expectRevert(Vault.MinimumNotMet.selector);vault.execute(id,Vault.Leg.StopLoss,"");
        adapter.configure(3 ether,false,true);
        vm.prank(keeper);vm.expectRevert(Vault.MinimumNotMet.selector);vault.execute(id,Vault.Leg.StopLoss,"");
        require(vault.getOrder(id).held==10 ether);vault.cancel(id);require(market.balanceOf(address(this))==100 ether);
    }
    function testBracketActualProceedsAndTakeProfitInvalidatesStop() public {
        uint256 id=vault.create(terms(Vault.Kind.Bracket));
        vm.prank(keeper);vm.expectRevert(Vault.NotEligible.selector);vault.execute(id,Vault.Leg.StopLoss,"");
        adapter.configure(25 ether,false,false);vault.execute(id,Vault.Leg.Entry,"");
        require(vault.getOrder(id).held==25 ether);
        adapter.configure(24 ether,false,false);vm.expectRevert(Vault.MinimumNotMet.selector);vault.execute(id,Vault.Leg.TakeProfit,"");
        adapter.configure(25 ether,false,false);vault.execute(id,Vault.Leg.TakeProfit,"");
        vm.prank(keeper);vm.expectRevert(Vault.NotEligible.selector);vault.execute(id,Vault.Leg.StopLoss,"");
    }
    function testBracketStopInvalidatesTakeProfit() public {
        uint256 id=vault.create(terms(Vault.Kind.Bracket));vault.execute(id,Vault.Leg.Entry,"");
        adapter.configure(6 ether,false,false);vm.prank(keeper);vault.execute(id,Vault.Leg.StopLoss,"");
        vm.expectRevert(Vault.NotEligible.selector);vault.execute(id,Vault.Leg.TakeProfit,"");
    }
    function testCancelAfterEntryAndExpiryReturnsOnlyHeld() public {
        uint256 id=vault.create(terms(Vault.Kind.Bracket));vault.execute(id,Vault.Leg.Entry,"");
        market.mint(address(vault),7 ether);vm.warp(2000);
        vm.expectRevert(Vault.NotEligible.selector);vault.execute(id,Vault.Leg.TakeProfit,"");
        vault.cancel(id);require(market.balanceOf(address(this))==120 ether && market.balanceOf(address(vault))==7 ether);
        vm.expectRevert(Vault.NotEligible.selector);vault.cancel(id);
    }
    function testKeeperCannotCancelOrSpendOtherOrder() public {
        uint256 id=vault.create(terms(Vault.Kind.Bracket));
        vm.prank(keeper);vm.expectRevert(Vault.NotOwner.selector);vault.cancel(id);
        uint256 other=vault.create(terms(Vault.Kind.LimitBuy));vault.execute(other,Vault.Leg.Entry,"");
        require(vault.getOrder(id).held==10 ether && cash.balanceOf(address(vault))==10 ether);
    }
    function testInvalidKeeperFloorAndBracketRejected() public {
        Vault.Terms memory t=terms(Vault.Kind.StopLoss);t.keeper=address(0);
        vm.expectRevert(Vault.InvalidOrder.selector);vault.create(t);
        t=terms(Vault.Kind.StopLoss);t.stopMinimumRate=t.stopTriggerRate+1;
        vm.expectRevert(Vault.InvalidOrder.selector);vault.create(t);
        t=terms(Vault.Kind.LimitBuy);t.keeper=keeper;
        vm.expectRevert(Vault.InvalidOrder.selector);vault.create(t);
        t=terms(Vault.Kind.Bracket);t.stopTriggerRate=0.5 ether;
        vm.expectRevert(Vault.InvalidOrder.selector);vault.create(t);
    }
    function testPartialSpendAndReentryRejected() public {
        uint256 id=vault.create(terms(Vault.Kind.LimitBuy));adapter.configure(20 ether,true,false);
        vm.expectRevert(Vault.TransferMismatch.selector);vault.execute(id,Vault.Leg.Entry,"");
        adapter.configure(20 ether,false,false);adapter.enableReentryProbe();vault.execute(id,Vault.Leg.Entry,"");
        require(cash.allowance(address(vault),address(adapter))==0);
    }
    function testFuzzMinimumRoundsUp(uint96 a,uint96 r) public {
        if(a==0 || r==0)return;
        Vault.Terms memory t=terms(Vault.Kind.TakeProfit);t.amount=a;t.takeProfitRate=r;
        market.mint(address(this),a);uint256 id=vault.create(t);
        (,,,uint256 minimum)=vault.execution(id,Vault.Leg.TakeProfit);
        require(minimum==(uint256(a)*uint256(r)+1e18-1)/1e18);
    }
    function testTaxedDepositRejectedWithoutCustodyOrOrder() public {
        TaxToken taxed=new TaxToken();taxed.mint(address(this),100 ether);
        taxed.approve(address(vault),100 ether);
        Vault.Terms memory t=terms(Vault.Kind.LimitBuy);t.settlement=address(taxed);
        vm.expectRevert(Vault.TransferMismatch.selector);vault.create(t);
        require(vault.nextId()==0 && taxed.balanceOf(address(vault))==0);
    }
}
