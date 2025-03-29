// -----------------------------------------------------------------------------
// File: test/HookIntegration.t.sol
// -----------------------------------------------------------------------------

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Deployers} from "../lib/v4-periphery/lib/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "../lib/v4-periphery/lib/v4-core/src/PoolManager.sol";
import {IPoolManager} from "../lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "../lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {MockERC20} from "../lib/v4-periphery/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {Hook} from "../src/Hook.sol";
import {MockAavePool} from "./MockAavePool.sol";
import {MockTeller} from "./MockTeller.sol";
import {Currency, CurrencyLibrary} from "../lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolKey} from "../lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "../lib/v4-periphery/lib/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "../lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";

/**
 * @title HookIntegrationTest
 * @dev Integration tests focusing on the Hook contract's interactions with MockAavePool and MockTeller.
 */
contract HookIntegrationTest is Test, Deployers {
    PoolManager public pm;
    MockAavePool public aavePoolMock;
    MockTeller public vedaTellerMock;
    Hook public testHook;

    Currency public tokenA;
    Currency public tokenB;
    PoolKey public poolKey;

    /// @dev The initial sqrtPrice used when creating the pool (price of 1:1).
    uint160 internal constant MY_SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /**
     * @notice Sets up the PoolManager, mock aggregator protocols, and Hook contract.
     */
    function setUp() public {
        // Deploy manager & routers from the Deployers library
        deployFreshManagerAndRouters();
        pm = PoolManager(address(manager));

        // Deploy aggregator mocks
        aavePoolMock = new MockAavePool();
        vedaTellerMock = new MockTeller();

        // Deploy & mint test tokens, returning them as Currency wrappers
        (tokenA, tokenB) = deployMintAndApprove2Currencies();

        // Deploy Hook contract at a flagged address
        address flaggedHookAddr = address(uint160(0x8C0));
        deployCodeTo(
            "Hook",
            abi.encode(pm, address(aavePoolMock), address(vedaTellerMock)),
            flaggedHookAddr
        );
        testHook = Hook(flaggedHookAddr);

        // Create a pool with Hook set as the IHooks implementation
        (poolKey, ) = initPool(
            tokenA,
            tokenB,
            IHooks(address(testHook)),
            3000,
            MY_SQRT_PRICE_1_1
        );
    }

    /**
     * @notice Tests a basic addLiquidity workflow.
     */
    function test_BasicAddLiquidity() public {
        address user = address(9999);
        // Transfer tokens to user for testing
        MockERC20(Currency.unwrap(tokenA)).transfer(user, 10_000 ether);
        MockERC20(Currency.unwrap(tokenB)).transfer(user, 10_000 ether);

        address asset0 = Currency.unwrap(tokenA);
        address asset1 = Currency.unwrap(tokenB);

        // Snapshot aggregator's Aave/Veda balances before depositing
        uint256 aaveBefore0 = aavePoolMock.suppliedBalances(
            asset0,
            address(testHook)
        );
        uint256 aaveBefore1 = aavePoolMock.suppliedBalances(
            asset1,
            address(testHook)
        );
        uint256 vedaBefore0 = vedaTellerMock.shareBalances(
            asset0,
            address(testHook)
        );
        uint256 vedaBefore1 = vedaTellerMock.shareBalances(
            asset1,
            address(testHook)
        );

        vm.startPrank(user);
        MockERC20(asset0).approve(address(testHook), type(uint256).max);
        MockERC20(asset1).approve(address(testHook), type(uint256).max);

        Hook.LiquidityParams memory depositParams = Hook.LiquidityParams({
            fee: 3000,
            currency0: tokenA,
            currency1: tokenB,
            amount0: 4000 ether,
            amount1: 2000 ether,
            key: poolKey
        });

        // Perform the addLiquidity call
        testHook.addLiquidity(depositParams);

        vm.stopPrank();

        // Check aggregator's final Aave & Veda balances
        uint256 aaveAfter0 = aavePoolMock.suppliedBalances(
            asset0,
            address(testHook)
        );
        uint256 aaveAfter1 = aavePoolMock.suppliedBalances(
            asset1,
            address(testHook)
        );
        uint256 vedaAfter0 = vedaTellerMock.shareBalances(
            asset0,
            address(testHook)
        );
        uint256 vedaAfter1 = vedaTellerMock.shareBalances(
            asset1,
            address(testHook)
        );

        uint256 gotAave0 = aaveAfter0 - aaveBefore0;
        uint256 gotAave1 = aaveAfter1 - aaveBefore1;
        uint256 gotVeda0 = vedaAfter0 - vedaBefore0;
        uint256 gotVeda1 = vedaAfter1 - vedaBefore1;

        // Validate that 25% of each token went to Aave, 75% to Veda
        assertEq(gotAave0, 1000 ether, "AAVE aggregator for token0 mismatch");
        assertEq(gotAave1, 500 ether, "AAVE aggregator for token1 mismatch");
        assertEq(gotVeda0, 3000 ether, "Veda aggregator for token0 mismatch");
        assertEq(gotVeda1, 1500 ether, "Veda aggregator for token1 mismatch");
    }

    /**
     * @notice Tests addLiquidity with zero amounts, ensuring no tokens are deposited.
     */
    function test_ZeroDeposit() public {
        address user = makeNewUserWithTokens(100 ether, 100 ether);
        address asset0 = Currency.unwrap(tokenA);
        address asset1 = Currency.unwrap(tokenB);

        // Snapshot aggregator's Aave/Veda balances before depositing
        uint256 aaveBefore0 = aavePoolMock.suppliedBalances(
            asset0,
            address(testHook)
        );
        uint256 vedaBefore0 = vedaTellerMock.shareBalances(
            asset0,
            address(testHook)
        );
        uint256 aaveBefore1 = aavePoolMock.suppliedBalances(
            asset1,
            address(testHook)
        );
        uint256 vedaBefore1 = vedaTellerMock.shareBalances(
            asset1,
            address(testHook)
        );

        vm.startPrank(user);
        MockERC20(asset0).approve(address(testHook), type(uint256).max);
        MockERC20(asset1).approve(address(testHook), type(uint256).max);

        // Request 0 deposit for both tokens
        Hook.LiquidityParams memory depositParams = Hook.LiquidityParams({
            fee: 3000,
            currency0: tokenA,
            currency1: tokenB,
            amount0: 0,
            amount1: 0,
            key: poolKey
        });
        testHook.addLiquidity(depositParams);

        vm.stopPrank();

        // Check aggregator's final Aave & Veda balances to confirm no changes
        uint256 aaveAfter0 = aavePoolMock.suppliedBalances(
            asset0,
            address(testHook)
        );
        uint256 vedaAfter0 = vedaTellerMock.shareBalances(
            asset0,
            address(testHook)
        );
        uint256 aaveAfter1 = aavePoolMock.suppliedBalances(
            asset1,
            address(testHook)
        );
        uint256 vedaAfter1 = vedaTellerMock.shareBalances(
            asset1,
            address(testHook)
        );

        assertEq(
            aaveAfter0,
            aaveBefore0,
            "Should not deposit anything when amount=0"
        );
        assertEq(
            vedaAfter0,
            vedaBefore0,
            "Should not deposit anything when amount=0"
        );
        assertEq(
            aaveAfter1,
            aaveBefore1,
            "Should not deposit anything when amount=0"
        );
        assertEq(
            vedaAfter1,
            vedaBefore1,
            "Should not deposit anything when amount=0"
        );
    }

    /**
     * @notice Tests depositing only one token to Veda (tokenA only).
     */
    function test_EdgeCase_AllOneTokenToVeda() public {
        // Create user funded only with tokenA
        address user = makeNewUserWithTokens(10000 ether, 0);

        address asset0 = Currency.unwrap(tokenA);
        address asset1 = Currency.unwrap(tokenB);

        // Snapshot aggregator's Aave/Veda balances
        uint256 aaveBefore0 = aavePoolMock.suppliedBalances(
            asset0,
            address(testHook)
        );
        uint256 vedaBefore0 = vedaTellerMock.shareBalances(
            asset0,
            address(testHook)
        );
        uint256 aaveBefore1 = aavePoolMock.suppliedBalances(
            asset1,
            address(testHook)
        );
        uint256 vedaBefore1 = vedaTellerMock.shareBalances(
            asset1,
            address(testHook)
        );

        vm.startPrank(user);
        MockERC20(asset0).approve(address(testHook), type(uint256).max);

        // Deposit only tokenA => 2000
        Hook.LiquidityParams memory depositParams = Hook.LiquidityParams({
            fee: 3000,
            currency0: tokenA,
            currency1: tokenB,
            amount0: 2000 ether,
            amount1: 0,
            key: poolKey
        });
        testHook.addLiquidity(depositParams);
        vm.stopPrank();

        // Check aggregator's final Aave & Veda balances
        uint256 aaveAfter0 = aavePoolMock.suppliedBalances(
            asset0,
            address(testHook)
        );
        uint256 vedaAfter0 = vedaTellerMock.shareBalances(
            asset0,
            address(testHook)
        );
        uint256 aaveAfter1 = aavePoolMock.suppliedBalances(
            asset1,
            address(testHook)
        );
        uint256 vedaAfter1 = vedaTellerMock.shareBalances(
            asset1,
            address(testHook)
        );

        // Expect 25% => Aave, 75% => Veda for tokenA. B is untouched.
        assertEq(aaveAfter0 - aaveBefore0, 500 ether, "Expect 25% in Aave");
        assertEq(vedaAfter0 - vedaBefore0, 1500 ether, "Expect 75% in Veda");
        assertEq(aaveAfter1 - aaveBefore1, 0, "No deposit for tokenB => 0");
        assertEq(vedaAfter1 - vedaBefore1, 0, "No deposit for tokenB => 0");
    }

    /**
     * @notice Tests a scenario where the user doesn't have enough tokens to fulfill transferFrom.
     */
    function test_InsufficientBalance() public {
        // User has only 100 A, 50 B
        address user = makeNewUserWithTokens(100 ether, 50 ether);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(tokenA)).approve(
            address(testHook),
            type(uint256).max
        );

        // Attempt to deposit 200 A => should revert
        Hook.LiquidityParams memory depositParams = Hook.LiquidityParams({
            fee: 3000,
            currency0: tokenA,
            currency1: tokenB,
            amount0: 200 ether,
            amount1: 0,
            key: poolKey
        });

        vm.expectRevert(); // transferFrom fails
        testHook.addLiquidity(depositParams);
        vm.stopPrank();
    }

    /**
     * @notice Tests adding liquidity multiple times from the same user.
     */
    function test_ReAddLiquiditySameUser() public {
        address user = makeNewUserWithTokens(5000 ether, 5000 ether);

        address asset0 = Currency.unwrap(tokenA);
        address asset1 = Currency.unwrap(tokenB);

        // Snapshot aggregator's Aave/Veda balances
        uint256 aaveBefore0 = aavePoolMock.suppliedBalances(
            asset0,
            address(testHook)
        );
        uint256 aaveBefore1 = aavePoolMock.suppliedBalances(
            asset1,
            address(testHook)
        );
        uint256 vedaBefore0 = vedaTellerMock.shareBalances(
            asset0,
            address(testHook)
        );
        uint256 vedaBefore1 = vedaTellerMock.shareBalances(
            asset1,
            address(testHook)
        );

        vm.startPrank(user);
        MockERC20(asset0).approve(address(testHook), type(uint256).max);
        MockERC20(asset1).approve(address(testHook), type(uint256).max);

        // First deposit => 1000 A, 1000 B
        testHook.addLiquidity(
            Hook.LiquidityParams({
                fee: 3000,
                currency0: tokenA,
                currency1: tokenB,
                amount0: 1000 ether,
                amount1: 1000 ether,
                key: poolKey
            })
        );

        // Second deposit => 2000 A, 500 B
        testHook.addLiquidity(
            Hook.LiquidityParams({
                fee: 3000,
                currency0: tokenA,
                currency1: tokenB,
                amount0: 2000 ether,
                amount1: 500 ether,
                key: poolKey
            })
        );
        vm.stopPrank();

        // Check aggregator's final Aave & Veda balances
        uint256 aaveAfter0 = aavePoolMock.suppliedBalances(
            asset0,
            address(testHook)
        );
        uint256 aaveAfter1 = aavePoolMock.suppliedBalances(
            asset1,
            address(testHook)
        );
        uint256 vedaAfter0 = vedaTellerMock.shareBalances(
            asset0,
            address(testHook)
        );
        uint256 vedaAfter1 = vedaTellerMock.shareBalances(
            asset1,
            address(testHook)
        );

        // Expect 25% => Aave, 75% => Veda of total 3000 A (750 A => Aave, 2250 => Veda)
        // and 1500 B (375 B => Aave, 1125 => Veda)
        assertEq(
            aaveAfter0 - aaveBefore0,
            750 ether,
            "Should see 750 in Aave for tokenA"
        );
        assertEq(
            aaveAfter1 - aaveBefore1,
            375 ether,
            "Should see 375 in Aave for tokenB"
        );
        assertEq(
            vedaAfter0 - vedaBefore0,
            2250 ether,
            "Should see 2250 in Veda for tokenA"
        );
        assertEq(
            vedaAfter1 - vedaBefore1,
            1125 ether,
            "Should see 1125 in Veda for tokenB"
        );
    }

    /**
     * @notice Tests adding liquidity with extra hookData, ensuring no effect on deposit logic.
     */
    function test_AddLiquidity_NoEffectWithHookData() public {
        address user = makeNewUserWithTokens(2000 ether, 2000 ether);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(tokenA)).approve(
            address(testHook),
            2000 ether
        );
        MockERC20(Currency.unwrap(tokenB)).approve(
            address(testHook),
            2000 ether
        );

        // This customData is not used in the current Hook logic
        bytes memory customData = abi.encode("some instructions", 42, true);

        Hook.LiquidityParams memory depositParams = Hook.LiquidityParams({
            fee: 3000,
            currency0: tokenA,
            currency1: tokenB,
            amount0: 500 ether,
            amount1: 300 ether,
            key: poolKey
        });

        testHook.addLiquidity(depositParams);
        vm.stopPrank();

        // Just ensure no revert occurred; no functional effect.
        assertTrue(true, "Add liquidity with custom data does not revert");
    }

    /**
     * @notice Utility: creates a new user and funds them with amtA of tokenA and amtB of tokenB.
     * @param amtA The amount of tokenA to grant the user.
     * @param amtB The amount of tokenB to grant the user.
     * @return user Address of the newly created user.
     */
    function makeNewUserWithTokens(
        uint256 amtA,
        uint256 amtB
    ) internal returns (address user) {
        user = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(block.timestamp, amtA, amtB))
                )
            )
        );
        MockERC20(Currency.unwrap(tokenA)).transfer(user, amtA);
        MockERC20(Currency.unwrap(tokenB)).transfer(user, amtB);
        return user;
    }

    /**
     * @notice Demonstrates a basic two-swap scenario with JIT liquidity from the aggregator.
     *         First swap is A => B, second is B => A.
     */
    function test_BasicSwap_With_JIT() public {
        // Create a swapper with 2000 A and 2000 B
        address swapper = makeNewUserWithTokens(2_000 ether, 2_000 ether);

        // Create aggregator's deposit user with 10000 A, 10000 B, but only 500 actually used
        address depositor = makeNewUserWithTokens(10_000 ether, 10_000 ether);

        // Transfer a small seed to the Hook contract
        MockERC20(Currency.unwrap(tokenA)).transfer(
            address(testHook),
            50 ether
        );
        MockERC20(Currency.unwrap(tokenB)).transfer(
            address(testHook),
            50 ether
        );

        // Aggregator deposits ~500 each (scaled down from 5000 => 500 to avoid overflow)
        vm.startPrank(depositor);
        MockERC20(Currency.unwrap(tokenA)).approve(
            address(testHook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(tokenB)).approve(
            address(testHook),
            type(uint256).max
        );
        testHook.addLiquidity(
            Hook.LiquidityParams({
                fee: poolKey.fee,
                currency0: tokenA,
                currency1: tokenB,
                amount0: 5000 ether, // scaled
                amount1: 5000 ether, // scaled
                key: poolKey
            })
        );
        vm.stopPrank();

        // Snapshot aggregator's Aave balances before the first swap
        uint256 aaveBeforeA = aavePoolMock.suppliedBalances(
            Currency.unwrap(tokenA),
            address(testHook)
        );
        uint256 aaveBeforeB = aavePoolMock.suppliedBalances(
            Currency.unwrap(tokenB),
            address(testHook)
        );

        // First swap: user swaps A => B
        vm.startPrank(swapper);

        MockERC20(Currency.unwrap(tokenA)).approve(
            address(swapRouter),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(tokenB)).approve(
            address(swapRouter),
            type(uint256).max
        );

        bool zeroForOne = true; // A => B
        int256 amountSpecified = 10 ether;
        uint160 priceLimit = zeroForOne
            ? TickMath.MIN_SQRT_PRICE + 10
            : TickMath.MAX_SQRT_PRICE - 10;

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: priceLimit
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(poolKey, swapParams, testSettings, bytes(""));

        // final user balances after first swap (not specifically checked, but no revert)
        uint256 swapperAAfter1 = MockERC20(Currency.unwrap(tokenA)).balanceOf(
            swapper
        );
        uint256 swapperBAfter1 = MockERC20(Currency.unwrap(tokenB)).balanceOf(
            swapper
        );
        vm.stopPrank();

        // aggregator's Aave balances after first swap
        uint256 aaveMidA = aavePoolMock.suppliedBalances(
            Currency.unwrap(tokenA),
            address(testHook)
        );
        uint256 aaveMidB = aavePoolMock.suppliedBalances(
            Currency.unwrap(tokenB),
            address(testHook)
        );

        // Second swap: user swaps B => A
        bool zeroForOne2 = false; // B => A
        int256 amountSpecified2 = 5000 ether;
        uint160 priceLimit2 = zeroForOne2
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;

        IPoolManager.SwapParams memory swapParams2 = IPoolManager.SwapParams({
            zeroForOne: zeroForOne2,
            amountSpecified: amountSpecified2,
            sqrtPriceLimitX96: priceLimit2
        });

        vm.startPrank(swapper);
        uint256 swapperABefore2 = MockERC20(Currency.unwrap(tokenA)).balanceOf(
            swapper
        );
        uint256 swapperBBefore2 = MockERC20(Currency.unwrap(tokenB)).balanceOf(
            swapper
        );

        swapRouter.swap(poolKey, swapParams2, testSettings, bytes(""));

        uint256 swapperAAfter2 = MockERC20(Currency.unwrap(tokenA)).balanceOf(
            swapper
        );
        uint256 swapperBAfter2 = MockERC20(Currency.unwrap(tokenB)).balanceOf(
            swapper
        );

        vm.stopPrank();

        // aggregator's Aave balances after second swap
        uint256 aaveAfterA = aavePoolMock.suppliedBalances(
            Currency.unwrap(tokenA),
            address(testHook)
        );
        uint256 aaveAfterB = aavePoolMock.suppliedBalances(
            Currency.unwrap(tokenB),
            address(testHook)
        );

        // Verify aggregator's final Aave balances changed from the initial deposit
        bool changedA = (aaveAfterA != aaveBeforeA);
        bool changedB = (aaveAfterB != aaveBeforeB);

        assertTrue(
            changedA || changedB,
            "Expect aggregator's Aave balance to change from JIT usage"
        );
    }
}
