// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOrvexManager, IOrvexVault} from "./RouteOrvexProbe.sol";

/// @dev Internal direct settlement, no adapter call, approval or extra custody.
/// Only the measured source-verified WETH/USDG pool is admitted in this prototype.
abstract contract OrvexVaultLeg {
    using SafeERC20 for IERC20;
    address public constant orvexManager = 0xd01C774d4A66408326Bc65728Ac5Ae5aAf004032;
    address public constant orvexVault = 0xFe7E25dE55e5cBbEcCcb661F3679F873f72B9b0D;
    address public constant orvexHook = 0x51854e4BAA4A7c9653B52e42021F1B2B35D31651;
    address public constant orvexWeth = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address public constant orvexUsdg = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 private transient orvexPending;
    error OrvexInvalidLeg();
    error OrvexCallbackRejected();
    error OrvexSettlementMismatch();

    function _assertOrvexRuntime() internal view {
        if (block.chainid != 4663 ||
            orvexManager.codehash != 0xabcccba7b2c0339035fab45b93950740b990e1ff74a4c5d576fb82c65a93a29f ||
            orvexVault.codehash != 0x678bab6ace02b3fc508054b194f3f70190a0621f51bcae69be33cc5416031908 ||
            orvexHook.codehash != 0x6e7e39c29fb7e77b2d3549654b8f35c01b47b2fe266ae7f7b658891696cb9c5b) revert OrvexInvalidLeg();
    }

    function _orvexSwap(address input, address output, uint256 amount) internal returns (uint256 out) {
        _assertOrvexRuntime();
        if (amount == 0 || amount > uint256(uint128(type(int128).max)) ||
            !((input == orvexWeth && output == orvexUsdg) || (input == orvexUsdg && output == orvexWeth))) revert OrvexInvalidLeg();
        bytes memory data = abi.encode(input, output, amount);
        orvexPending = keccak256(data);
        out = abi.decode(IOrvexVault(orvexVault).lock(data), (uint256));
        if (orvexPending != bytes32(0)) revert OrvexCallbackRejected();
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != orvexVault || orvexPending == bytes32(0) || keccak256(data) != orvexPending) revert OrvexCallbackRejected();
        orvexPending = bytes32(0);
        (address input, address output, uint256 amount) = abi.decode(data, (address, address, uint256));
        bool zeroForOne = input == orvexWeth;
        IOrvexManager.Key memory key = IOrvexManager.Key(orvexWeth, orvexUsdg, orvexHook, orvexManager, 8388608, bytes32(uint256(0x3c0042)));
        int256 delta = IOrvexManager(orvexManager).swap(key, IOrvexManager.Params(zeroForOne, -int256(amount),
            zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341), "");
        int128 d0 = int128(delta >> 128); int128 d1 = int128(delta);
        int128 paid = zeroForOne ? d0 : d1; int128 received = zeroForOne ? d1 : d0;
        if (paid >= 0 || received <= 0 || uint256(-int256(paid)) != amount) revert OrvexSettlementMismatch();
        uint256 out = uint256(uint128(received));
        IOrvexVault(orvexVault).sync(input);
        IERC20(input).safeTransfer(orvexVault, amount);
        if (IOrvexVault(orvexVault).settle() != amount) revert OrvexSettlementMismatch();
        IOrvexVault(orvexVault).take(output, address(this), out);
        return abi.encode(out);
    }
}
