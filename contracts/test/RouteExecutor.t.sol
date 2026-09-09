// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteExecutor} from "../RouteExecutor.sol";
import {V4Adapter, IRoutePoolManager} from "../adapters/V4Adapter.sol";
import {RouteTest, Token, TaxToken, Wrapped, MockDex, Vm} from "./Route.t.sol";
import {V2Adapter} from "../adapters/V2Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RouteExecutorTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token a; Token b; Token c; Token d; Wrapped weth;
    MockDex dex1; MockDex dex2; V2Adapter v1; V2Adapter v2; RouteExecutor router;
    address user = address(0xBEEF);
    function deployExecutor(address wrapped, address[] memory venues) internal virtual returns (RouteExecutor) {
        return new RouteExecutor(wrapped, venues, address(0));
    }
    function setUp() public virtual {
        a = new Token("A"); b = new Token("B"); c = new Token("C"); d = new Token("D"); weth = new Wrapped();
        dex1 = new MockDex(); dex2 = new MockDex(); v1 = new V2Adapter("one", address(dex1)); v2 = new V2Adapter("two", address(dex2));
        address[] memory venues = new address[](2); venues[0] = address(v1); venues[1] = address(v2);
        router = deployExecutor(address(weth), venues);
        dex1.setRate(address(a), address(b), 2e18); dex2.setRate(address(a), address(b), 3e18);
        dex1.setRate(address(a), address(c), 2e18); dex2.setRate(address(c), address(d), 2e18); dex1.setRate(address(d), address(b), 2e18);
        dex1.setRate(address(weth), address(b), 2e18); dex1.setRate(address(b), address(weth), 1e18);
        for (uint256 i; i < 2; ++i) { address dex = i == 0 ? address(dex1) : address(dex2); a.mint(dex, 1e32); b.mint(dex, 1e32); c.mint(dex, 1e32); d.mint(dex, 1e32); weth.mint(dex, 1e32); }
        a.mint(user, 1e30); b.mint(user, 1e30); vm.prank(user); a.approve(address(router), type(uint256).max); vm.prank(user); b.approve(address(router), type(uint256).max);
        vm.deal(user, 100 ether); vm.deal(address(weth), 100 ether);
    }
    function leg(address adapter, address output) internal pure returns (RouteExecutor.Leg memory) { return RouteExecutor.Leg(adapter, output, 0, 0, address(0), false); }
    function direct(uint256 amount) internal view returns (RouteExecutor.Branch[] memory p) {
        p = new RouteExecutor.Branch[](1); p[0].amountIn = amount; p[0].legs = new RouteExecutor.Leg[](1); p[0].legs[0] = leg(address(v1), address(b));
    }
    function testSplitAndClearApprovals() public {
        RouteExecutor.Branch[] memory p = new RouteExecutor.Branch[](2);
        p[0] = direct(4 ether)[0]; p[1] = direct(6 ether)[0]; p[1].legs[0].adapter = address(v2);
        vm.prank(user); uint256 out = router.swap(address(a), address(b), 10 ether, 26 ether, user, block.timestamp, p);
        require(out == 26 ether && a.allowance(address(router), address(v1)) == 0 && a.allowance(address(router), address(v2)) == 0);
    }
    function testThreeHopsPreserveDonations() public {
        RouteExecutor.Branch[] memory p = direct(1 ether); p[0].legs = new RouteExecutor.Leg[](3);
        p[0].legs[0] = leg(address(v1), address(c)); p[0].legs[1] = leg(address(v2), address(d)); p[0].legs[2] = leg(address(v1), address(b));
        a.mint(address(router), 7); b.mint(address(router), 8); c.mint(address(router), 9); d.mint(address(router), 10);
        vm.prank(user); require(router.swap(address(a), address(b), 1 ether, 8 ether, user, block.timestamp, p) == 8 ether);
        require(a.balanceOf(address(router)) == 7 && b.balanceOf(address(router)) == 8 && c.balanceOf(address(router)) == 9 && d.balanceOf(address(router)) == 10);
    }
    function testBadAllocationRejected() public { vm.prank(user); vm.expectRevert(RouteExecutor.InvalidAmount.selector); router.swap(address(a), address(b), 2 ether, 1, user, block.timestamp, direct(1 ether)); }
    function testUnknownAdapterRejected() public { RouteExecutor.Branch[] memory p = direct(1); p[0].legs[0].adapter = address(dex1); vm.prank(user); vm.expectRevert(RouteExecutor.InvalidRoute.selector); router.swap(address(a), address(b), 1, 1, user, block.timestamp, p); }
    function testWrongOutputRejected() public { RouteExecutor.Branch[] memory p = direct(1); p[0].legs[0].tokenOut = address(c); vm.prank(user); vm.expectRevert(RouteExecutor.InvalidRoute.selector); router.swap(address(a), address(b), 1, 1, user, block.timestamp, p); }
    function testZeroMinimumRejected() public { vm.prank(user); vm.expectRevert(RouteExecutor.InvalidAmount.selector); router.swap(address(a), address(b), 1, 0, user, block.timestamp, direct(1)); }
    function testExpiredRejected() public { vm.warp(100); vm.prank(user); vm.expectRevert(RouteExecutor.DeadlineExpired.selector); router.swap(address(a), address(b), 1, 1, user, 99, direct(1)); }
    function testFinalSlippageRevertsAll() public { uint256 beforeBalance = a.balanceOf(user); vm.prank(user); vm.expectRevert(RouteExecutor.SlippageExceeded.selector); router.swap(address(a), address(b), 1 ether, 3 ether, user, block.timestamp, direct(1 ether)); require(a.balanceOf(user) == beforeBalance); }
    function testNativeInput() public { vm.prank(user); require(router.swap{value: 1 ether}(address(0), address(b), 1 ether, 2 ether, user, block.timestamp, direct(1 ether)) == 2 ether); }
    function testNativeOutput() public { RouteExecutor.Branch[] memory p = direct(1 ether); p[0].legs[0].tokenOut = address(weth); uint256 beforeBalance = user.balance; vm.prank(user); router.swap(address(b), address(0), 1 ether, 1 ether, user, block.timestamp, p); require(user.balance == beforeBalance + 1 ether); }
    function testTaxedInputRejected() public { TaxToken tax = new TaxToken(); tax.mint(user, 1 ether); vm.prank(user); tax.approve(address(router), 1 ether); vm.prank(user); vm.expectRevert(RouteExecutor.UnsupportedToken.selector); router.swap(address(tax), address(b), 1 ether, 1, user, block.timestamp, direct(1 ether)); }
    function testCycleRejected() public { RouteExecutor.Branch[] memory p = direct(1); p[0].legs = new RouteExecutor.Leg[](2); p[0].legs[0] = leg(address(v1), address(c)); p[0].legs[1] = leg(address(v2), address(a)); vm.prank(user); vm.expectRevert(RouteExecutor.InvalidRoute.selector); router.swap(address(a), address(b), 1, 1, user, block.timestamp, p); }
    function testNonV4ParametersRejected() public { RouteExecutor.Branch[] memory p = direct(1); p[0].legs[0].nativePool = true; vm.prank(user); vm.expectRevert(RouteExecutor.InvalidRoute.selector); router.swap(address(a), address(b), 1, 1, user, block.timestamp, p); }
    function testFuzzSplitExactInput(uint96 input, uint8 fraction) public {
        uint256 amount = uint256(input) + 2; uint256 left = amount * (uint256(fraction) % 99 + 1) / 100;
        if (left == 0 || left == amount) return;
        RouteExecutor.Branch[] memory p = new RouteExecutor.Branch[](2); p[0] = direct(left)[0]; p[1] = direct(amount - left)[0]; p[1].legs[0].adapter = address(v2);
        uint256 beforeBalance = a.balanceOf(user); vm.prank(user); uint256 out = router.swap(address(a), address(b), amount, 1, user, block.timestamp, p);
        require(beforeBalance - a.balanceOf(user) == amount && out == left * 2 + (amount - left) * 3);
    }
}
