// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteMetricExecutor, IRouteMetricPool} from "../experimental/RouteMetricExecutor.sol";
import {Token, TaxToken, Wrapped, Vm} from "./Route.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MetricFactoryFixture {
    mapping(address => bool) public isPool;
    function allow(address pool, bool enabled) external { isPool[pool] = enabled; }
}
contract MetricPoolFixture is IRouteMetricPool {
    Immutables private settings;
    uint256 public mode;
    constructor(address factory, address a, address b) {
        settings.factory = factory; (settings.token0, settings.token1) = a < b ? (a,b) : (b,a);
    }
    function getImmutables() external view returns (Immutables memory) { return settings; }
    function setMode(uint256 value) external { mode = value; }
    function setExtension(address ext) external { settings.extension1 = ext; }
    function setOrder(uint256 order) external { settings.beforeSwap = order; }
    function setFactory(address f) external { settings.factory = f; }
    function reverseTokens() external { (settings.token0,settings.token1) = (settings.token1,settings.token0); }
    function swap(address recipient, bool direction, int128 amount, uint128, bytes calldata, bytes calldata)
        external returns (int128 d0, int128 d1)
    {
        int128 owed = mode == 1 ? amount - 1 : mode == 2 ? amount + 1 : amount;
        int128 out = amount * 2;
        d0 = direction ? owed : -out; d1 = direction ? -out : owed;
        IERC20(direction ? settings.token1 : settings.token0).transfer(recipient, uint256(uint128(out)));
        if (mode == 6) { d0 = owed; d1 = owed; }
        if (mode != 3) {
            RouteMetricExecutor(payable(msg.sender)).metricOmmSwapCallback(d0, d1, mode == 7 ? bytes("bad") : bytes(""));
            if (mode == 4) RouteMetricExecutor(payable(msg.sender)).metricOmmSwapCallback(d0, d1, "");
        }
        if (mode == 5) { if (direction) d1 -= 1; else d0 -= 1; }
    }
}
contract MetricRejectReceiver { receive() external payable { revert(); } }
contract MetricReentryToken is Token {
    RouteMetricExecutor executor; address pool; address output;
    bytes4 public swapError; bytes4 public callbackError; bool armed;
    constructor() Token("REENTRY") {}
    function arm(RouteMetricExecutor e,address p,address out) external { executor=e;pool=p;output=out;armed=true; }
    function _update(address from,address to,uint256 value) internal override {
        super._update(from,to,value);
        if (armed && from!=address(0) && to==pool) {
            armed=false;
            (bool ok,bytes memory reason)=address(executor).call(abi.encodeCall(executor.swap,(pool,address(this),output,1,1,address(0xBEEF),block.timestamp)));
            require(!ok && reason.length>=4); swapError=bytes4(reason);
            (ok,reason)=address(executor).call(abi.encodeCall(executor.metricOmmSwapCallback,(int256(1),int256(-2),bytes(""))));
            require(!ok && reason.length>=4); callbackError=bytes4(reason);
        }
    }
}
contract RouteMetricExecutorTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token a; Token b; Wrapped weth; MetricFactoryFixture factory; MetricPoolFixture pool; RouteMetricExecutor executor;
    address constant recipient = address(0xBEEF);
    function setUp() public {
        a = new Token("A"); b = new Token("B"); weth = new Wrapped(); factory = new MetricFactoryFixture();
        executor = new RouteMetricExecutor(address(factory), address(weth)); pool = _pool(address(a), address(b));
        a.mint(address(this), 1e30); b.mint(address(this), 1e30);
        a.approve(address(executor),100); b.approve(address(executor),100); vm.deal(address(this), 100 ether); vm.deal(address(weth),100 ether);
    }
    receive() external payable {}
    function _pool(address input, address output) private returns(MetricPoolFixture p) {
        p = new MetricPoolFixture(address(factory),input,output); factory.allow(address(p),true);
        Token(input).mint(address(p),1e30); Token(output).mint(address(p),1e30);
    }
    function _swap() private returns(uint256) { return executor.swap(address(pool),address(a),address(b),100,200,recipient,block.timestamp); }
    function testExactTransferAndPreservedDonations() public {
        a.mint(address(executor),17); b.mint(address(executor),19); vm.deal(address(executor),23);
        uint256 before = a.balanceOf(address(this)); require(_swap()==200);
        require(a.balanceOf(address(this))==before-100 && b.balanceOf(recipient)==200);
        require(a.balanceOf(address(executor))==17 && b.balanceOf(address(executor))==19 && address(executor).balance==23);
        require(a.allowance(address(this),address(executor))==0 && a.allowance(address(executor),address(pool))==0);
    }
    function testOppositeDirectionAndRecipientIsCaller() public {
        uint256 before = a.balanceOf(address(this));
        require(executor.swap(address(pool),address(b),address(a),100,200,address(this),block.timestamp)==200);
        require(a.balanceOf(address(this))==before+200);
    }
    function testNonLexicalPoolTokenOrder() public {
        pool.reverseTokens(); IRouteMetricPool.Immutables memory p = pool.getImmutables(); require(p.token0 > p.token1);
        require(_swap()==200); require(b.balanceOf(recipient)==200);
    }
    function testNativeInputPreservesWrappedAndNativeDonations() public {
        pool = _pool(address(weth),address(b)); weth.mint(address(executor),17); vm.deal(address(executor),23);
        require(executor.swap{value:100}(address(pool),address(0),address(b),100,200,recipient,block.timestamp)==200);
        require(weth.balanceOf(address(executor))==17 && address(executor).balance==23 && b.balanceOf(recipient)==200);
    }
    function testNativeOutputPreservesWrappedAndNativeDonations() public {
        pool = _pool(address(a),address(weth)); weth.mint(address(executor),17); vm.deal(address(executor),23);
        require(executor.swap(address(pool),address(a),address(0),100,200,recipient,block.timestamp)==200);
        require(weth.balanceOf(address(executor))==17 && address(executor).balance==23 && recipient.balance==200);
    }
    function testMinimumRevertsAllTransfersAndCanRetry() public {
        uint256 before = a.balanceOf(address(this)); vm.expectRevert(RouteMetricExecutor.SlippageExceeded.selector);
        executor.swap(address(pool),address(a),address(b),100,201,recipient,block.timestamp);
        require(a.balanceOf(address(this))==before && b.balanceOf(recipient)==0 && a.allowance(address(this),address(executor))==100); require(_swap()==200);
    }
    function testSequentialSwapsClearTransientState() public { require(_swap()==200); a.approve(address(executor),100); require(_swap()==200); }
    function testPartialInputRejected() public { pool.setMode(1); vm.expectRevert(RouteMetricExecutor.CallbackRejected.selector); _swap(); }
    function testExcessInputRejected() public { pool.setMode(2); vm.expectRevert(RouteMetricExecutor.CallbackRejected.selector); _swap(); }
    function testMissingCallbackRejected() public { pool.setMode(3); vm.expectRevert(RouteMetricExecutor.CallbackRejected.selector); _swap(); }
    function testRepeatedCallbackRejected() public { pool.setMode(4); vm.expectRevert(RouteMetricExecutor.CallbackRejected.selector); _swap(); }
    function testFalseOutputRejected() public { pool.setMode(5); vm.expectRevert(RouteMetricExecutor.InvalidAmount.selector); _swap(); }
    function testWrongSignsRejected() public { pool.setMode(6); vm.expectRevert(RouteMetricExecutor.CallbackRejected.selector); _swap(); }
    function testUnexpectedCallbackDataRejected() public { pool.setMode(7); vm.expectRevert(RouteMetricExecutor.CallbackRejected.selector); _swap(); }
    function testUnsolicitedCallbackRejected() public { vm.expectRevert(RouteMetricExecutor.CallbackRejected.selector); executor.metricOmmSwapCallback(100,-200,""); }
    function testUnsupportedPoolRejected() public { factory.allow(address(pool),false); vm.expectRevert(RouteMetricExecutor.InvalidRoute.selector); _swap(); }
    function testWrongFactoryRejected() public { pool.setFactory(address(this)); vm.expectRevert(RouteMetricExecutor.InvalidRoute.selector); _swap(); }
    function testExtensionsRejected() public { pool.setExtension(address(this)); vm.expectRevert(RouteMetricExecutor.InvalidRoute.selector); _swap(); }
    function testExtensionOrdersRejected() public { pool.setOrder(1); vm.expectRevert(RouteMetricExecutor.InvalidRoute.selector); _swap(); }
    function testWrongTokenRejected() public { vm.expectRevert(RouteMetricExecutor.InvalidRoute.selector); executor.swap(address(pool),address(a),address(weth),100,1,recipient,block.timestamp); }
    function testExpiryRejected() public { vm.warp(100); vm.expectRevert(RouteMetricExecutor.DeadlineExpired.selector); executor.swap(address(pool),address(a),address(b),100,1,recipient,99); }
    function testNativeValueRejected() public { vm.expectRevert(RouteMetricExecutor.InvalidAmount.selector); executor.swap{value:1}(address(pool),address(a),address(b),100,1,recipient,block.timestamp); }
    function testSelfRecipientRejected() public { vm.expectRevert(RouteMetricExecutor.InvalidRoute.selector); executor.swap(address(pool),address(a),address(b),100,1,address(executor),block.timestamp); }
    function testTaxedInputRejected() public {
        TaxToken tax = new TaxToken(); pool = _pool(address(tax),address(b)); tax.mint(address(this),100); tax.approve(address(executor),100);
        vm.expectRevert(RouteMetricExecutor.UnsupportedToken.selector); executor.swap(address(pool),address(tax),address(b),100,1,recipient,block.timestamp);
    }
    function testTaxedOutputRejected() public {
        TaxToken tax = new TaxToken(); pool = _pool(address(a),address(tax));
        vm.expectRevert(RouteMetricExecutor.InvalidAmount.selector); executor.swap(address(pool),address(a),address(tax),100,1,recipient,block.timestamp);
    }
    function testNativeRecipientFailureRollsBack() public {
        pool = _pool(address(a),address(weth)); MetricRejectReceiver bad = new MetricRejectReceiver();
        uint256 before = a.balanceOf(address(this)); vm.expectRevert(RouteMetricExecutor.NativeTransferFailed.selector);
        executor.swap(address(pool),address(a),address(0),100,1,address(bad),block.timestamp); require(a.balanceOf(address(this))==before);
    }
    function testTokenReentryAndCallbackImpersonationFailWithoutCorruptingSwap() public {
        MetricReentryToken token = new MetricReentryToken(); pool=_pool(address(token),address(b));
        token.mint(address(this),100); token.approve(address(executor),100); token.arm(executor,address(pool),address(b));
        require(executor.swap(address(pool),address(token),address(b),100,200,recipient,block.timestamp)==200);
        require(token.swapError()==bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        require(token.callbackError()==RouteMetricExecutor.CallbackRejected.selector);
    }
    function testZeroInputRejected() public { vm.expectRevert(RouteMetricExecutor.InvalidAmount.selector); executor.swap(address(pool),address(a),address(b),0,1,recipient,block.timestamp); }
    function testOversizedInputRejected() public { vm.expectRevert(RouteMetricExecutor.InvalidAmount.selector); executor.swap(address(pool),address(a),address(b),uint256(uint128(type(int128).max))+1,1,recipient,block.timestamp); }
    function testZeroMinimumRejected() public { vm.expectRevert(RouteMetricExecutor.InvalidAmount.selector); executor.swap(address(pool),address(a),address(b),100,0,recipient,block.timestamp); }
    function testFuzzExactInput(uint64 amount) public {
        if(amount==0)return; a.approve(address(executor),amount);
        require(executor.swap(address(pool),address(a),address(b),amount,uint256(amount)*2,recipient,block.timestamp)==uint256(amount)*2);
    }
}
