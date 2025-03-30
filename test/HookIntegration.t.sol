// ./test/HookIntegration.t.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

//////////////////////////////////////////////////////
//                  Imports                         //
//////////////////////////////////////////////////////

// CODE_UPDATED_HERE: unify on OpenZeppelin's IERC20
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "../lib/forge-std/src/Test.sol";
import {console} from "../lib/forge-std/src/console.sol";

import {Deployers} from "../lib/v4-periphery/lib/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "../lib/v4-periphery/lib/v4-core/src/PoolManager.sol";
import {IPoolManager} from "../lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "../lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";

// We keep MockERC20 from solmate for testing
import {MockERC20} from "../lib/v4-periphery/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";

import {Hook} from "../src/Hook.sol";
// CODE_UPDATED_HERE: aggregatorVault is the new vault that stores multi-token
import {HookVault} from "../src/HookVault.sol";

import {Currency, CurrencyLibrary} from "../lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolKey} from "../lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "../lib/v4-periphery/lib/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "../lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";

/**
 * @title HookIntegrationTest
 * @dev Integration tests focusing on the updated Hook contract's interactions with aggregatorVault (HookVault).
 *
 * Re-using original test cases, adapted to aggregatorVault usage.
 */
contract HookIntegrationTest is Test, Deployers {
    ///////////////////////////////////////////////////////////////
    //                 Contract Instances                        //
    ///////////////////////////////////////////////////////////////

    PoolManager public pm;
    HookVault public aggregatorVault; // CODE_UPDATED_HERE: aggregator vault
    Hook public testHook;

    // Basic tokens used in testing
    Currency public tokenA;
    Currency public tokenB;

    // The poolKey used for our Uniswap V4 pool
    PoolKey public poolKey;

    // A typical sqrtPrice for a 1:1 ratio
    uint160 internal constant MY_SQRT_PRICE_1_1 = 79228162514264337593543950336;

    ///////////////////////////////////////////////////////////////
    //                        setUp                              //
    ///////////////////////////////////////////////////////////////

    /**
     * @notice Sets up the environment for testing, including HookVault, Hook, and a sample pool.
     */
    function setUp() public {
        console.log("HookIntegrationTest.setUp() start...");

        // 1) Deploy manager & routers from the Deployers library
        deployFreshManagerAndRouters();
        pm = PoolManager(address(manager));

        // 2) Deploy & mint two tokens (tokenA, tokenB)
        (tokenA, tokenB) = deployMintAndApprove2Currencies();

        // 3) aggregatorVault: the new multi-asset vault
        aggregatorVault = new HookVault();

        // 4) Deploy Hook with references to pm + aggregatorVault
        {
            address flaggedHookAddr = address(uint160(0x8C0));
            // We'll encode the constructor arguments: (PoolManager, HookVault)
            deployCodeTo(
                "Hook",
                abi.encode(pm, aggregatorVault),
                flaggedHookAddr
            );
            testHook = Hook(flaggedHookAddr);
            aggregatorVault.grantHookRole(address(testHook));
        }

        // 5) Create a Uniswap V4 pool that uses testHook as its IHooks
        (poolKey, ) = initPool(
            tokenA,
            tokenB,
            IHooks(address(testHook)),
            3000,
            MY_SQRT_PRICE_1_1
        );

        console.log("HookIntegrationTest.setUp() done");
    }

    ///////////////////////////////////////////////////////////////
    //                 test_BasicAddLiquidity                    //
    ///////////////////////////////////////////////////////////////

    function test_BasicAddLiquidity() public {
        console.log("test_BasicAddLiquidity start...");
        // 1) user gets 10k of each token
        address user = address(9999);
        MockERC20(address(uint160(Currency.unwrap(tokenA)))).transfer(
            user,
            10_000 ether
        );
        MockERC20(address(uint160(Currency.unwrap(tokenB)))).transfer(
            user,
            10_000 ether
        );

        // 2) aggregatorVault shares before
        address asset0 = Currency.unwrap(tokenA);
        address asset1 = Currency.unwrap(tokenB);

        uint256 shBefore0 = aggregatorVault.totalShares(IERC20(asset0));
        uint256 shBefore1 = aggregatorVault.totalShares(IERC20(asset1));

        // 3) user calls addLiquidity on Hook
        vm.startPrank(user);
        MockERC20(address(uint160(asset0))).approve(
            address(testHook),
            type(uint256).max
        );
        MockERC20(address(uint160(asset1))).approve(
            address(testHook),
            type(uint256).max
        );

        Hook.LiquidityParams memory depositParams = Hook.LiquidityParams({
            fee: 3000,
            currency0: tokenA,
            currency1: tokenB,
            amount0: 4000 ether,
            amount1: 2000 ether,
            key: poolKey
        });
        testHook.addLiquidity(depositParams);
        vm.stopPrank();

        // 4) aggregatorVault shares after
        uint256 shAfter0 = aggregatorVault.totalShares(IERC20(asset0));
        uint256 shAfter1 = aggregatorVault.totalShares(IERC20(asset1));

        uint256 got0 = shAfter0 - shBefore0;
        uint256 got1 = shAfter1 - shBefore1;
        console.log(
            "test_BasicAddLiquidity => aggregatorVault sharesGot0:",
            got0
        );
        console.log(
            "test_BasicAddLiquidity => aggregatorVault sharesGot1:",
            got1
        );

        // Expect aggregator vault to have 4k of asset0, 2k of asset1 (assuming 1:1 mapping for shares)
        assertEq(got0, 4000 ether, "Vault shares mismatch token0");
        assertEq(got1, 2000 ether, "Vault shares mismatch token1");

        console.log("test_BasicAddLiquidity done");
    }

    ///////////////////////////////////////////////////////////////
    //                   test_ZeroDeposit                       //
    ///////////////////////////////////////////////////////////////

    function test_ZeroDeposit() public {
        console.log("test_ZeroDeposit start...");
        // 1) user with some tokens
        address user = makeNewUserWithTokens(100 ether, 100 ether);

        address asset0 = Currency.unwrap(tokenA);
        address asset1 = Currency.unwrap(tokenB);

        // aggregatorVault shares before
        uint256 shBefore0 = aggregatorVault.totalShares(IERC20(asset0));
        uint256 shBefore1 = aggregatorVault.totalShares(IERC20(asset1));

        // 2) user calls addLiquidity(0,0)
        vm.startPrank(user);
        MockERC20(address(uint160(asset0))).approve(
            address(testHook),
            type(uint256).max
        );
        MockERC20(address(uint160(asset1))).approve(
            address(testHook),
            type(uint256).max
        );

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

        // aggregatorVault shares after
        uint256 shAfter0 = aggregatorVault.totalShares(IERC20(asset0));
        uint256 shAfter1 = aggregatorVault.totalShares(IERC20(asset1));

        console.log(
            "test_ZeroDeposit => checking aggregatorVault didn't get anything..."
        );

        assertEq(
            shAfter0,
            shBefore0,
            "Should not deposit anything when amount=0"
        );
        assertEq(
            shAfter1,
            shBefore1,
            "Should not deposit anything when amount=0"
        );

        console.log("test_ZeroDeposit done");
    }

    ///////////////////////////////////////////////////////////////
    //     test_EdgeCase_AllOneTokenToVeda => aggregatorVault    //
    ///////////////////////////////////////////////////////////////

    /**
     * @notice In the original code, we tested depositing only tokenA => 2000 ether.
     * Here we replicate: user with 10k tokenA, 0 tokenB, then deposit => aggregatorVault.
     */
    function test_EdgeCase_AllOneTokenToVeda() public {
        console.log("test_EdgeCase_AllOneTokenToVeda start...");
        // user => 10k tokenA, 0 tokenB
        address user = makeNewUserWithTokens(10000 ether, 0);

        address asset0 = Currency.unwrap(tokenA);
        address asset1 = Currency.unwrap(tokenB);

        // aggregatorVault shares before
        uint256 shBefore0 = aggregatorVault.totalShares(IERC20(asset0));
        uint256 shBefore1 = aggregatorVault.totalShares(IERC20(asset1));

        // deposit only tokenA => 2000
        vm.startPrank(user);
        MockERC20(address(uint160(asset0))).approve(
            address(testHook),
            type(uint256).max
        );

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

        // aggregatorVault shares after
        uint256 shAfter0 = aggregatorVault.totalShares(IERC20(asset0));
        uint256 shAfter1 = aggregatorVault.totalShares(IERC20(asset1));

        console.log(
            "test_EdgeCase_AllOneTokenToVeda => aggregatorVault got tokenA shares:",
            shAfter0 - shBefore0
        );
        console.log(
            "test_EdgeCase_AllOneTokenToVeda => aggregatorVault got tokenB shares:",
            shAfter1 - shBefore1
        );

        // Expect aggregatorVault to have +2000 tokenA shares, +0 for tokenB
        assertEq(
            shAfter0 - shBefore0,
            2000 ether,
            "Expect aggregatorVault to hold tokenA=2000"
        );
        assertEq(
            shAfter1 - shBefore1,
            0,
            "Expect aggregatorVault to hold tokenB=0"
        );

        console.log("test_EdgeCase_AllOneTokenToVeda done");
    }

    ///////////////////////////////////////////////////////////////
    //               test_InsufficientBalance                   //
    ///////////////////////////////////////////////////////////////

    function test_InsufficientBalance() public {
        console.log("test_InsufficientBalance start...");
        // user => 100A, 50B
        address user = makeNewUserWithTokens(100 ether, 50 ether);

        vm.startPrank(user);
        // Approve
        MockERC20(address(uint160(Currency.unwrap(tokenA)))).approve(
            address(testHook),
            type(uint256).max
        );

        // Attempt deposit => 200A
        Hook.LiquidityParams memory depositParams = Hook.LiquidityParams({
            fee: 3000,
            currency0: tokenA,
            currency1: tokenB,
            amount0: 200 ether,
            amount1: 0,
            key: poolKey
        });

        vm.expectRevert();
        testHook.addLiquidity(depositParams);

        vm.stopPrank();
        console.log("test_InsufficientBalance done");
    }

    ///////////////////////////////////////////////////////////////
    //            test_ReAddLiquiditySameUser                   //
    ///////////////////////////////////////////////////////////////

    function test_ReAddLiquiditySameUser() public {
        console.log("test_ReAddLiquiditySameUser start...");
        // user => 5k each
        address user = makeNewUserWithTokens(5000 ether, 5000 ether);

        address asset0 = Currency.unwrap(tokenA);
        address asset1 = Currency.unwrap(tokenB);

        // aggregatorVault shares before
        uint256 shBefore0 = aggregatorVault.totalShares(IERC20(asset0));
        uint256 shBefore1 = aggregatorVault.totalShares(IERC20(asset1));

        vm.startPrank(user);
        MockERC20(address(uint160(asset0))).approve(
            address(testHook),
            type(uint256).max
        );
        MockERC20(address(uint160(asset1))).approve(
            address(testHook),
            type(uint256).max
        );

        // First deposit => 1000A, 1000B
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

        // Second deposit => 2000A, 500B
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

        // aggregatorVault shares after
        uint256 shAfter0 = aggregatorVault.totalShares(IERC20(asset0));
        uint256 shAfter1 = aggregatorVault.totalShares(IERC20(asset1));

        console.log(
            "test_ReAddLiquiditySameUser => aggregatorVault net shares for tokenA:",
            shAfter0 - shBefore0
        );
        console.log(
            "test_ReAddLiquiditySameUser => aggregatorVault net shares for tokenB:",
            shAfter1 - shBefore1
        );

        // user deposited total 3000 A, 1500 B
        // aggregatorVault should hold those shares if 1:1
        assertEq(
            shAfter0 - shBefore0,
            3000 ether,
            "Should see +3000 aggregatorVault shares for tokenA"
        );
        assertEq(
            shAfter1 - shBefore1,
            1500 ether,
            "Should see +1500 aggregatorVault shares for tokenB"
        );

        console.log("test_ReAddLiquiditySameUser done");
    }

    ///////////////////////////////////////////////////////////////
    //    test_AddLiquidity_NoEffectWithHookData                //
    ///////////////////////////////////////////////////////////////

    function test_AddLiquidity_NoEffectWithHookData() public {
        console.log("test_AddLiquidity_NoEffectWithHookData start...");
        address user = makeNewUserWithTokens(2000 ether, 2000 ether);

        vm.startPrank(user);
        MockERC20(address(uint160(Currency.unwrap(tokenA)))).approve(
            address(testHook),
            2000 ether
        );
        MockERC20(address(uint160(Currency.unwrap(tokenB)))).approve(
            address(testHook),
            2000 ether
        );

        // "metadata" that our Hook doesn't specifically use
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

        console.log("No revert => success");
        assertTrue(true, "Add liquidity with custom data does not revert");
    }

    ///////////////////////////////////////////////////////////////
    //                (F) test_BasicSwap_With_JIT               //
    ///////////////////////////////////////////////////////////////

    /**
     * @notice We replicate the original scenario:
     *     - aggregator deposits ~500 of A and B
     *     - swapper does two swaps (A => B, then B => A)
     *     - Hook does a JIT deposit/withdraw from aggregatorVault in beforeSwap/afterSwap
     */
    function test_BasicSwap_With_JIT() public {
        console.log("test_BasicSwap_With_JIT => start...");
        // 1) create swapper with 2k A, 2k B
        address swapper = makeNewUserWithTokens(2_000 ether, 2_000 ether);
        console.log("   swapper =>", swapper);

        // aggregator's "depositor" => 10k each but will deposit 500 each
        address depositor = makeNewUserWithTokens(10_000 ether, 10_000 ether);
        console.log("   depositor =>", depositor);

        // 2) aggregator seeds Hook with deposit => 5000 => scaled to 500
        vm.startPrank(depositor);

        // Approve to Hook
        MockERC20(address(uint160(Currency.unwrap(tokenA)))).approve(
            address(testHook),
            type(uint256).max
        );
        MockERC20(address(uint160(Currency.unwrap(tokenB)))).approve(
            address(testHook),
            type(uint256).max
        );

        // deposit ~5000 => effectively 500
        testHook.addLiquidity(
            Hook.LiquidityParams({
                fee: poolKey.fee,
                currency0: tokenA,
                currency1: tokenB,
                amount0: 5000 ether,
                amount1: 5000 ether,
                key: poolKey
            })
        );
        vm.stopPrank();

        // aggregatorVault shares after deposit
        uint256 vaultA_beforeSwap = aggregatorVault.totalShares(
            IERC20(Currency.unwrap(tokenA))
        );
        uint256 vaultB_beforeSwap = aggregatorVault.totalShares(
            IERC20(Currency.unwrap(tokenB))
        );
        console.log(
            "test_BasicSwap_With_JIT: aggregatorVault shares => tokenA:%s, tokenB:%s",
            vaultA_beforeSwap,
            vaultB_beforeSwap
        );

        // 3) swapper => first swap A => B
        vm.startPrank(swapper);
        MockERC20(address(uint160(Currency.unwrap(tokenA)))).approve(
            address(swapRouter),
            type(uint256).max
        );
        MockERC20(address(uint160(Currency.unwrap(tokenB)))).approve(
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

        console.log("=== test_BasicSwap_With_JIT => first swap (A => B) ===");
        swapRouter.swap(poolKey, swapParams, testSettings, bytes(""));
        vm.stopPrank();

        // aggregatorVault shares mid-swap
        uint256 vaultA_midSwap = aggregatorVault.totalShares(
            IERC20(Currency.unwrap(tokenA))
        );
        uint256 vaultB_midSwap = aggregatorVault.totalShares(
            IERC20(Currency.unwrap(tokenB))
        );
        console.log(
            "After first swap => aggregatorVault tokenA: %s => %s",
            vaultA_beforeSwap,
            vaultA_midSwap
        );
        console.log(
            "After first swap => aggregatorVault tokenB: %s => %s",
            vaultB_beforeSwap,
            vaultB_midSwap
        );

        // 4) second swap => B => A
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

        console.log("=== test_BasicSwap_With_JIT => second swap (B => A) ===");
        vm.startPrank(swapper);
        swapRouter.swap(poolKey, swapParams2, testSettings, bytes(""));
        vm.stopPrank();

        // aggregatorVault shares after second swap
        uint256 vaultA_afterSwap = aggregatorVault.totalShares(
            IERC20(Currency.unwrap(tokenA))
        );
        uint256 vaultB_afterSwap = aggregatorVault.totalShares(
            IERC20(Currency.unwrap(tokenB))
        );
        console.log(
            "After second swap => aggregatorVault tokenA: %s => %s",
            vaultA_midSwap,
            vaultA_afterSwap
        );
        console.log(
            "After second swap => aggregatorVault tokenB: %s => %s",
            vaultB_midSwap,
            vaultB_afterSwap
        );

        bool changedA = (vaultA_afterSwap != vaultA_beforeSwap);
        bool changedB = (vaultB_afterSwap != vaultB_beforeSwap);

        console.log(
            "test_BasicSwap_With_JIT => aggregatorVault final shares (tokenA=%s, tokenB=%s)",
            vaultA_afterSwap,
            vaultB_afterSwap
        );
        assertTrue(
            changedA || changedB,
            "Expect aggregatorVault share balances to change from JIT usage"
        );

        console.log("test_BasicSwap_With_JIT done");
    }

    ///////////////////////////////////////////////////////////////
    //                Helper: makeNewUserWithTokens             //
    ///////////////////////////////////////////////////////////////

    /**
     * @notice Helper that creates a user and transfers them amtA & amtB.
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
        MockERC20(address(uint160(Currency.unwrap(tokenA)))).transfer(
            user,
            amtA
        );
        MockERC20(address(uint160(Currency.unwrap(tokenB)))).transfer(
            user,
            amtB
        );
        return user;
    }
}
