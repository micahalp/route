// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IOrvexManager {
    struct Key { address currency0; address currency1; address hooks; address poolManager; uint24 fee; bytes32 parameters; }
    struct Params { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
    function swap(Key calldata key, Params calldata params, bytes calldata hookData) external returns (int256);
}
interface IOrvexVault {
    function lock(bytes calldata data) external returns (bytes memory);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}
interface IOrvexWrapped is IERC20 { function deposit() external payable; function withdraw(uint256 amount) external; }

/// @notice Research only: one source-verified Orvex WETH/USDG pool, either direction.
/// @dev No production registration or deployment. No router, Permit2, external approval,
/// owner, configurable target or quoter dependency. Full simulation is the quote probe.
contract RouteOrvexProbe is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    address public constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant MANAGER = 0xd01C774d4A66408326Bc65728Ac5Ae5aAf004032;
    address public constant VAULT = 0xFe7E25dE55e5cBbEcCcb661F3679F873f72B9b0D;
    address public constant HOOK = 0x51854e4BAA4A7c9653B52e42021F1B2B35D31651;
    bytes32 private transient pending;
    error InvalidSwap();
    error CallbackRejected();
    error DeadlineExpired();
    error SlippageExceeded();
    error UnsupportedToken();
    error NativeTransferFailed();

    receive() external payable { if (msg.sender != WETH) revert CallbackRejected(); }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minimum, address recipient, uint256 deadline)
        external payable nonReentrant returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        address input = tokenIn == address(0) ? WETH : tokenIn;
        address output = tokenOut == address(0) ? WETH : tokenOut;
        if (block.chainid != 4663 || amountIn == 0 || amountIn > uint256(uint128(type(int128).max)) || minimum == 0 ||
            recipient == address(0) || recipient == address(this) ||
            !((input == WETH && output == USDG) || (input == USDG && output == WETH)) ||
            msg.value != (tokenIn == address(0) ? amountIn : 0)) revert InvalidSwap();
        if (MANAGER.codehash != 0xabcccba7b2c0339035fab45b93950740b990e1ff74a4c5d576fb82c65a93a29f ||
            VAULT.codehash != 0x678bab6ace02b3fc508054b194f3f70190a0621f51bcae69be33cc5416031908 ||
            HOOK.codehash != 0x6e7e39c29fb7e77b2d3549654b8f35c01b47b2fe266ae7f7b658891696cb9c5b) revert InvalidSwap();
        uint256 nativeBefore = address(this).balance - msg.value;
        uint256 wrappedBefore = IERC20(WETH).balanceOf(address(this));
        uint256 recipientBefore = tokenOut == address(0) ? 0 : IERC20(output).balanceOf(recipient);
        uint256 senderBefore = tokenIn == address(0) ? 0 : IERC20(input).balanceOf(msg.sender);
        if (tokenIn == address(0)) IOrvexWrapped(WETH).deposit{value: amountIn}();
        bytes memory data = abi.encode(tokenIn, tokenOut, amountIn, minimum, recipient, msg.sender);
        pending = keccak256(data);
        amountOut = abi.decode(IOrvexVault(VAULT).lock(data), (uint256));
        if (pending != bytes32(0)) revert CallbackRejected();
        if (tokenOut == address(0)) {
            IOrvexWrapped(WETH).withdraw(amountOut);
            (bool ok,) = recipient.call{value: amountOut}("");
            if (!ok) revert NativeTransferFailed();
        }
        if (address(this).balance != nativeBefore || IERC20(WETH).balanceOf(address(this)) != wrappedBefore) revert UnsupportedToken();
        if (tokenIn != address(0) && IERC20(input).balanceOf(msg.sender) + amountIn != senderBefore) revert UnsupportedToken();
        // Native delivery is the exact-value successful call above. A receiver
        // may forward that ETH; its retained balance is not proof of delivery.
        if (tokenOut != address(0) && IERC20(output).balanceOf(recipient) != recipientBefore + amountOut) revert UnsupportedToken();
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != VAULT || pending == bytes32(0) || pending != keccak256(data)) revert CallbackRejected();
        pending = bytes32(0);
        (address tokenIn, address tokenOut, uint256 amountIn, uint256 minimum, address recipient, address payer) =
            abi.decode(data, (address, address, uint256, uint256, address, address));
        bool zeroForOne = tokenIn == WETH || tokenIn == address(0);
        IOrvexManager.Key memory key = IOrvexManager.Key(WETH, USDG, HOOK, MANAGER, 8388608, bytes32(uint256(0x3c0042)));
        int256 delta = IOrvexManager(MANAGER).swap(key, IOrvexManager.Params(zeroForOne, -int256(amountIn),
            zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341), "");
        int128 d0 = int128(delta >> 128);
        int128 d1 = int128(delta);
        int128 paid = zeroForOne ? d0 : d1;
        int128 received = zeroForOne ? d1 : d0;
        if (paid >= 0 || received <= 0 || uint256(-int256(paid)) != amountIn) revert InvalidSwap();
        uint256 amountOut = uint256(uint128(received));
        if (amountOut < minimum) revert SlippageExceeded();
        address input = zeroForOne ? WETH : USDG;
        IOrvexVault(VAULT).sync(input);
        if (tokenIn == address(0)) IERC20(input).safeTransfer(VAULT, amountIn);
        else IERC20(input).safeTransferFrom(payer, VAULT, amountIn);
        if (IOrvexVault(VAULT).settle() != amountIn) revert UnsupportedToken();
        IOrvexVault(VAULT).take(zeroForOne ? USDG : WETH, tokenOut == address(0) ? address(this) : recipient, amountOut);
        return abi.encode(amountOut);
    }
}
