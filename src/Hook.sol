// ./src/Hook.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseHook} from "../lib/v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "../lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "../lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "../lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "../lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "../lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "../lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencyLibrary, Currency} from "../lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "../lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "../lib/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "../lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "../lib/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "../lib/v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";

import {IPool} from "./interfaces/IPool.sol";
import {ITellerWithMultiAssetSupport} from "./interfaces/ITellerWithMultiAssetSupport.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/**
 * @title Hook
 * @notice Demonstrates a Just-In-Time liquidity strategy:
 *         1) During addLiquidity, 25% goes to Aave, 75% goes to Veda aggregator.
 *         2) During swaps, we withdraw from Aave, add narrow-range liquidity, then remove it post-swap.
 */
contract Hook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    /// @notice Address of a mocked lending protocol, e.g. Aave.
    IPool public lendingProtocol;
    /// @notice A mock aggregator that receives 75% of tokens upon deposit.
    ITellerWithMultiAssetSupport public vedaTeller;

    bool private liquidityInitialized;

    /// @dev The ratio that is staked into Aave in addLiquidity. (25% => Aave)
    uint256 internal constant AAVE_PERCENT = 25;
    /// @dev The ratio that is staked into Veda aggregator in addLiquidity. (75% => Veda)
    uint256 internal constant VEDA_PERCENT = 75;

    /// @dev These ticks define the ephemeral JIT range inserted during a swap.
    int24 public tickLower;
    int24 public tickUpper;

    /// @dev Tracks how much liquidity is currently added in the ephemeral range.
    uint128 private liquidityAdded;

    /// @dev Optional record-keeping for user aggregator shares.
    mapping(address => mapping(address => uint256)) public userTokenShares;
    mapping(address => uint256) public totalTokenShares;

    error PoolNotInitialized();

    /**
     * @notice Params used when adding liquidity to the aggregator.
     */
    struct LiquidityParams {
        uint24 fee;
        Currency currency0;
        Currency currency1;
        uint256 amount0;
        uint256 amount1;
        PoolKey key;
    }

    /**
     * @notice Sets up the Hook contract, linking it to a PoolManager, an Aave-like lending protocol, and a Veda aggregator.
     * @param _manager Reference to the Uniswap v4 PoolManager.
     * @param _lendingProtocol Mocked Aave pool.
     * @param _vedaTeller Mocked aggregator for Veda.
     */
    constructor(
        IPoolManager _manager,
        address _lendingProtocol,
        address _vedaTeller
    ) BaseHook(_manager) {
        lendingProtocol = IPool(_lendingProtocol);
        vedaTeller = ITellerWithMultiAssetSupport(_vedaTeller);
    }

    /**
     * @notice Returns the required hook permissions for this contract.
     * @return Hooks.Permissions Memory struct detailing which hook functions are enabled.
     */
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /**
     * @notice Allows a user to add liquidity to the aggregator. Splits deposits into Aave (25%) and Veda aggregator (75%).
     * @param params Struct detailing the token amounts, fee, and poolKey details.
     */
    function addLiquidity(LiquidityParams calldata params) external {
        require(
            params.amount0 > 0 || params.amount1 > 0,
            "No tokens to deposit"
        );

        // Pull tokens from the user => this contract.
        address asset0 = Currency.unwrap(params.currency0);
        address asset1 = Currency.unwrap(params.currency1);

        if (params.amount0 > 0) {
            bool ok0 = IERC20(asset0).transferFrom(
                msg.sender,
                address(this),
                params.amount0
            );
            require(ok0, "transferFrom(token0) failed");
        }
        if (params.amount1 > 0) {
            bool ok1 = IERC20(asset1).transferFrom(
                msg.sender,
                address(this),
                params.amount1
            );
            require(ok1, "transferFrom(token1) failed");
        }

        // Calculate how much goes to Aave vs. Veda aggregator.
        uint256 toAave0 = (params.amount0 * AAVE_PERCENT) / 100;
        uint256 toAave1 = (params.amount1 * AAVE_PERCENT) / 100;
        uint256 toVeda0 = (params.amount0 * VEDA_PERCENT) / 100;
        uint256 toVeda1 = (params.amount1 * VEDA_PERCENT) / 100;

        // Supply the appropriate portion to Aave (if non-zero).
        if (toAave0 > 0) {
            IERC20(asset0).approve(address(lendingProtocol), toAave0);
            try lendingProtocol.supply(asset0, toAave0, address(this), 0) {
                // No additional action on success
            } catch {
                // Swallow any error for demonstration
            }
        }
        if (toAave1 > 0) {
            IERC20(asset1).approve(address(lendingProtocol), toAave1);
            try lendingProtocol.supply(asset1, toAave1, address(this), 0) {
                // No additional action on success
            } catch {
                // Swallow any error for demonstration
            }
        }

        // Deposit the rest into Veda aggregator.
        if (toVeda0 > 0) {
            IERC20(asset0).approve(address(vedaTeller), toVeda0);
            vedaTeller.deposit(asset0, toVeda0, 1);
        }
        if (toVeda1 > 0) {
            IERC20(asset1).approve(address(vedaTeller), toVeda1);
            vedaTeller.deposit(asset1, toVeda1, 1);
        }

        // Optional record-keeping of how many tokens user contributed.
        userTokenShares[msg.sender][asset0] += params.amount0;
        userTokenShares[msg.sender][asset1] += params.amount1;
        totalTokenShares[asset0] += params.amount0;
        totalTokenShares[asset1] += params.amount1;
    }

    /**
     * @notice Hook function called by the PoolManager before liquidity is added.
     * @dev Ensures that liquidity is initialized properly.
     */
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        require(
            !liquidityInitialized || sender == address(this),
            "Add Liquidity through Hook"
        );
        liquidityInitialized = true;
        return this.beforeAddLiquidity.selector;
    }

    /**
     * @notice Hook function called by the PoolManager before a swap occurs.
     * @dev Withdraws from Aave and provides a short-range JIT liquidity position, if available.
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata hookData
    )
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Check if the pool is initialized
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            key.toId()
        );
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // If the user provided custom ticks, decode them. Otherwise, set a narrow range around currentTick.
        if (hookData.length > 0) {
            (tickLower, tickUpper) = abi.decode(hookData, (int24, int24));
        } else {
            int24 finalTickLower = (currentTick / 60) * 60;
            int24 finalTickUpper = finalTickLower + 60;
            tickLower = finalTickLower;
            tickUpper = finalTickUpper;
        }

        // Attempt to withdraw aggregator's balance from Aave for both tokens.
        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        // Retrieve aggregator's Aave balances via staticcall
        (bool success0, bytes memory data0) = address(lendingProtocol)
            .staticcall(
                abi.encodeWithSignature(
                    "suppliedBalances(address,address)",
                    asset0,
                    address(this)
                )
            );
        uint256 aaveBalance0 = 0;
        if (success0 && data0.length >= 32) {
            aaveBalance0 = abi.decode(data0, (uint256));
        }

        (bool success1, bytes memory data1) = address(lendingProtocol)
            .staticcall(
                abi.encodeWithSignature(
                    "suppliedBalances(address,address)",
                    asset1,
                    address(this)
                )
            );
        uint256 aaveBalance1 = 0;
        if (success1 && data1.length >= 32) {
            aaveBalance1 = abi.decode(data1, (uint256));
        }

        // Perform actual withdraw calls from Aave, ignoring any failure
        if (aaveBalance0 > 0) {
            try
                lendingProtocol.withdraw(asset0, aaveBalance0, address(this))
            returns (uint256) {
                // Withdraw succeeded
            } catch {
                // Silence errors in this mock scenario
            }
        }
        if (aaveBalance1 > 0) {
            try
                lendingProtocol.withdraw(asset1, aaveBalance1, address(this))
            returns (uint256) {
                // Withdraw succeeded
            } catch {
                // Silence errors in this mock scenario
            }
        }

        // Determine the current token balances after withdrawal
        uint256 bal0 = IERC20(asset0).balanceOf(address(this));
        uint256 bal1 = IERC20(asset1).balanceOf(address(this));

        // Calculate how much liquidity can be formed with these balances and the desired tick range
        liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            bal0,
            bal1
        );

        // If we can add liquidity, proceed with modifyLiquidity
        if (liquidityAdded > 0) {
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int128(liquidityAdded),
                    salt: bytes32(0)
                }),
                hookData
            );

            // If negative delta => aggregator owes tokens to the pool
            int256 amt0 = delta.amount0();
            if (amt0 < 0) {
                uint256 owed0 = uint256(-amt0);
                key.currency0.settle(poolManager, address(this), owed0, false);
            }

            int256 amt1 = delta.amount1();
            if (amt1 < 0) {
                uint256 owed1 = uint256(-amt1);
                key.currency1.settle(poolManager, address(this), owed1, false);
            }
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Hook function called by the PoolManager after a swap has completed.
     * @dev Removes any ephemeral JIT liquidity and re-supplies the aggregator's final balances to Aave.
     */
    function afterSwap(
        address /*sender*/,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta deltaIn,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (liquidityAdded == 0) {
            // If no JIT liquidity was added, there's nothing to do
            return (this.afterSwap.selector, 0);
        }

        // Remove the JIT liquidity
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int128(liquidityAdded),
                salt: bytes32(0)
            }),
            hookData
        );

        // Take any owed tokens back to this contract
        if (delta.amount0() > 0) {
            uint256 amt0 = uint256(int256(delta.amount0()));
            key.currency0.take(poolManager, address(this), amt0, false);
        }
        if (delta.amount1() > 0) {
            uint256 amt1 = uint256(int256(delta.amount1()));
            key.currency1.take(poolManager, address(this), amt1, false);
        }

        // Re-supply leftover tokens to Aave
        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        uint256 finalBal0 = IERC20(asset0).balanceOf(address(this));
        uint256 finalBal1 = IERC20(asset1).balanceOf(address(this));

        if (finalBal0 > 0) {
            IERC20(asset0).approve(address(lendingProtocol), finalBal0);
            try lendingProtocol.supply(asset0, finalBal0, address(this), 0) {
                // No additional action on success
            } catch {
                // Silence errors in this mock scenario
            }
        }
        if (finalBal1 > 0) {
            IERC20(asset1).approve(address(lendingProtocol), finalBal1);
            try lendingProtocol.supply(asset1, finalBal1, address(this), 0) {
                // No additional action on success
            } catch {
                // Silence errors in this mock scenario
            }
        }

        // Reset the local tracking
        liquidityAdded = 0;

        return (this.afterSwap.selector, 0);
    }

    /**
     * @notice Returns the lower tick used in the ephemeral JIT range.
     * @return The current stored tickLower value.
     */
    function getTickLower() external view returns (int24) {
        return tickLower;
    }

    /**
     * @notice Returns the upper tick used in the ephemeral JIT range.
     * @return The current stored tickUpper value.
     */
    function getTickUpper() external view returns (int24) {
        return tickUpper;
    }
}
