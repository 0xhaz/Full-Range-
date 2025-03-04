// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {UniswapV4ERC20} from "v4-periphery/libraries/UniswapV4ERC20.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

contract FullRange is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using StateLibrary for IPoolManager;

    /// @notice Thrown when trying to interact with non-initialized pool
    error PoolNotInitialized();
    error TickSpacingNotDefault();
    error LiquidityDoesntMeetMinimum();
    error SenderMustBeHook();
    error ExpiredPastDeadline();
    error TooMuchSlippage();

    bytes internal constant ZERO_BYTES = bytes("");

    /// @dev min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    int256 internal constant MAX_INT = type(int256).max;
    uint16 internal constant MINIMUM_LIQUIDITY = 1000;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    struct PoolInfo {
        bool hasAccruedFees;
        address liquidityToken;
    }

    struct AddLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 liquidity;
        uint256 deadline;
    }

    // @notice Mapping of poolId to poolInfo
    mapping(PoolId => PoolInfo) public poolInfo;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function addLiquidity(AddLiquidityParams calldata params)
        external
        ensure(params.deadline)
        returns (uint128 liquidity)
    {
        /// @notice PoolKey is a structure that uniquely identifies a liqudity pool by storing its details
        /// the 2 currencies involved(sorted numerically), the swap fee, tick spacing, and hooks (extra functionality) of the pool
        /// It acts as a unique identifier, ensuring that each pool can be precisely specified and accessed within the code
        PoolKey memory key = PoolKey({
            /// @notice The lower currency of the pool, sorted numerically
            currency0: params.currency0,
            /// @notice The higher currency of the pool, sorted numerically
            currency1: params.currency1,
            /// @notice The pool swap fee, capped at 1_000_000. The upper 4 bits determine if the hook sets any fees
            fee: params.fee,
            /// @notice Ticks that involve positions must be multiple of tick spacing
            tickSpacing: 60,
            /// @notice The hooks of the pool
            hooks: IHooks(address(this))
        });

        // Convert the PoolKey to a PoolId
        PoolId poolId = key.toId();

        // Fetch the price of the pool - sqrtPriceX96 is the square root of the price of the pool
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        // Ensure that the pool is initialized
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Fetch the pool information
        PoolInfo storage pool = poolInfo[poolId];

        /// @notice Fetch the liquidity of the pool
        uint128 poolLiquidity = manager.getLiquidity(poolId);

        /// @notice Computes the maximum amount of liquidity received for a given amount
        /// of token0, token1, the current pool prices and the prices at the tick boundaries
        /// @param sqrtRatioX96 A sqrt price representing the current pool prices
        /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
        /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
        /// @param amount0 The amount of token0 being sent in
        /// @param amount1 The amount of token1 being sent in
        /// @return liquidity The maximum amount of liquidity received
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            params.amount0Desired,
            params.amount1Desired
        );

        /// @notice Ensure that the liquidity meets the minimum threshold
        if (poolLiquidity == 0 && liquidity <= MINIMUM_LIQUIDITY) revert LiquidityDoesntMeetMinimum();

        /// @notice Delta represents the change in the pool's balances when liquidity is added
        BalanceDelta addedDelta = modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                // the lower and upper ticks of the position
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                // the amount of liquidity to add
                liquidityDelta: liquidity.toInt256(),
                // a value to set if you want unique liquidity positions at the same range
                salt: 0
            })
        );

        if (poolLiquidity == 0) {
            // permanently lock the first MINIMUM_LIQUIDITY tokens
            liquidity -= MINIMUM_LIQUIDITY;
            UniswapV4ERC20(pool.liquidityToken).mint(address(0), MINIMUM_LIQUIDITY);
        }

        UniswapV4ERC20(pool.liquidityToken).mint(params.to, liquidity);

        if (uint128(-addedDelta.amount0()) < params.amount0Min || uint128(-addedDelta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    function removeLiquidity(RemoveLiquidityParams calldata params)
        public
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        /// @notice PoolKey is a structure that uniquely identifies a liqudity pool by storing its details
        /// the 2 currencies involved(sorted numerically), the swap fee, tick spacing, and hooks (extra functionality) of the pool
        /// It acts as a unique identifier, ensuring that each pool can be precisely specified and accessed within the code
        PoolKey memory key = PoolKey({
            /// @notice The lower currency of the pool, sorted numerically
            currency0: params.currency0,
            /// @notice The higher currency of the pool, sorted numerically
            currency1: params.currency1,
            /// @notice The pool swap fee, capped at 1_000_000. The upper 4 bits determine if the hook sets any fees
            fee: params.fee,
            /// @notice Ticks that involve positions must be multiple of tick spacing
            tickSpacing: 60,
            /// @notice The hooks of the pool
            hooks: IHooks(address(this))
        });

        // Convert the PoolKey to a PoolId
        PoolId poolId = key.toId();

        // Fetch the price of the pool - sqrtPriceX96 is the square root of the price of the pool
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        UniswapV4ERC20 erc20 = UniswapV4ERC20(poolInfo[poolId].liquidityToken);

        delta = modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(params.liquidity.toInt256()),
                salt: 0
            })
        );

        erc20.burn(msg.sender, params.liquidity);
    }

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (key.tickSpacing != 60) revert TickSpacingNotDefault();

        PoolId poolId = key.toId();

        string memory tokenSymbol = string(
            abi.encodePacked(
                "UniV4",
                "-",
                IERC20Metadata(Currency.unwrap(key.currency0)).symbol(),
                "-",
                IERC20Metadata(Currency.unwrap(key.currency1)).symbol(),
                "-",
                Strings.toString(uint256(key.fee))
            )
        );

        address poolToken = address(new UniswapV4ERC20(tokenSymbol, tokenSymbol));

        poolInfo[poolId] = PoolInfo({hasAccruedFees: false, liquidityToken: poolToken});

        return FullRange.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        if (sender != address(this)) revert SenderMustBeHook();

        return FullRange.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        if (!poolInfo[poolId].hasAccruedFees) {
            PoolInfo storage pool = poolInfo[poolId];
            pool.hasAccruedFees = true;
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Modify the liquidity of a pool
     * @param key the pool key
     * @param params the liquidity modification parameters
     * @return delta the change in the pool's balances
     * @dev The abi.decode call is used to decode the BalanceDelta struct from the callback data
     */
    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));
    }

    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        /// @dev Used by users to pay off any outstanding amounts they owe, potentially a different currency
        // with the function returning the amount paid
        key.currency0.settle(manager, sender, uint256(int256(-delta.amount0())), false);
        key.currency1.settle(manager, sender, uint256(int256(-delta.amount1())), false);
    }

    function _takeDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        /// @dev This function allows user to withdraw or "net out" a specified amount of currency
        // which could be seen as a mechanism for zero-cost flash loans under certain conditions
        manager.take(key.currency0, sender, uint256(int256(delta.amount0())));
        manager.take(key.currency1, sender, uint256(int256(delta.amount1())));
    }

    function _removeLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        PoolInfo storage pool = poolInfo[poolId];

        if (pool.hasAccruedFees) {
            _rebalance(key);
        }

        uint256 liquidityToRemove = FullMath.mulDiv(
            uint256(-params.liquidityDelta),
            manager.getLiquidity(poolId),
            UniswapV4ERC20(pool.liquidityToken).totalSupply()
        );

        params.liquidityDelta = -(liquidityToRemove.toInt256());
        (delta,) = manager.modifyLiquidity(key, params, ZERO_BYTES);
        pool.hasAccruedFees = false;
    }

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            delta = _removeLiquidity(data.key, data.params);
            _takeDeltas(data.sender, data.key, delta);
        } else {
            (delta,) = manager.modifyLiquidity(data.key, data.params, ZERO_BYTES);
            _settleDeltas(data.sender, data.key, delta);
        }
        return abi.encode(delta);
    }

    function _rebalance(PoolKey memory key) public {
        PoolId poolId = key.toId();
        (BalanceDelta balanceDelta,) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(manager.getLiquidity(poolId).toInt256()),
                salt: 0
            }),
            ZERO_BYTES
        );

        uint160 newSqrtPriceX96 = (
            FixedPointMathLib.sqrt(
                FullMath.mulDiv(uint128(balanceDelta.amount1()), FixedPoint96.Q96, uint128(balanceDelta.amount0()))
            ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)
        ).toUint160();

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                amountSpecified: -MAX_INT - 1, // equivalent to type(int256).min
                sqrtPriceLimitX96: newSqrtPriceX96
            }),
            ZERO_BYTES
        );

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            newSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            uint256(uint128(balanceDelta.amount0())),
            uint256(uint128(balanceDelta.amount1()))
        );

        (BalanceDelta balanceDeltaAfter,) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256(),
                salt: 0
            }),
            ZERO_BYTES
        );

        // donate any "dust" from the sqrtRatio change as fee
        uint128 donateAmount0 = uint128(balanceDelta.amount0() + balanceDeltaAfter.amount0());
        uint128 donateAmount1 = uint128(balanceDelta.amount1() + balanceDeltaAfter.amount1());

        manager.donate(key, donateAmount0, donateAmount1, ZERO_BYTES);
    }
}
