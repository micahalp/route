// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Route} from "../Route.sol";
import {V2Adapter} from "../adapters/V2Adapter.sol";
import {BaseAdapter} from "../adapters/BaseAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface Vm {
    function deal(address who, uint256 value) external;
    function prank(address who) external;
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata data) external;
    function expectRevert() external;
    function warp(uint256 timestamp) external;
}

contract Token is ERC20 {
    constructor(string memory symbol) ERC20(symbol, symbol) {}
    function mint(address to, uint256 value) external { _mint(to, value); }
}

contract TaxToken is Token {
    constructor() Token("TAX") {}
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            super._update(from, address(0), value / 100);
            value -= value / 100;
        }
        super._update(from, to, value);
    }
}

contract Wrapped is Token {
    constructor() Token("WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 value) external {
        _burn(msg.sender, value);
        (bool ok,) = msg.sender.call{value: value}("");
        require(ok);
    }
}

contract MockDex {
    mapping(address => mapping(address => uint256)) public rate;
    bool public failQuote;
    bool public failSwap;
    uint256 public executionBps = 10000;
    function setRate(address a, address b, uint256 r) external { rate[a][b] = r; }
    function setFailure(bool q, bool s) external { failQuote = q; failSwap = s; }
    function setExecution(uint256 bps) external { executionBps = bps; }
    function getAmountsOut(uint256 amount, address[] calldata path) external view returns (uint256[] memory amounts) {
        require(!failQuote && rate[path[0]][path[1]] != 0);
        amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount * rate[path[0]][path[1]] / 1e18;
    }
    function swapExactTokensForTokens(uint256 amount, uint256 minOut, address[] calldata path, address to, uint256 deadline)
        external virtual returns (uint256[] memory amounts)
    {
        require(!failSwap && block.timestamp <= deadline);
        uint256 output = amount * rate[path[0]][path[1]] / 1e18 * executionBps / 10000;
        require(output >= minOut);
        IERC20(path[0]).transferFrom(msg.sender, address(this), amount);
        IERC20(path[1]).transfer(to, output);
        amounts = new uint256[](2);
        amounts[0] = amount; amounts[1] = output;
    }
}

contract RejectNative { receive() external payable { revert(); } }

contract ReenterNative {
    Route immutable router;
    bool public prevented;
    constructor(Route r) { router = r; }
    receive() external payable {
        try router.quote(address(0), address(1), 1) { revert("reentered"); }
        catch { prevented = true; }
    }
}

contract RouteTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token a; Token b; Token c; Wrapped weth;
    MockDex dex1; MockDex dex2;
    V2Adapter v1; V2Adapter v2;
    Route router;
    address user = address(0xBEEF);

    function setUp() public {
        a = new Token("A"); b = new Token("B"); c = new Token("C"); weth = new Wrapped();
        dex1 = new MockDex(); dex2 = new MockDex();
        v1 = new V2Adapter("exchange one", address(dex1)); v2 = new V2Adapter("exchange two", address(dex2));
        address[] memory venues = new address[](2); venues[0] = address(v1); venues[1] = address(v2);
        address[] memory bridges = new address[](1); bridges[0] = address(c);
        router = new Route(address(weth), venues, bridges);
        dex1.setRate(address(a), address(b), 2e18); dex2.setRate(address(a), address(b), 3e18);
        for (uint256 i; i < 2; ++i) {
            address dex = i == 0 ? address(dex1) : address(dex2);
            a.mint(dex, 1e32); b.mint(dex, 1e32); c.mint(dex, 1e32); weth.mint(dex, 1e32);
        }
        a.mint(user, 1e30); b.mint(user, 1e30);
        vm.prank(user); a.approve(address(router), type(uint256).max);
        vm.prank(user); b.approve(address(router), type(uint256).max);
        vm.deal(user, 100 ether); vm.deal(address(weth), 100 ether);
    }

    function testBestDirectAcrossDexes() public {
        Route.Quote memory q = router.quote(address(a), address(b), 10 ether);
        require(q.amountOut == 30 ether && q.first.adapter == address(v2) && q.intermediate == address(0));
    }
    function testCrossDexTwoHop() public {
        dex1.setRate(address(a), address(c), 2e18);
        dex2.setRate(address(c), address(b), 2e18);
        Route.Quote memory q = router.quote(address(a), address(b), 10 ether);
        require(q.amountOut == 40 ether && q.intermediate == address(c));
        require(q.first.adapter == address(v1) && q.second.adapter == address(v2));
        uint256 beforeOut = b.balanceOf(user);
        vm.prank(user); router.swap(address(a), address(b), 10 ether, 39 ether, user, block.timestamp);
        require(b.balanceOf(user) == beforeOut + 40 ether);
        require(c.balanceOf(address(router)) == 0);
    }
    function testRequotesAtExecution() public {
        router.quote(address(a), address(b), 10 ether);
        dex1.setRate(address(a), address(b), 4e18);
        uint256 beforeOut = b.balanceOf(user);
        vm.prank(user); uint256 result = router.swap(address(a), address(b), 10 ether, 29 ether, user, block.timestamp);
        require(result == 40 ether && b.balanceOf(user) == beforeOut + result);
    }
    function testExpiredReverts() public {
        vm.warp(100); vm.expectRevert(Route.DeadlineExpired.selector);
        vm.prank(user); router.swap(address(a), address(b), 1 ether, 1, user, 99);
    }
    function testSlippageRevertsAtomically() public {
        uint256 beforeIn = a.balanceOf(user);
        vm.expectRevert(abi.encodeWithSelector(Route.SlippageExceeded.selector, 3 ether, 4 ether));
        vm.prank(user); router.swap(address(a), address(b), 1 ether, 4 ether, user, block.timestamp);
        require(a.balanceOf(user) == beforeIn && a.balanceOf(address(router)) == 0);
    }
    function testExecutionShortfallRevertsAtomically() public {
        dex2.setExecution(9000);
        uint256 beforeIn = a.balanceOf(user);
        vm.expectRevert(); vm.prank(user);
        router.swap(address(a), address(b), 1 ether, 29e17, user, block.timestamp);
        require(a.balanceOf(user) == beforeIn && a.allowance(address(router), address(v2)) == 0);
    }
    function testApprovalsClearedAndDonationUntouched() public {
        a.mint(address(router), 7); b.mint(address(router), 9);
        a.mint(address(v2), 11); b.mint(address(v2), 13);
        vm.prank(user); router.swap(address(a), address(b), 1 ether, 2 ether, user, block.timestamp);
        require(a.allowance(address(router), address(v2)) == 0);
        require(a.allowance(address(v2), address(dex2)) == 0);
        require(a.balanceOf(address(router)) == 7 && b.balanceOf(address(router)) == 9);
        require(a.balanceOf(address(v2)) == 11 && b.balanceOf(address(v2)) == 13);
    }
    function testBrokenVenueSkipped() public {
        dex2.setFailure(true, false);
        Route.Quote memory q = router.quote(address(a), address(b), 1 ether);
        require(q.amountOut == 2 ether && q.first.adapter == address(v1));
    }
    function testNoRoute() public {
        vm.expectRevert(Route.NoRoute.selector); router.quote(address(b), address(a), 1 ether);
    }
    function testNativeIn() public {
        dex1.setRate(address(weth), address(b), 2e18);
        uint256 beforeOut = b.balanceOf(user);
        vm.prank(user); router.swap{value: 1 ether}(address(0), address(b), 1 ether, 1 ether, user, block.timestamp);
        require(b.balanceOf(user) == beforeOut + 2 ether && address(router).balance == 0);
    }
    function testNativeOut() public {
        dex1.setRate(address(a), address(weth), 1e18);
        uint256 beforeOut = user.balance;
        vm.prank(user); router.swap(address(a), address(0), 1 ether, 1 ether, user, block.timestamp);
        require(user.balance == beforeOut + 1 ether && address(router).balance == 0);
    }
    function testNativeRecipientRejectionRollsBack() public {
        dex1.setRate(address(a), address(weth), 1e18);
        RejectNative bad = new RejectNative();
        uint256 beforeIn = a.balanceOf(user);
        vm.expectRevert(Route.NativeTransferFailed.selector); vm.prank(user);
        router.swap(address(a), address(0), 1 ether, 1 ether, address(bad), block.timestamp);
        require(a.balanceOf(user) == beforeIn);
    }
    function testReentrancyPrevented() public {
        dex1.setRate(address(a), address(weth), 1e18);
        ReenterNative receiver = new ReenterNative(router);
        vm.prank(user); router.swap(address(a), address(0), 1 ether, 1 ether, address(receiver), block.timestamp);
        require(receiver.prevented());
    }
    function testWrongValueRejected() public {
        vm.expectRevert(Route.InvalidValue.selector); vm.prank(user);
        router.swap{value: 1}(address(a), address(b), 1 ether, 1, user, block.timestamp);
    }
    function testSameTokenAndZeroAmountRejected() public {
        vm.expectRevert(Route.InvalidPair.selector); router.quote(address(a), address(a), 1);
        vm.expectRevert(Route.InvalidPair.selector); router.quote(address(0), address(weth), 1);
        vm.expectRevert(Route.InvalidAmount.selector); router.quote(address(a), address(b), 0);
    }
    function testZeroMinimumAndBadRecipientRejected() public {
        vm.expectRevert(Route.InvalidAmount.selector); vm.prank(user);
        router.swap(address(a), address(b), 1, 0, user, block.timestamp);
        vm.expectRevert(Route.InvalidRecipient.selector); vm.prank(user);
        router.swap(address(a), address(b), 1, 1, address(router), block.timestamp);
    }
    function testTaxedInputRejected() public {
        TaxToken taxed = new TaxToken(); taxed.mint(user, 10 ether);
        vm.prank(user); taxed.approve(address(router), 10 ether);
        vm.expectRevert(Route.UnsupportedToken.selector); vm.prank(user);
        router.swap(address(taxed), address(b), 1 ether, 1, user, block.timestamp);
    }
    function testTaxedOutputRejected() public {
        TaxToken taxed = new TaxToken(); taxed.mint(address(dex1), 10 ether);
        dex1.setRate(address(a), address(taxed), 1e18);
        vm.expectRevert(BaseAdapter.UnsupportedToken.selector); vm.prank(user);
        router.swap(address(a), address(taxed), 1 ether, 0.5 ether, user, block.timestamp);
    }
    function testInvalidConfigurationRejected() public {
        address[] memory venues = new address[](2); venues[0] = address(v1); venues[1] = address(v1);
        vm.expectRevert(Route.InvalidConfiguration.selector); new Route(address(weth), venues, new address[](0));
    }
    function testFuzzConservation(uint96 seed) public {
        uint256 amount = uint256(seed) % 1e24 + 1;
        uint256 beforeIn = a.balanceOf(user); uint256 beforeOut = b.balanceOf(user);
        vm.prank(user); uint256 result = router.swap(address(a), address(b), amount, amount, user, block.timestamp);
        require(result == amount * 3 && a.balanceOf(user) == beforeIn - amount && b.balanceOf(user) == beforeOut + result);
        require(a.balanceOf(address(router)) == 0 && b.balanceOf(address(router)) == 0);
    }
}
