// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteOrderVault} from "../experimental/RouteOrderVault.sol";
import {RouteLeanMetaExecutor} from "../RouteLeanMetaExecutor.sol";
import {OrderTestFeed} from "./RouteOrderVault.t.sol";
import {MockUpstream} from "./RouteMetaExecutor.t.sol";
import {Token, Vm} from "./Route.t.sol";

/// Tests the existing fixed-target executor as the vault adapter, without a new wrapper.
/// Upstream liquidity and prices remain fixtures, not a provider fork test.
contract RouteOrderSettlementTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token market; Token cash; MockUpstream upstream;
    RouteLeanMetaExecutor executor; RouteOrderVault vault; OrderTestFeed feed;
    function setUp() public {
        vm.warp(1000);market=new Token("M");cash=new Token("C");upstream=new MockUpstream();
        executor=new RouteLeanMetaExecutor(address(upstream),MockUpstream.swap.selector);
        feed=new OrderTestFeed();feed.set(10 ether,1000);
        vault=new RouteOrderVault(address(feed),address(executor),60);
        cash.mint(address(this),100 ether);market.mint(address(upstream),100 ether);
        cash.mint(address(upstream),100 ether);cash.approve(address(vault),100 ether);
    }
    function create() internal returns(uint256) {
        return vault.create(RouteOrderVault.Terms({kind:RouteOrderVault.Kind.Bracket,
            market:address(market),settlement:address(cash),amount:10 ether,
            entryPrice:10 ether,takeProfitPrice:12 ether,stopPrice:8 ether,
            entryMinimum:15 ether,takeProfitRate:2 ether,stopRate:0.5 ether,expiresAt:2000}));
    }
    function payload(address input,address output,uint256 amount,uint256 received,address recipient)
        internal pure returns(bytes memory) {
        return abi.encodeCall(MockUpstream.swap,(input,output,amount,received,recipient));
    }
    function enter(uint256 id,uint256 amount,uint256 received,address recipient) internal {
        vault.execute(id,RouteOrderVault.Leg.Entry,payload(address(cash),address(market),amount,received,recipient));
    }
    function assertClean() internal view {
        require(cash.allowance(address(vault),address(executor))==0);
        require(market.allowance(address(vault),address(executor))==0);
        require(cash.allowance(address(executor),address(upstream))==0);
        require(market.allowance(address(executor),address(upstream))==0);
    }
    function testBracketUsesActualOutputAndClearsBothAllowanceLayers() public {
        uint256 id=create();enter(id,10 ether,20 ether,address(vault));
        require(vault.getOrder(id).held==20 ether);assertClean();
        feed.set(12 ether,1000);
        vault.execute(id,RouteOrderVault.Leg.TakeProfit,
            payload(address(market),address(cash),20 ether,40 ether,address(vault)));
        require(cash.balanceOf(address(this))==130 ether);assertClean();
        require(vault.getOrder(id).state==RouteOrderVault.State.Completed);
        vm.expectRevert(RouteOrderVault.NotEligible.selector);
        vault.execute(id,RouteOrderVault.Leg.StopLoss,"");
    }
    function testRedirectedOutputRollsBackWholeOrder() public {
        uint256 id=create();
        vm.expectRevert(RouteLeanMetaExecutor.SlippageExceeded.selector);
        enter(id,10 ether,20 ether,address(0xBAD));
        require(market.balanceOf(address(0xBAD))==0 && vault.getOrder(id).held==10 ether);
        require(vault.getOrder(id).state==RouteOrderVault.State.Pending);assertClean();
    }
    function testPartialInputCannotFill() public {
        uint256 id=create();vm.expectRevert(RouteLeanMetaExecutor.UnsupportedToken.selector);
        enter(id,5 ether,20 ether,address(vault));
        require(vault.getOrder(id).held==10 ether);assertClean();
    }
    function testDonationsCannotSatisfyMinimumOrBeSpent() public {
        uint256 id=create();market.mint(address(vault),50 ether);
        cash.mint(address(executor),3 ether);market.mint(address(executor),4 ether);
        vm.expectRevert(RouteLeanMetaExecutor.SlippageExceeded.selector);
        enter(id,10 ether,14 ether,address(vault));
        enter(id,10 ether,20 ether,address(vault));
        require(vault.getOrder(id).held==20 ether && market.balanceOf(address(vault))==70 ether);
        require(cash.balanceOf(address(executor))==3 ether && market.balanceOf(address(executor))==4 ether);
        vault.cancel(id);require(market.balanceOf(address(this))==20 ether);
        require(market.balanceOf(address(vault))==50 ether);assertClean();
    }
    function testRejectedStopKeepsPositionAvailableForCancellation() public {
        uint256 id=create();enter(id,10 ether,20 ether,address(vault));feed.set(7 ether,1000);
        vm.expectRevert(RouteLeanMetaExecutor.SlippageExceeded.selector);
        vault.execute(id,RouteOrderVault.Leg.StopLoss,
            payload(address(market),address(cash),20 ether,9 ether,address(vault)));
        require(vault.getOrder(id).state==RouteOrderVault.State.Entered);
        require(vault.getOrder(id).held==20 ether);assertClean();
        vault.cancel(id);require(market.balanceOf(address(this))==20 ether);
    }
}
