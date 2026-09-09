// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {
    RouteFeeFlywheel,
    IFlywheelExecutor,
    IFlywheelFactory
} from "../experimental/RouteFeeFlywheel.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface FlyForkVm {
    function createSelectFork(string calldata, uint256) external returns (uint256);
    function deal(address, uint256) external;
    function prank(address) external;
}

interface FlyRealSafe {
    function nonce() external view returns (uint256);
    function getThreshold() external view returns (uint256);
    function approveHash(bytes32) external;
    function getTransactionHash(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address,
        uint256
    ) external view returns (bytes32);
    function execTransaction(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    ) external payable returns (bool);
}

interface FlyRealEscrow {
    function credit(address) external payable;
    function balanceOf(address) external view returns (uint256);
}

/// @dev Local fork only. Owner impersonation approves hashes; no real signatures or broadcasts.
contract RouteFeeFlywheelForkTest {
    FlyForkVm constant vm = FlyForkVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant SAFE = 0x3b9C7bC09FF64F554480f30Ad40286cFc09d2F80;
    address constant OPERATOR = 0xf5613936227559aD5BeefCf308eb024f20a7A1FC;
    address constant TOKEN = 0x4A72B9702f991b790788f8AFA9e7112541f4E8f8;
    address constant ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address constant FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant EXECUTOR = 0x22c1Bba36Ba220964D029Eb4B1eF7c6ed167E32E;
    address constant OWNER1 = 0xAd7f8d0e54693cCaC2478eAeE1e1C9e7F48EBf77;
    address constant OWNER2 = 0xf07321aA8518615Fcbf70c92a349266895bc202C;
    RouteFeeFlywheel wheel;

    function safeCall(bytes memory data) private {
        FlyRealSafe safe = FlyRealSafe(SAFE);
        bytes32 hash = safe.getTransactionHash(
            address(wheel), 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce()
        );
        vm.prank(OWNER1);
        safe.approveHash(hash);
        vm.prank(OWNER2);
        safe.approveHash(hash);
        bytes memory signatures = abi.encodePacked(
            bytes32(uint256(uint160(OWNER1))),
            bytes32(0),
            uint8(1),
            bytes32(uint256(uint160(OWNER2))),
            bytes32(0),
            uint8(1)
        );
        require(
            safe.execTransaction(
                address(wheel), 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures
            ),
            "Safe transaction failed"
        );
    }

    function testForkRealSafeEscrowExecutorAndRecipientHandover() public {
        vm.createSelectFork("https://rpc.mainnet.chain.robinhood.com", 57653510);
        require(block.chainid == 4663 && FlyRealSafe(SAFE).getThreshold() == 2);
        vm.prank(OPERATOR);
        wheel = new RouteFeeFlywheel(SAFE, OPERATOR, TOKEN, ESCROW, FACTORY, EXECUTOR);
        require(wheel.paused());
        vm.prank(0x6f6aFe1e23a59Cdc5901F2626301D6D408D72D9B);
        IFlywheelFactory(FACTORY).transferCreatorFeeRecipient(TOKEN, address(wheel));
        // Synthetic funding through the actual escrow, not claimed historical fee revenue.
        vm.deal(address(this), 1 ether);
        FlyRealEscrow(ESCROW).credit{value: 0.0001 ether}(address(wheel));
        RouteFeeFlywheel.Policy memory p = RouteFeeFlywheel.Policy(
            0.0001 ether, 0.0001 ether, 0.0001 ether, 300000 ether, 60, block.timestamp + 300
        );
        safeCall(abi.encodeCall(RouteFeeFlywheel.setPolicy, (p)));
        IFlywheelExecutor.Branch[] memory branches = new IFlywheelExecutor.Branch[](1);
        IFlywheelExecutor.Leg[] memory legs = new IFlywheelExecutor.Leg[](1);
        legs[0] = IFlywheelExecutor.Leg(
            0xd5Cdc1eFA4a625504b9E8792ee42776F16cDf09A, TOKEN, 9000, 90, address(0), true
        );
        branches[0] = IFlywheelExecutor.Branch(0.000065 ether, legs);
        uint256 ethBefore = SAFE.balance;
        uint256 tokensBefore = IERC20(TOKEN).balanceOf(SAFE);
        vm.prank(OPERATOR);
        uint256 received = wheel.execute(0, 0.0001 ether, 20 ether, block.timestamp + 60, branches);
        require(received >= 20 ether && IERC20(TOKEN).balanceOf(SAFE) == tokensBefore + received);
        require(SAFE.balance == ethBefore + 0.000035 ether && address(wheel).balance == 0);
        require(FlyRealEscrow(ESCROW).balanceOf(address(wheel)) == 0);
        safeCall(abi.encodeCall(RouteFeeFlywheel.pause, ()));
        safeCall(abi.encodeCall(RouteFeeFlywheel.handoverFeesToTreasury, ()));
    }
}
