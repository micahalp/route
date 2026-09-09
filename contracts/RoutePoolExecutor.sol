// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {V3Adapter, IV3Router} from "./adapters/V3Adapter.sol";
import {V2Adapter, IV2Router} from "./adapters/V2Adapter.sol";
import {IRouteAdapter} from "./interfaces/IRouteAdapter.sol";
import {V4Adapter} from "./adapters/V4Adapter.sol";
import {IRamsesRouter, IRamsesFactory} from "./interfaces/IRamsesRouter.sol";

interface IRamsesWrapped is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface ILeanV2Router {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface ILeanV2Factory {
    function getPair(address, address) external view returns (address);
}

interface ILeanV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface ILeanV3Pool {
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
}

interface ILeanV3Router {
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

interface ILeanV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256, uint256, address, bytes calldata) external;
}

/// @notice Fee-free settlement through fixed routers, canonical pools and approved adapters.
/// @dev No owner or upgrades. Direct V3 payments require an authenticated pool callback.
contract RoutePoolExecutor is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Leg {
        address adapter;
        address tokenOut;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bool nativePool;
    }

    struct Branch {
        uint256 amountIn;
        Leg[] legs;
    }
    IRamsesWrapped public immutable wrappedNative;
    address public immutable v4Adapter;
    address public immutable fastV3Adapter;
    address public immutable fastV3Router;
    address public immutable fastV3PoolFactory;
    address private transient callbackPool;
    address private transient callbackInput;
    uint256 private transient callbackAmount;
    uint256 private transient callbackOutput;
    bool private transient callbackZeroForOne;
    address public immutable fastV2Adapter;
    address public immutable fastV2Router;
    address public immutable fastV2PairFactory;
    address public immutable ramsesRouter;
    address public immutable ramsesFactory;
    uint96 private immutable fastV3Fees;
    mapping(address => bool) public allowedAdapter;
    error InvalidRoute();
    error InvalidAmount();
    error DeadlineExpired();
    error UnsupportedToken();
    error SlippageExceeded();
    error NativeTransferFailed();
    error CallbackRejected();
    event Swapped(
        address indexed sender,
        address indexed recipient,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 routeHash
    );

    constructor(
        address wrapped,
        address[] memory adapters,
        address v4,
        address fastV3,
        address fastV2,
        address ramses,
        address factory
    ) {
        if (wrapped.code.length == 0 || adapters.length == 0 || adapters.length > 16) {
            revert InvalidRoute();
        }
        wrappedNative = IRamsesWrapped(wrapped);
        for (uint256 i; i < adapters.length; ++i) {
            if (adapters[i].code.length == 0 || allowedAdapter[adapters[i]]) {
                revert InvalidRoute();
            }
            allowedAdapter[adapters[i]] = true;
        }
        if (v4 != address(0) && !allowedAdapter[v4]) {
            revert InvalidRoute();
        }
        v4Adapter = v4;
        fastV3Adapter = fastV3;
        address target;
        uint96 configuredFees;
        if (fastV3 != address(0)) {
            if (!allowedAdapter[fastV3] || fastV3 == v4) {
                revert InvalidRoute();
            }
            target = V3Adapter(fastV3).dexRouter();
            if (target.code.length == 0) {
                revert InvalidRoute();
            }
            // Snapshot the immutable V3 adapter configuration, not caller data.
            for (uint256 i; i < 4; ++i) {
                try V3Adapter(fastV3).feeTiers(i) returns (uint24 fee) {
                    if (fee == 0 || fee >= 1_000_000) {
                        revert InvalidRoute();
                    }
                    configuredFees |= uint96(uint256(fee) << (i * 24));
                } catch {
                    break;
                }
            }
            if (configuredFees == 0) {
                revert InvalidRoute();
            }
        }
        fastV3Router = target;
        address poolFactory;
        if (
            block.chainid == 4663 && target == 0xCaf681a66D020601342297493863E78C959E5cb2
                && target.codehash
                    == 0x6f36c378e272c6324c48f045182bcb54bd8ad654cf9ebd42e8893d52c4cb25dc
        ) {
            poolFactory = ILeanV3Router(target).factory();
            if (
                poolFactory != 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA
                    || poolFactory.codehash
                        != 0xec72b1abd1f2faee020cfea9c646bd8994f9fb389054f6e574f103a895091739
                    || ILeanV3Router(target).WETH9() != wrapped
            ) {
                revert InvalidRoute();
            }
        }
        fastV3PoolFactory = poolFactory;
        fastV3Fees = configuredFees;
        fastV2Adapter = fastV2;
        address targetV2;
        if (fastV2 != address(0)) {
            if (!allowedAdapter[fastV2] || fastV2 == v4 || fastV2 == fastV3) {
                revert InvalidRoute();
            }
            targetV2 = V2Adapter(fastV2).dexRouter();
            if (targetV2.code.length == 0) {
                revert InvalidRoute();
            }
        }
        fastV2Router = targetV2;
        // Direct V2 swaps require this reviewed implementation's 997/1000 fee math.
        address pairFactory;
        if (
            block.chainid == 4663 && targetV2 == 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba
                && targetV2.codehash
                    == 0xbd55ea26b2f8d42a8ff151511cef92a326a9817686899fe96a8a8f81ee7fc55e
        ) {
            pairFactory = ILeanV2Router(targetV2).factory();
            if (
                pairFactory != 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f
                    || pairFactory.codehash
                        != 0xbab145d02e7005f0d84c6c1639d39b799b0ea16df99ebbdaf5a14d9da820b4e0
                    || ILeanV2Router(targetV2).WETH() != wrapped
            ) {
                revert InvalidRoute();
            }
        }
        fastV2PairFactory = pairFactory;
        if (
            !allowedAdapter[ramses] || ramses == v4 || ramses == fastV2 || ramses == fastV3
                || factory.code.length == 0
        ) {
            revert InvalidRoute();
        }
        address deployer = IRamsesRouter(ramses).deployer();
        if (
            deployer.code.length == 0 || IRamsesRouter(ramses).WETH9() != wrapped
                || IRamsesFactory(factory).ramsesV3PoolDeployer() != deployer
        ) {
            revert InvalidRoute();
        }
        ramsesRouter = ramses;
        ramsesFactory = factory;
    }

    receive() external payable {
        if (msg.sender != address(wrappedNative)) {
            revert InvalidRoute();
        }
    }

    function isFastV3Fee(uint24 fee) public view returns (bool) {
        if (fee == 0) {
            return false;
        }
        uint96 configured = fastV3Fees;
        for (uint256 i; i < 4; ++i) {
            if (uint24(configured) == fee) {
                return true;
            }
            configured >>= 24;
        }
        return false;
    }

    // Virtual only for isolated mock-pool tests; production has no setter.
    function _v2PairFactory() internal view virtual returns (address) {
        return fastV2PairFactory;
    }

    function _v3PoolFactory() internal view virtual returns (address) {
        return fastV3PoolFactory;
    }

    function _poolSwap(address factory, address input, address output, uint24 fee, uint256 amount)
        private
        returns (uint256 out)
    {
        if (amount == 0 || amount > uint256(type(int256).max)) {
            revert InvalidAmount();
        }
        address pool = ILeanV3Factory(factory).getPool(input, output, fee);
        if (pool.code.length == 0) {
            revert InvalidRoute();
        }
        callbackPool = pool;
        callbackInput = input;
        callbackAmount = amount;
        callbackZeroForOne = input < output;
        ILeanV3Pool(pool)
            .swap(
                address(this),
                input < output,
                int256(amount),
                input < output ? 4295128740 : 1461446703485210103287273052203988822378723970341,
                ""
            );
        if (callbackPool != address(0) || callbackAmount != 0) {
            revert CallbackRejected();
        }
        out = callbackOutput;
        delete callbackInput;
        delete callbackOutput;
        delete callbackZeroForOne;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
        external
    {
        if (msg.sender != callbackPool || callbackPool == address(0) || data.length != 0) {
            revert CallbackRejected();
        }
        int256 owed = callbackZeroForOne ? amount0Delta : amount1Delta;
        int256 received = callbackZeroForOne ? amount1Delta : amount0Delta;
        if (
            owed <= 0 || received >= 0 || received == type(int256).min
                || uint256(owed) != callbackAmount
        ) {
            revert CallbackRejected();
        }
        callbackOutput = uint256(-received);
        address token = callbackInput;
        delete callbackPool;
        delete callbackAmount;
        uint256 beforePool = IERC20(token).balanceOf(msg.sender);
        IERC20(token).safeTransfer(msg.sender, uint256(owed));
        if (IERC20(token).balanceOf(msg.sender) != beforePool + uint256(owed)) {
            revert UnsupportedToken();
        }
    }

    function _pairSwap(address factory, address input, address output, uint256 amount)
        private
        returns (uint256 out)
    {
        if (amount == 0 || amount > type(uint112).max) {
            revert InvalidAmount();
        }
        address pair = ILeanV2Factory(factory).getPair(input, output);
        if (pair.code.length == 0) {
            revert InvalidRoute();
        }
        (uint112 r0, uint112 r1,) = ILeanV2Pair(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            input < output ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (reserveIn == 0 || reserveOut == 0) {
            revert SlippageExceeded();
        }
        uint256 effective = amount * 997;
        out = effective * reserveOut / (reserveIn * 1000 + effective);
        if (out == 0) {
            revert SlippageExceeded();
        }
        uint256 beforePair = IERC20(input).balanceOf(pair);
        IERC20(input).safeTransfer(pair, amount);
        if (IERC20(input).balanceOf(pair) != beforePair + amount) {
            revert UnsupportedToken();
        }
        ILeanV2Pair(pair)
            .swap(input < output ? 0 : out, input < output ? out : 0, address(this), "");
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline,
        Branch[] calldata branches
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) {
            revert DeadlineExpired();
        }
        address input = tokenIn == address(0) ? address(wrappedNative) : tokenIn;
        address output = tokenOut == address(0) ? address(wrappedNative) : tokenOut;
        if (
            input == output || input.code.length == 0 || output.code.length == 0
                || recipient == address(0) || recipient == address(this)
        ) {
            revert InvalidRoute();
        }
        if (amountIn == 0 || minOut == 0 || msg.value != (tokenIn == address(0) ? amountIn : 0)) {
            revert InvalidAmount();
        }
        if (branches.length == 0 || branches.length > 4) {
            revert InvalidRoute();
        }
        uint256 sum;
        for (uint256 b; b < branches.length; ++b) {
            Branch calldata branch = branches[b];
            if (branch.amountIn == 0 || branch.legs.length == 0 || branch.legs.length > 4) {
                revert InvalidRoute();
            }
            sum += branch.amountIn;
            address previous = input;
            for (uint256 h; h < branch.legs.length; ++h) {
                Leg calldata leg = branch.legs[h];
                if (
                    !allowedAdapter[leg.adapter] || leg.tokenOut.code.length == 0
                        || leg.tokenOut == input || leg.tokenOut == previous
                ) {
                    revert InvalidRoute();
                }
                for (uint256 j; j < h; ++j) {
                    if (branch.legs[j].tokenOut == leg.tokenOut) {
                        revert InvalidRoute();
                    }
                }
                if (leg.adapter == ramsesRouter) {
                    // fee is unused for this family; spacing identifies the pool.
                    if (
                        leg.fee != 0 || leg.tickSpacing <= 0 || leg.tickSpacing > 32767
                            || leg.hooks != address(0) || leg.nativePool
                    ) {
                        revert InvalidRoute();
                    }
                } else if (
                    leg.adapter != v4Adapter
                        && (leg.tickSpacing != 0 || leg.hooks != address(0) || leg.nativePool)
                ) {
                    revert InvalidRoute();
                }
                previous = leg.tokenOut;
            }
            if (previous != output) {
                revert InvalidRoute();
            }
        }
        if (sum != amountIn) {
            revert InvalidAmount();
        }
        uint256 beforeInput = IERC20(input).balanceOf(address(this));
        uint256 beforeOutput = IERC20(output).balanceOf(address(this));
        if (tokenIn == address(0)) {
            wrappedNative.deposit{value: amountIn}();
        } else {
            IERC20(input).safeTransferFrom(msg.sender, address(this), amountIn);
        }
        if (IERC20(input).balanceOf(address(this)) != beforeInput + amountIn) {
            revert UnsupportedToken();
        }
        for (uint256 b; b < branches.length; ++b) {
            address current = input;
            uint256 amount = branches[b].amountIn;
            for (uint256 h; h < branches[b].legs.length; ++h) {
                Leg calldata leg = branches[b].legs[h];
                uint256 startInput = IERC20(current).balanceOf(address(this));
                uint256 startOutput = IERC20(leg.tokenOut).balanceOf(address(this));
                address spender = leg.adapter == fastV3Adapter
                    ? fastV3Router
                    : leg.adapter == fastV2Adapter ? fastV2Router : leg.adapter;
                address pairFactory = leg.adapter == fastV2Adapter ? _v2PairFactory() : address(0);
                address poolFactory = leg.adapter == fastV3Adapter ? _v3PoolFactory() : address(0);
                uint256 expectedDirectOutput;
                if (pairFactory == address(0) && poolFactory == address(0)) {
                    IERC20(current).forceApprove(spender, amount);
                }
                if (pairFactory != address(0)) {
                    if (leg.fee != 0) {
                        revert InvalidRoute();
                    }
                    expectedDirectOutput = _pairSwap(pairFactory, current, leg.tokenOut, amount);
                } else if (poolFactory != address(0)) {
                    if (!isFastV3Fee(leg.fee)) {
                        revert InvalidRoute();
                    }
                    expectedDirectOutput =
                        _poolSwap(poolFactory, current, leg.tokenOut, leg.fee, amount);
                } else if (leg.adapter == ramsesRouter) {
                    // Ramses authenticates its callback; balance deltas determine the output.
                    IRamsesRouter(ramsesRouter)
                        .exactInputSingle(
                            IRamsesRouter.Params(
                                current,
                                leg.tokenOut,
                                leg.tickSpacing,
                                address(this),
                                deadline,
                                amount,
                                1,
                                0
                            )
                        );
                } else if (leg.adapter == fastV3Adapter) {
                    if (!isFastV3Fee(leg.fee)) {
                        revert InvalidRoute();
                    }
                    IV3Router(fastV3Router)
                        .exactInputSingle(
                            IV3Router.Params(
                                current, leg.tokenOut, leg.fee, address(this), amount, 1, 0
                            )
                        );
                } else if (leg.adapter == fastV2Adapter) {
                    if (leg.fee != 0) {
                        revert InvalidRoute();
                    }
                    address[] memory path = new address[](2);
                    path[0] = current;
                    path[1] = leg.tokenOut;
                    IV2Router(fastV2Router)
                        .swapExactTokensForTokens(amount, 1, path, address(this), block.timestamp);
                } else if (leg.adapter == v4Adapter) {
                    V4Adapter(payable(v4Adapter))
                        .swap(
                            current,
                            leg.tokenOut,
                            amount,
                            leg.fee,
                            leg.tickSpacing,
                            leg.hooks,
                            leg.nativePool
                        );
                } else {
                    IRouteAdapter(leg.adapter).swap(current, leg.tokenOut, amount, 1, leg.fee);
                }
                if (pairFactory == address(0) && poolFactory == address(0)) {
                    IERC20(current).forceApprove(spender, 0);
                }
                if (IERC20(current).balanceOf(address(this)) != startInput - amount) {
                    revert UnsupportedToken();
                }
                amount = IERC20(leg.tokenOut).balanceOf(address(this)) - startOutput;
                if (
                    (pairFactory != address(0) || poolFactory != address(0))
                        && amount != expectedDirectOutput
                ) {
                    revert UnsupportedToken();
                }
                if (amount == 0) {
                    revert SlippageExceeded();
                }
                current = leg.tokenOut;
            }
        }
        if (IERC20(input).balanceOf(address(this)) != beforeInput) {
            revert UnsupportedToken();
        }
        amountOut = IERC20(output).balanceOf(address(this)) - beforeOutput;
        if (amountOut < minOut) {
            revert SlippageExceeded();
        }
        if (tokenOut == address(0)) {
            wrappedNative.withdraw(amountOut);
            (bool ok,) = recipient.call{value: amountOut}("");
            if (!ok) {
                revert NativeTransferFailed();
            }
        } else {
            uint256 beforeRecipient = IERC20(output).balanceOf(recipient);
            IERC20(output).safeTransfer(recipient, amountOut);
            if (IERC20(output).balanceOf(recipient) != beforeRecipient + amountOut) {
                revert UnsupportedToken();
            }
        }
        if (IERC20(output).balanceOf(address(this)) != beforeOutput) {
            revert UnsupportedToken();
        }
        emit Swapped(
            msg.sender,
            recipient,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            keccak256(abi.encode(branches))
        );
    }
}
