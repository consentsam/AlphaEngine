// CODE_UPDATED_HERE: file path relative to your repo
// ./src/Hook.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// CODE_UPDATED_HERE: unify on OpenZeppelin's IERC20
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

import {console} from "forge-std/console.sol";

// CODE_UPDATED_HERE: Import your aggregator vault (HookVault)
import {HookVault} from "./HookVault.sol";

/**
 * @title Hook
 * @notice Demonstrates a Just-In-Time liquidity strategy, updated to unify IERC20 references using OpenZeppelin.
 */
contract Hook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    // ------------------------------------------------------------
    // CODE_UPDATED_HERE: aggregatorVault
    // ------------------------------------------------------------
    HookVault public aggregatorVault; // The multi-asset vault

    bool private liquidityInitialized;

    // ephemeral JIT range
    int24 public tickLower;
    int24 public tickUpper;
    uint128 private liquidityAdded;

    // Example user -> token => shares (just for your own tracking)
    mapping(address => mapping(address => uint256)) public userTokenShares;
    mapping(address => uint256) public totalTokenShares;

    error PoolNotInitialized();

    struct LiquidityParams {
        uint24 fee;
        Currency currency0;
        Currency currency1;
        uint256 amount0;
        uint256 amount1;
        PoolKey key;
    }

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------
    constructor(
        IPoolManager _manager,
        HookVault _aggregatorVault
    ) BaseHook(_manager) {
        aggregatorVault = _aggregatorVault;
    }

    /**
     * @notice Hook permissions
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

    // ------------------------------------------------------------
    // (A) addLiquidity => aggregatorVault
    // ------------------------------------------------------------
    function addLiquidity(LiquidityParams calldata params) external {
        console.log("Hook.addLiquidity() called by =>", msg.sender);

        require(
            params.amount0 > 0 || params.amount1 > 0,
            "No tokens to deposit"
        );

        // Identify the underlying token addresses
        address asset0 = Currency.unwrap(params.currency0);
        address asset1 = Currency.unwrap(params.currency1);

        console.log(" addLiquidity: asset0 =>", asset0);
        console.log(" addLiquidity: asset1 =>", asset1);

        // ------------------------------------------------------------
        // CODE_UPDATED_HERE: The Hook pulls tokens from the user -> Hook
        // then the Hook approves aggregatorVault, then aggregatorVault pulls from Hook
        // ------------------------------------------------------------

        // (1) If user wants to deposit token0
        if (params.amount0 > 0) {
            console.log(" aggregatorVault.deposit token0 =>", params.amount0);

            // Step A: transferFrom user => Hook
            IERC20(asset0).transferFrom(
                msg.sender,
                address(this),
                params.amount0
            );

            // Step B: Hook approves aggregatorVault
            IERC20(asset0).approve(address(aggregatorVault), params.amount0);

            // Step C: aggregatorVault.deposit(token0, address(this), amount0)
            aggregatorVault.deposit(
                IERC20(asset0),
                address(this),
                params.amount0
            );

            // Track user "virtual" shares
            userTokenShares[msg.sender][asset0] += params.amount0;
            totalTokenShares[asset0] += params.amount0;
        }

        // (2) If user wants to deposit token1
        if (params.amount1 > 0) {
            console.log(" aggregatorVault.deposit token1 =>", params.amount1);

            // Step A: transferFrom user => Hook
            IERC20(asset1).transferFrom(
                msg.sender,
                address(this),
                params.amount1
            );

            // Step B: Hook approves aggregatorVault
            IERC20(asset1).approve(address(aggregatorVault), params.amount1);

            // Step C: aggregatorVault.deposit(token1, address(this), amount1)
            aggregatorVault.deposit(
                IERC20(asset1),
                address(this),
                params.amount1
            );

            // Track user "virtual" shares
            userTokenShares[msg.sender][asset1] += params.amount1;
            totalTokenShares[asset1] += params.amount1;
        }
    }

    // Called by PoolManager
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        console.log("Hook.beforeAddLiquidity() => sender:", sender);
        require(
            !liquidityInitialized || sender == address(this),
            "Add Liquidity through Hook"
        );
        liquidityInitialized = true;
        return this.beforeAddLiquidity.selector;
    }

    // ------------------------------------------------------------
    // (B) removeLiquidity => aggregatorVault
    // Example only: you may want a more robust ratio-based approach
    // ------------------------------------------------------------
    function removeLiquidity(LiquidityParams calldata params) external {
        console.log("Hook.removeLiquidity() => user:", msg.sender);

        address asset0 = Currency.unwrap(params.currency0);
        address asset1 = Currency.unwrap(params.currency1);

        if (params.amount0 > 0) {
            console.log(" removeLiquidity => token0 amount:", params.amount0);

            uint256 userSh0 = userTokenShares[msg.sender][asset0];
            require(userSh0 >= params.amount0, "not enough user token0 shares");

            // Decrement user's "virtual" shares
            userTokenShares[msg.sender][asset0] = userSh0 - params.amount0;
            totalTokenShares[asset0] -= params.amount0;

            // aggregatorVault withdraw from the Hook's shares
            aggregatorVault.withdraw(
                IERC20(asset0),
                address(this),
                params.amount0
            );

            // Now the Hook has these tokens => transfer them to user
            IERC20(asset0).transfer(msg.sender, params.amount0);
        }

        if (params.amount1 > 0) {
            console.log(" removeLiquidity => token1 amount:", params.amount1);

            uint256 userSh1 = userTokenShares[msg.sender][asset1];
            require(userSh1 >= params.amount1, "not enough user token1 shares");

            // Decrement user's "virtual" shares
            userTokenShares[msg.sender][asset1] = userSh1 - params.amount1;
            totalTokenShares[asset1] -= params.amount1;

            aggregatorVault.withdraw(
                IERC20(asset1),
                address(this),
                params.amount1
            );

            // Now the Hook has these tokens => transfer them to user
            IERC20(asset1).transfer(msg.sender, params.amount1);
        }
    }

    // ------------------------------------------------------------
    // (C) BEFORE SWAP => aggregator withdraw for JIT
    // ------------------------------------------------------------
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
        console.log("Hook.beforeSwap() => caller:", sender);

        // 1) confirm pool is init
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            key.toId()
        );
        console.log("   sqrtPriceX96 =>", sqrtPriceX96);
        console.log("   currentTick =>", currentTick);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // 2) set ephemeral range
        if (hookData.length > 0) {
            (tickLower, tickUpper) = abi.decode(hookData, (int24, int24));
        } else {
            int24 finalTickLower = (currentTick / 60) * 60;
            int24 finalTickUpper = finalTickLower + 60;
            tickLower = finalTickLower;
            tickUpper = finalTickUpper;
        }
        console.log("   chosen tickLower =>", tickLower);
        console.log("   chosen tickUpper =>", tickUpper);

        // 3) aggregator withdraw all from aggregatorVault
        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);
        uint256 totalSh0 = aggregatorVault.totalShares(IERC20(asset0));
        uint256 totalSh1 = aggregatorVault.totalShares(IERC20(asset1));
        console.log("   aggregatorVault totalShares0 =>", totalSh0);
        console.log("   aggregatorVault totalShares1 =>", totalSh1);

        if (totalSh0 > 0) {
            console.log(" aggregatorVault.withdraw() all token0 =>", totalSh0);
            aggregatorVault.withdraw(IERC20(asset0), address(this), totalSh0);
        }
        if (totalSh1 > 0) {
            console.log(" aggregatorVault.withdraw() all token1 =>", totalSh1);
            aggregatorVault.withdraw(IERC20(asset1), address(this), totalSh1);
        }

        // 4) final balances => add short-range liquidity
        uint256 bal0 = IERC20(asset0).balanceOf(address(this));
        uint256 bal1 = IERC20(asset1).balanceOf(address(this));
        console.log("   final Hook contract bal0 =>", bal0);
        console.log("   final Hook contract bal1 =>", bal1);

        liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            bal0,
            bal1
        );
        console.log("   liquidityAdded =>", liquidityAdded);

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
            if (delta.amount0() < 0) {
                uint256 owed0 = uint256(int256(-delta.amount0()));
                console.log(" aggregator owes token0 =>", owed0);
                key.currency0.settle(poolManager, address(this), owed0, false);
            }
            if (delta.amount1() < 0) {
                uint256 owed1 = uint256(int256(-delta.amount1()));
                console.log(" aggregator owes token1 =>", owed1);
                key.currency1.settle(poolManager, address(this), owed1, false);
            }
        } else {
            console.log("   0 liquidity => skipping modifyLiquidity call.");
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ------------------------------------------------------------
    // (D) AFTER SWAP => remove ephemeral JIT range
    // ------------------------------------------------------------
    function afterSwap(
        address /*sender*/,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta /*deltaIn*/,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        console.log("Hook.afterSwap() => removing JIT liquidity if any");

        if (liquidityAdded == 0) {
            console.log("   No JIT liquidity => skipping");
            return (this.afterSwap.selector, 0);
        }

        console.log("   Removing JIT liquidity =>", liquidityAdded);

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

        if (delta.amount0() > 0) {
            uint256 amt0 = uint256(int256(delta.amount0()));
            console.log(" aggregator Taking token0 =>", amt0);
            key.currency0.take(poolManager, address(this), amt0, false);
        }
        if (delta.amount1() > 0) {
            uint256 amt1 = uint256(int256(delta.amount1()));
            console.log(" aggregator Taking token1 =>", amt1);
            key.currency1.take(poolManager, address(this), amt1, false);
        }

        // re-deposit leftover tokens
        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);
        uint256 finalBal0 = IERC20(asset0).balanceOf(address(this));
        uint256 finalBal1 = IERC20(asset1).balanceOf(address(this));
        console.log("   finalBal0 =>", finalBal0);
        console.log("   finalBal1 =>", finalBal1);

        if (finalBal0 > 0) {
            IERC20(asset0).approve(address(aggregatorVault), finalBal0);
            aggregatorVault.deposit(IERC20(asset0), address(this), finalBal0);
        }
        if (finalBal1 > 0) {
            IERC20(asset1).approve(address(aggregatorVault), finalBal1);
            aggregatorVault.deposit(IERC20(asset1), address(this), finalBal1);
        }

        // reset
        liquidityAdded = 0;
        return (this.afterSwap.selector, 0);
    }

    // helper views
    function getTickLower() external view returns (int24) {
        return tickLower;
    }

    function getTickUpper() external view returns (int24) {
        return tickUpper;
    }
}
