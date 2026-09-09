// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {V4Adapter, IRoutePoolManager} from "../adapters/V4Adapter.sol";
import {Token, TaxToken, Wrapped, Vm} from "./Route.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
interface ICallback { function unlockCallback(bytes calldata) external returns (bytes memory); }

contract MockManager is IRoutePoolManager {
    address public synced; uint256 public beforeSync; uint256 public paid; uint256 public used;
    bool public partialFill; bool public mutate; bool public doubleCallback;
    function behavior(bool p, bool m, bool d) external { partialFill = p; mutate = m; doubleCallback = d; }
    receive() external payable {}
    function unlock(bytes calldata data) external returns (bytes memory result) {
        result = ICallback(msg.sender).unlockCallback(mutate ? bytes("bad") : data);
        if (doubleCallback) ICallback(msg.sender).unlockCallback(data);
        require(paid == used, "unsettled");
    }
    function swap(PoolKey calldata, SwapParams calldata params, bytes calldata) external returns (int256) {
        used = uint256(-params.amountSpecified); if (partialFill) used /= 2;
        int128 input = -int128(int256(used)); int128 output = int128(int256(used * 2));
        int128 d0 = params.zeroForOne ? input : output; int128 d1 = params.zeroForOne ? output : input;
        return (int256(d0) << 128) | int256(uint256(uint128(d1)));
    }
    function sync(address currency) external { synced = currency; beforeSync = IERC20(currency).balanceOf(address(this)); }
    function settle() external payable returns (uint256 amount) {
        amount = msg.value > 0 ? msg.value : IERC20(synced).balanceOf(address(this)) - beforeSync;
        paid = amount;
    }
    function take(address currency, address to, uint256 amount) external {
        if (currency == address(0)) { (bool ok,) = to.call{value: amount}(""); require(ok); }
        else require(IERC20(currency).transfer(to, amount));
    }
}
contract V4ExecutionTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token a; Token b; Wrapped weth; MockManager manager; V4Adapter adapter;
    function setUp() public {
        a = new Token("A"); b = new Token("B"); weth = new Wrapped(); manager = new MockManager(); adapter = new V4Adapter(address(manager), address(weth));
        a.mint(address(this), 100 ether); b.mint(address(manager), 100 ether); a.approve(address(adapter), type(uint256).max);
        weth.mint(address(this), 100 ether); weth.approve(address(adapter), type(uint256).max);
        vm.deal(address(weth), 100 ether); vm.deal(address(manager), 100 ether);
    }
    function testERC20ExactInput() public { require(adapter.swap(address(a), address(b), 1 ether, 500, 10, address(0), false) == 2 ether); require(a.balanceOf(address(adapter)) == 0 && b.balanceOf(address(adapter)) == 0); }
    function testNativePoolInput() public { require(adapter.swap(address(weth), address(b), 1 ether, 500, 10, address(0), true) == 2 ether); require(address(adapter).balance == 0); }
    function testNativePoolOutput() public { require(adapter.swap(address(a), address(weth), 1 ether, 500, 10, address(0), true) == 2 ether); require(address(adapter).balance == 0); }
    function testCallbackRequiresPoolManager() public { vm.expectRevert(V4Adapter.UnauthorizedCallback.selector); adapter.unlockCallback(""); }
    function testCallbackRequiresActiveSwap() public { vm.prank(address(manager)); vm.expectRevert(V4Adapter.UnauthorizedCallback.selector); adapter.unlockCallback(""); }
    function testCallbackDataBound() public { manager.behavior(false, true, false); vm.expectRevert(V4Adapter.UnauthorizedCallback.selector); adapter.swap(address(a), address(b), 1 ether, 500, 10, address(0), false); }
    function testCallbackSingleUse() public { manager.behavior(false, false, true); vm.expectRevert(V4Adapter.UnauthorizedCallback.selector); adapter.swap(address(a), address(b), 1 ether, 500, 10, address(0), false); }
    function testPartialFillRejected() public { manager.behavior(true, false, false); vm.expectRevert(V4Adapter.InvalidSwap.selector); adapter.swap(address(a), address(b), 1 ether, 500, 10, address(0), false); }
    function testUnreviewedHooksRejected() public { vm.expectRevert(V4Adapter.InvalidSwap.selector); adapter.swap(address(a), address(b), 1 ether, 500, 10, address(0x80), false); }
    function testDonationsPreserved() public { a.mint(address(adapter), 10); b.mint(address(adapter), 20); adapter.swap(address(a), address(b), 1 ether, 500, 10, address(0), false); require(a.balanceOf(address(adapter)) == 10 && b.balanceOf(address(adapter)) == 20); }
    function testTaxedInputRejected() public { TaxToken tax = new TaxToken(); tax.mint(address(this), 1 ether); tax.approve(address(adapter), 1 ether); vm.expectRevert(V4Adapter.UnsupportedToken.selector); adapter.swap(address(tax), address(b), 1 ether, 500, 10, address(0), false); }
    function testInvalidNativePoolRejected() public { vm.expectRevert(V4Adapter.InvalidSwap.selector); adapter.swap(address(a), address(b), 1 ether, 500, 10, address(0), true); }
    function testLargeInputRejected() public { vm.expectRevert(V4Adapter.InvalidSwap.selector); adapter.swap(address(a), address(b), 1 << 127, 500, 10, address(0), false); }
}
