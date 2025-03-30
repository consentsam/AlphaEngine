// ./src/Hook.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

//////////////////////////////////////////////////////////
//                  Imports                             //
//////////////////////////////////////////////////////////

// CODE_UPDATED_HERE: Replacing old submodule IERC20 references with OpenZeppelin's IERC20
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

// NOTE: Your aggregatorVault is presumably your updated HookVault that uses
//       OpenZeppelin's IERC20. We'll reference it as `aggregatorVault`.
import {HookVault} from "./HookVault.sol"; // <--- For example, if you name it HookVault

//////////////////////////////////////////////////////////
//                 Contract Definition                  //
//////////////////////////////////////////////////////////

/**
 * @title Hook
 * @notice Demonstrates a Just-In-Time liquidity strategy, updated to unify IERC20 references using OpenZeppelin.
 */
contract Hook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    //////////////////////////////////////
    // CODE_UPDATED_HERE: unify on OZ's IERC20
    //////////////////////////////////////
    // Instead of IPool or aggregator, we'll integrate with aggregatorVault of type HookVault that uses IERC20 (OpenZeppelin).
    HookVault public aggregatorVault;

    bool private liquidityInitialized;

    // These ticks define the ephemeral JIT range inserted during a swap.
    int24 public tickLower;
    int24 public tickUpper;

    // Tracks how much liquidity is currently added in the ephemeral range
    uint128 private liquidityAdded;

    //////////////////////////////////////
    //   Example: Data for "removeLiquidity"
    //////////////////////////////////////
    mapping(address => mapping(address => uint256)) public userTokenShares;
    mapping(address => uint256) public totalTokenShares;

    error PoolNotInitialized();

    /**
     * @notice Params used when adding or removing aggregator-based liquidity.
     */
    struct LiquidityParams {
        uint24 fee;
        Currency currency0;
        Currency currency1;
        uint256 amount0;
        uint256 amount1;
        PoolKey key;
    }

    //////////////////////////////////////////////////////////
    //                  Constructor                         //
    //////////////////////////////////////////////////////////

    /**
     * @notice Sets up the Hook contract, linking it to a PoolManager and an aggregator vault.
     * @param _manager Reference to the Uniswap V4 PoolManager.
     * @param _aggregatorVault The aggregator vault that handles multi-token deposit/withdraw (e.g. HookVault).
     */
    constructor(
        IPoolManager _manager,
        HookVault _aggregatorVault
    )
        // CODE_UPDATED_HERE: unify constructor to accept aggregatorVault
        BaseHook(_manager)
    {
        aggregatorVault = _aggregatorVault;
    }

    /**
     * @notice Returns the required hook permissions for this contract.
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

    //////////////////////////////////////////////////////////
    //             (A) ADD LIQUIDITY to aggregator          //
    //////////////////////////////////////////////////////////

    /**
     * @notice Allows a user to add liquidity to aggregatorVault.
     *         Example logic that splits deposit across two tokens.
     */
    function addLiquidity(LiquidityParams calldata params) external {
        console.log("Hook.addLiquidity() called by =>", msg.sender);

        require(
            params.amount0 > 0 || params.amount1 > 0,
            "No tokens to deposit"
        );

        address asset0 = Currency.unwrap(params.currency0);
        address asset1 = Currency.unwrap(params.currency1);

        console.log(" addLiquidity: asset0 =>", asset0);
        console.log(" addLiquidity: asset1 =>", asset1);

        // CODE_UPDATED_HERE: We deposit tokens into aggregatorVault (which uses OZ IERC20).
        // "params.amount0" from msg.sender -> aggregatorVault
        if (params.amount0 > 0) {
            console.log(" aggregatorVault.deposit token0 =>", params.amount0);
            aggregatorVault.deposit(IERC20(asset0), msg.sender, params.amount0);
            // Record user shares
            userTokenShares[msg.sender][asset0] += params.amount0;
            totalTokenShares[asset0] += params.amount0;
        }

        // deposit token1
        if (params.amount1 > 0) {
            console.log(" aggregatorVault.deposit token1 =>", params.amount1);
            aggregatorVault.deposit(IERC20(asset1), msg.sender, params.amount1);
            userTokenShares[msg.sender][asset1] += params.amount1;
            totalTokenShares[asset1] += params.amount1;
        }
    }

    /**
     * @dev Hook function that checks if liquidity is initialized properly.
     */
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

    //////////////////////////////////////////////////////////
    //             (B) REMOVE LIQUIDITY from aggregator     //
    //////////////////////////////////////////////////////////

    /**
     * @notice Allows user to remove liquidity from aggregatorVault.
     * @dev Example logic that proportionally burns user's aggregator shares for each token.
     */
    function removeLiquidity(LiquidityParams calldata params) external {
        console.log("Hook.removeLiquidity() => user:", msg.sender);

        address asset0 = Currency.unwrap(params.currency0);
        address asset1 = Currency.unwrap(params.currency1);

        // CODE_UPDATED_HERE: We'll burn aggregatorVault shares for each token
        if (params.amount0 > 0) {
            console.log(" removeLiquidity => token0 amount:", params.amount0);

            // Suppose aggregatorVault has total X shares for asset0
            uint256 totalSh0 = aggregatorVault.totalShares(IERC20(asset0));
            // user shares
            uint256 userSh0 = userTokenShares[msg.sender][asset0];

            // figure how many aggregatorVault shares correspond to "params.amount0"
            // For simplicity, do: sharesToBurn0 = (params.amount0 * totalSh0 / aggregatorVaultBalanceOfThatToken).
            // aggregatorVault might do the ratio behind the scenes, but we can keep it simple:
            require(userSh0 >= params.amount0, "not enough user token0 shares");
            uint256 sharesToBurn0 = params.amount0;
            // You might do a better ratio, but this is just an example.

            userTokenShares[msg.sender][asset0] -= sharesToBurn0;
            totalTokenShares[asset0] -= sharesToBurn0;

            aggregatorVault.withdraw(IERC20(asset0), msg.sender, sharesToBurn0);
        }

        // If user also wants to remove token1
        if (params.amount1 > 0) {
            console.log(" removeLiquidity => token1 amount:", params.amount1);

            uint256 totalSh1 = aggregatorVault.totalShares(IERC20(asset1));
            uint256 userSh1 = userTokenShares[msg.sender][asset1];
            require(userSh1 >= params.amount1, "not enough user token1 shares");
            uint256 sharesToBurn1 = params.amount1;

            userTokenShares[msg.sender][asset1] -= sharesToBurn1;
            totalTokenShares[asset1] -= sharesToBurn1;

            aggregatorVault.withdraw(IERC20(asset1), msg.sender, sharesToBurn1);
        }
    }

    //////////////////////////////////////////////////////////
    //             (C) BEFORE SWAP => withdraw for JIT      //
    //////////////////////////////////////////////////////////

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

        // 1) check pool is initialized
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            key.toId()
        );
        console.log("   sqrtPriceX96 =>", sqrtPriceX96);
        console.log("   currentTick =>", currentTick);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // 2) decide narrower JIT range
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

        // 3) aggregator withdraws from aggregatorVault
        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        // CODE_UPDATED_HERE: aggregatorVault has total shares.
        uint256 totalSh0 = aggregatorVault.totalShares(IERC20(asset0));
        uint256 totalSh1 = aggregatorVault.totalShares(IERC20(asset1));
        console.log("   aggregatorVault totalShares0 =>", totalSh0);
        console.log("   aggregatorVault totalShares1 =>", totalSh1);

        if (totalSh0 > 0) {
            console.log("   aggregatorVault.withdraw() all token0 shares");
            aggregatorVault.withdraw(IERC20(asset0), address(this), totalSh0);
        }
        if (totalSh1 > 0) {
            console.log("   aggregatorVault.withdraw() all token1 shares");
            aggregatorVault.withdraw(IERC20(asset1), address(this), totalSh1);
        }

        // 4) check final contract balances => add short-range liquidity
        uint256 bal0 = IERC20(asset0).balanceOf(address(this));
        uint256 bal1 = IERC20(asset1).balanceOf(address(this));
        console.log("   final Hook contract bal0 =>", bal0);
        console.log("   final Hook contract bal1 =>", bal1);

        // Calculate how much liquidity we can add
        liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            bal0,
            bal1
        );
        console.log("   liquidityAdded =>", liquidityAdded);

        // 5) Actually add the liquidity
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

            // If negative => aggregator owes tokens
            if (delta.amount0() < 0) {
                // CODE_UPDATED_HERE: negative cast fix
                uint256 owed0 = uint256(int256(-delta.amount0()));
                console.log("   aggregator owes token0 =>", owed0);
                key.currency0.settle(poolManager, address(this), owed0, false);
            }
            if (delta.amount1() < 0) {
                // CODE_UPDATED_HERE: negative cast fix
                uint256 owed1 = uint256(int256(-delta.amount1()));
                console.log("   aggregator owes token1 =>", owed1);
                key.currency1.settle(poolManager, address(this), owed1, false);
            }
        } else {
            console.log("   0 liquidity => skipping modifyLiquidity call.");
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    //////////////////////////////////////////////////////////
    //             (D) AFTER SWAP => remove JIT liquidity   //
    //////////////////////////////////////////////////////////

    function afterSwap(
        address /*sender*/,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta /*deltaIn*/,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        console.log("Hook.afterSwap() => removing JIT liquidity if any");

        // If no JIT liquidity was added, skip
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

        // If delta.amount0() > 0 => aggregator can take tokens
        if (delta.amount0() > 0) {
            uint256 amt0 = uint256(int256(delta.amount0()));
            console.log("   aggregator Taking token0 =>", amt0);
            key.currency0.take(poolManager, address(this), amt0, false);
        }
        if (delta.amount1() > 0) {
            uint256 amt1 = uint256(int256(delta.amount1()));
            console.log("   aggregator Taking token1 =>", amt1);
            key.currency1.take(poolManager, address(this), amt1, false);
        }

        // re-deposit final balances into aggregatorVault for later usage
        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        uint256 finalBal0 = IERC20(asset0).balanceOf(address(this));
        uint256 finalBal1 = IERC20(asset1).balanceOf(address(this));

        console.log("   finalBal0 =>", finalBal0);
        console.log("   finalBal1 =>", finalBal1);

        if (finalBal0 > 0) {
            console.log("   aggregatorVault.deposit back token0 =>", finalBal0);
            aggregatorVault.deposit(IERC20(asset0), address(this), finalBal0);
        }
        if (finalBal1 > 0) {
            console.log("   aggregatorVault.deposit back token1 =>", finalBal1);
            aggregatorVault.deposit(IERC20(asset1), address(this), finalBal1);
        }

        // reset
        liquidityAdded = 0;
        return (this.afterSwap.selector, 0);
    }

    //////////////////////////////////////////////////////////
    //                  Helper Functions                    //
    //////////////////////////////////////////////////////////

    /**
     * @notice Returns the lower tick used in the ephemeral JIT range.
     */
    function getTickLower() external view returns (int24) {
        return tickLower;
    }

    /**
     * @notice Returns the upper tick used in the ephemeral JIT range.
     */
    function getTickUpper() external view returns (int24) {
        return tickUpper;
    }
}
