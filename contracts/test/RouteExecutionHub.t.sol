// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {RouteExecutionHub} from "../RouteExecutionHub.sol";
import {RouteExecutor} from "../RouteExecutor.sol";
import {RouteMetaExecutor} from "../RouteMetaExecutor.sol";
import {V2Adapter} from "../adapters/V2Adapter.sol";
import {Token, TaxToken, Wrapped, MockDex, Vm, RejectNative} from "./Route.t.sol";
import {MockUpstream} from "./RouteMetaExecutor.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract HubReentry {
    RouteExecutionHub public executor;
    bool public prevented;

    constructor(RouteExecutionHub value) {
        executor = value;
    }

    receive() external payable {
        try executor.swap(address(0), address(1), 1, 1, address(this), block.timestamp, bytes("")) {
            revert("reentered");
        } catch (bytes memory reason) {
            prevented = bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()"));
        }
    }
}

contract RouteExecutionHubTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Token a;
    Token b;
    Wrapped weth;
    MockDex dex;
    V2Adapter adapter;
    RouteExecutor route;
    RouteMetaExecutor meta;
    MockUpstream upstream;
    RouteExecutionHub fees;
    address user = address(0xBEEF);
    address treasury = address(0xFEE);
    address next = address(0xCAFE);

    function setUp() public {
        a = new Token("A");
        b = new Token("B");
        weth = new Wrapped();
        dex = new MockDex();
        adapter = new V2Adapter("test", address(dex));
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        route = new RouteExecutor(address(weth), adapters, address(0));
        upstream = new MockUpstream();
        meta = new RouteMetaExecutor(address(upstream), MockUpstream.swap.selector);
        fees = new RouteExecutionHub(
            address(weth),
            adapters,
            address(0),
            address(upstream),
            MockUpstream.swap.selector,
            address(this),
            treasury
        );
        dex.setRate(address(a), address(b), 2e18);
        dex.setRate(address(weth), address(b), 2e18);
        dex.setRate(address(a), address(weth), 2e18);
        a.mint(user, 1e32);
        b.mint(address(dex), 1e32);
        b.mint(address(upstream), 1e32);
        weth.mint(address(dex), 1e32);
        vm.deal(user, 100 ether);
        vm.deal(address(weth), 100 ether);
        vm.deal(address(upstream), 100 ether);
        vm.prank(user);
        a.approve(address(fees), type(uint256).max);
    }

    function plan(uint256 amount, address output)
        internal
        view
        returns (RouteExecutor.Branch[] memory p)
    {
        p = new RouteExecutor.Branch[](1);
        p[0].amountIn = amount;
        p[0].legs = new RouteExecutor.Leg[](1);
        p[0].legs[0] = RouteExecutor.Leg(address(adapter), output, 0, 0, address(0), false);
    }

    function payload(address input, address output, uint256 amount, uint256 payout)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(MockUpstream.swap, (input, output, amount, payout, address(fees)));
    }

    function testDirectFeeAndExactApprovals() public {
        vm.prank(user);
        uint256 out = fees.swap(
            address(a),
            address(b),
            1 ether,
            1.997 ether,
            user,
            block.timestamp,
            plan(1 ether, address(b))
        );
        require(
            out == 1.997 ether && b.balanceOf(user) == out && b.balanceOf(treasury) == 0.003 ether
        );
        require(a.allowance(address(fees), address(adapter)) == 0);
        require(a.balanceOf(address(fees)) == 0 && b.balanceOf(address(fees)) == 0);
    }

    function testMetaFeeAndExactApprovals() public {
        vm.prank(user);
        uint256 out = fees.swap(
            address(a),
            address(b),
            1 ether,
            1.997 ether,
            user,
            block.timestamp,
            payload(address(a), address(b), 1 ether, 2 ether)
        );
        require(
            out == 1.997 ether && b.balanceOf(treasury) == 0.003 ether && b.balanceOf(user) == out
        );
        require(a.allowance(address(fees), address(upstream)) == 0);
    }

    function testNoFeeOrInputLossWhenNetMinimumFails() public {
        uint256 beforeInput = a.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(RouteExecutor.SlippageExceeded.selector);
        fees.swap(
            address(a),
            address(b),
            1 ether,
            2 ether,
            user,
            block.timestamp,
            plan(1 ether, address(b))
        );
        require(
            b.balanceOf(treasury) == 0 && a.balanceOf(user) == beforeInput && b.balanceOf(user) == 0
        );
    }

    function testMetaNetMinimumFailsAtomically() public {
        vm.prank(user);
        vm.expectRevert(RouteMetaExecutor.SlippageExceeded.selector);
        fees.swap(
            address(a),
            address(b),
            1 ether,
            2 ether,
            user,
            block.timestamp,
            payload(address(a), address(b), 1 ether, 2 ether)
        );
        require(b.balanceOf(treasury) == 0);
    }

    function testDirectNativeInput() public {
        vm.prank(user);
        fees.swap{value: 1 ether}(
            address(0), address(b), 1 ether, 1, user, block.timestamp, plan(1 ether, address(b))
        );
        require(b.balanceOf(treasury) == 0.003 ether && b.balanceOf(user) == 1.997 ether);
    }

    function testDirectNativeOutput() public {
        uint256 beforeUser = user.balance;
        vm.prank(user);
        fees.swap(
            address(a),
            address(0),
            1 ether,
            1.997 ether,
            user,
            block.timestamp,
            plan(1 ether, address(weth))
        );
        require(user.balance == beforeUser + 1.997 ether && treasury.balance == 0.003 ether);
    }

    function testMetaNativeInput() public {
        vm.prank(user);
        fees.swap{value: 1 ether}(
            address(0),
            address(b),
            1 ether,
            1,
            user,
            block.timestamp,
            payload(address(0), address(b), 1 ether, 2 ether)
        );
        require(b.balanceOf(treasury) == 0.003 ether);
    }

    function testMetaNativeOutput() public {
        uint256 beforeUser = user.balance;
        vm.prank(user);
        fees.swap(
            address(a),
            address(0),
            1 ether,
            1.997 ether,
            user,
            block.timestamp,
            payload(address(a), address(0), 1 ether, 2 ether)
        );
        require(user.balance == beforeUser + 1.997 ether && treasury.balance == 0.003 ether);
    }

    function testSplitFeeRoundedOnceOnTotal() public {
        RouteExecutor.Branch[] memory p = new RouteExecutor.Branch[](2);
        p[0] = plan(200, address(b))[0];
        p[1] = plan(200, address(b))[0];
        vm.prank(user);
        uint256 out = fees.swap(address(a), address(b), 400, 799, user, block.timestamp, p);
        require(out == 799 && b.balanceOf(treasury) == 1);
    }

    function testDustFeeRoundsDown() public {
        vm.prank(user);
        require(
            fees.swap(
                    address(a), address(b), 333, 666, user, block.timestamp, plan(333, address(b))
                ) == 666
        );
        require(b.balanceOf(treasury) == 0);
    }

    function testOwnerCanRedirectBothPaths() public {
        fees.setFeeRecipient(next);
        vm.prank(user);
        fees.swap(
            address(a), address(b), 1 ether, 1, user, block.timestamp, plan(1 ether, address(b))
        );
        vm.prank(user);
        fees.swap(
            address(a),
            address(b),
            1 ether,
            1,
            user,
            block.timestamp,
            payload(address(a), address(b), 1 ether, 2 ether)
        );
        require(
            b.balanceOf(treasury) == 0 && b.balanceOf(next) == 0.006 ether && fees.FEE_BPS() == 15
        );
    }

    function testOtherWalletCannotRedirect() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        fees.setFeeRecipient(user);
    }

    function testInvalidFeeRecipientsRejected() public {
        address[5] memory invalid =
            [address(0), address(fees), address(upstream), address(weth), address(adapter)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(RouteExecutionHub.InvalidFeeRecipient.selector);
            fees.setFeeRecipient(invalid[i]);
        }
    }

    function testTwoStepAdminTransfer() public {
        fees.transferOwnership(next);
        require(fees.owner() == address(this) && fees.pendingOwner() == next);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        fees.acceptOwnership();
        vm.prank(next);
        fees.acceptOwnership();
        require(fees.owner() == next && fees.pendingOwner() == address(0));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        fees.setFeeRecipient(user);
        vm.prank(next);
        fees.setFeeRecipient(user);
        require(fees.feeRecipient() == user);
    }

    function testAdminRenounceDisabled() public {
        vm.expectRevert(RouteExecutionHub.RenounceDisabled.selector);
        fees.renounceOwnership();
    }

    function testUserCanAlsoBeTreasury() public {
        fees.setFeeRecipient(user);
        vm.prank(user);
        uint256 out = fees.swap(
            address(a), address(b), 1 ether, 1, user, block.timestamp, plan(1 ether, address(b))
        );
        require(out == 1.997 ether && b.balanceOf(user) == 2 ether);
    }

    function testDonationsNotChargedOrSpent() public {
        a.mint(address(fees), 7);
        b.mint(address(fees), 9);
        vm.deal(address(fees), 11);
        vm.prank(user);
        fees.swap(
            address(a), address(b), 1 ether, 1, user, block.timestamp, plan(1 ether, address(b))
        );
        require(
            a.balanceOf(address(fees)) == 7 && b.balanceOf(address(fees)) == 9
                && address(fees).balance == 11 && b.balanceOf(treasury) == 0.003 ether
        );
    }

    function testRejectingTreasuryRevertsAll() public {
        fees.setFeeRecipient(address(new RejectNative()));
        uint256 beforeInput = a.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(RouteExecutionHub.NativeTransferFailed.selector);
        fees.swap(
            address(a), address(0), 1 ether, 1, user, block.timestamp, plan(1 ether, address(weth))
        );
        require(a.balanceOf(user) == beforeInput);
    }

    function testRejectingUserRevertsFee() public {
        RejectNative receiver = new RejectNative();
        vm.prank(user);
        vm.expectRevert(RouteExecutionHub.NativeTransferFailed.selector);
        fees.swap(
            address(a),
            address(0),
            1 ether,
            1,
            address(receiver),
            block.timestamp,
            plan(1 ether, address(weth))
        );
        require(treasury.balance == 0);
    }

    function testTreasuryReentryBlocked() public {
        HubReentry receiver = new HubReentry(fees);
        fees.setFeeRecipient(address(receiver));
        vm.prank(user);
        fees.swap(
            address(a), address(0), 1 ether, 1, user, block.timestamp, plan(1 ether, address(weth))
        );
        require(receiver.prevented() && address(receiver).balance == 0.003 ether);
    }

    function testTaxedInputRejected() public {
        TaxToken tax = new TaxToken();
        tax.mint(user, 1 ether);
        vm.prank(user);
        tax.approve(address(fees), 1 ether);
        vm.prank(user);
        vm.expectRevert(RouteExecutionHub.UnsupportedToken.selector);
        fees.swap(
            address(tax), address(b), 1 ether, 1, user, block.timestamp, plan(1 ether, address(b))
        );
    }

    function testExpiredSwapPaysNoFee() public {
        vm.warp(100);
        vm.prank(user);
        vm.expectRevert(RouteExecutionHub.DeadlineExpired.selector);
        fees.swap(address(a), address(b), 1 ether, 1, user, 99, plan(1 ether, address(b)));
        require(b.balanceOf(treasury) == 0);
    }

    function testFuzzFeeAndNetInverse(uint128 grossInput) public view {
        uint256 gross = uint256(grossInput) + 1;
        uint256 fee = fees.feeFor(gross);
        uint256 net = gross - fee;
        require(fee == gross * 15 / 10000);
        uint256 required = fees.grossForNet(net);
        require(required <= gross && required - fees.feeFor(required) >= net);
        if (required > 0) {
            require(required - 1 - fees.feeFor(required - 1) < net);
        }
    }

    function testFeeDoesNotOverflowUint256() public view {
        require(
            fees.feeFor(type(uint256).max)
                == type(uint256).max / 10000 * 15 + (type(uint256).max % 10000) * 15 / 10000
        );
    }

    function testMetaCannotRedirectOutput() public {
        bytes memory data =
            abi.encodeCall(MockUpstream.swap, (address(a), address(b), 1 ether, 2 ether, next));
        vm.prank(user);
        vm.expectRevert(RouteExecutionHub.SlippageExceeded.selector);
        fees.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, data);
        require(b.balanceOf(next) == 0 && b.balanceOf(treasury) == 0);
    }

    function testMetaCannotSpendDonatedInput() public {
        a.mint(address(fees), 10 ether);
        vm.prank(user);
        vm.expectRevert(RouteExecutionHub.UpstreamReverted.selector);
        fees.swap(
            address(a),
            address(b),
            1 ether,
            1,
            user,
            block.timestamp,
            payload(address(a), address(b), 2 ether, 2 ether)
        );
        require(a.balanceOf(address(fees)) == 10 ether);
    }

    function testMetaPartialFillRejectedAtomically() public {
        uint256 beforeInput = a.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(RouteExecutionHub.UnsupportedToken.selector);
        fees.swap(
            address(a),
            address(b),
            1 ether,
            1,
            user,
            block.timestamp,
            payload(address(a), address(b), 0.5 ether, 2 ether)
        );
        require(a.balanceOf(user) == beforeInput && b.balanceOf(treasury) == 0);
    }

    function testWrongUpstreamSelectorRejected() public {
        vm.prank(user);
        vm.expectRevert(RouteExecutionHub.InvalidRoute.selector);
        fees.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, hex"12345678");
    }

    function testNativeValueMismatchRejected() public {
        vm.prank(user);
        vm.expectRevert(RouteExecutionHub.InvalidAmount.selector);
        fees.swap{value: 1}(
            address(a),
            address(b),
            1 ether,
            1,
            user,
            block.timestamp,
            payload(address(a), address(b), 1 ether, 2 ether)
        );
    }

    function testUnknownAdapterRejected() public {
        RouteExecutor.Branch[] memory p = plan(1 ether, address(b));
        p[0].legs[0].adapter = address(upstream);
        vm.prank(user);
        vm.expectRevert(RouteExecutionHub.InvalidRoute.selector);
        fees.swap(address(a), address(b), 1 ether, 1, user, block.timestamp, p);
    }

    function testInvalidAllocationRejected() public {
        vm.prank(user);
        vm.expectRevert(RouteExecutionHub.InvalidAmount.selector);
        fees.swap(
            address(a), address(b), 1 ether, 1, user, block.timestamp, plan(2 ether, address(b))
        );
    }

    function testMetaDonationsPreserved() public {
        a.mint(address(fees), 7);
        b.mint(address(fees), 9);
        vm.deal(address(fees), 11);
        vm.prank(user);
        fees.swap(
            address(a),
            address(b),
            1 ether,
            1,
            user,
            block.timestamp,
            payload(address(a), address(b), 1 ether, 2 ether)
        );
        require(
            a.balanceOf(address(fees)) == 7 && b.balanceOf(address(fees)) == 9
                && address(fees).balance == 11
        );
    }

    function testDirectNativeTransfersRejectedWhileIdle() public {
        vm.prank(user);
        (bool ok,) = address(fees).call{value: 1}("");
        require(!ok);
    }

    function testFuzzActualDirectAndMetaFees(uint96 raw) public {
        uint256 amount = uint256(raw) + 1;
        uint256 gross = amount * 2;
        uint256 expectedFee = gross * 15 / 10000;
        vm.prank(user);
        uint256 directOut = fees.swap(
            address(a), address(b), amount, 1, user, block.timestamp, plan(amount, address(b))
        );
        vm.prank(user);
        uint256 metaOut = fees.swap(
            address(a),
            address(b),
            amount,
            1,
            user,
            block.timestamp,
            payload(address(a), address(b), amount, gross)
        );
        require(directOut == gross - expectedFee && metaOut == directOut);
        require(
            b.balanceOf(treasury) == expectedFee * 2
                && a.allowance(address(fees), address(upstream)) == 0
        );
    }
}
