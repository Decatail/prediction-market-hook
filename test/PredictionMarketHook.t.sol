// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

contract PredictionMarketHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PredictionMarketHook hook;
    PoolKey key;
    PoolId poolId;
    Currency token0;
    Currency token1;

    function setUp() public {
        // Deploy Uniswap V4 core
        deployFreshManagerAndRouters();

        // Deploy Hook
        hook = new PredictionMarketHook(IPoolManager(address(manager)));
        
        // Create tokens
        (token0, token1) = deployMintAndApprove2Currencies();
        
        // Create pool with hook
        (key,) = initPool(
            token0,     // currency0
            token1,     // currency1
            hook,       // hook contract
            IHooks(hook).getHookPermissions(),
            3000,       // fee = 0.3%
            TickMath.getSqrtRatioAtTick(0), // initial price = 1:1
            ZERO_BYTES
        );
        
        poolId = key.toId();
        
        // Add initial liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IFullRangeLiquidity(-60, 60, 10 ether, 10 ether),
            ZERO_BYTES
        );
        
        // Give test accounts some ETH for betting
        vm.deal(address(this), 100 ether);
        vm.deal(address(0x1234), 100 ether);
        vm.deal(address(0x5678), 100 ether);
        vm.deal(address(0x9ABC), 100 ether);
    }

    // ============================================================
    //  CREATE MARKET
    // ============================================================

    function testCreateMarket() public {
        hook.createMarket{value: 1 ether}(key, 1 hours, PredictionMarketHook.Direction.UP);
        
        (uint256 up, uint256 down,,) = hook.getOdds(poolId);
        assertEq(up, 1 ether, "Up bets should be 1 ETH");
        assertEq(down, 0, "Down bets should be 0");
    }

    function testCreateMarketFailsWithInvalidDirection() public {
        vm.expectRevert("Direction required");
        hook.createMarket{value: 1 ether}(key, 1 hours, PredictionMarketHook.Direction.NONE);
    }

    function testCreateMarketFailsWithShortDuration() public {
        vm.expectRevert("Min 1 hour");
        hook.createMarket{value: 1 ether}(key, 30 minutes, PredictionMarketHook.Direction.UP);
    }

    function testCannotCreateDuplicateMarket() public {
        hook.createMarket{value: 1 ether}(key, 1 hours, PredictionMarketHook.Direction.UP);
        vm.expectRevert("Market already active");
        hook.createMarket{value: 1 ether}(key, 1 hours, PredictionMarketHook.Direction.DOWN);
    }

    // ============================================================
    //  PLACE BETS
    // ============================================================

    function testPlaceBet() public {
        hook.createMarket{value: 1 ether}(key, 1 hours, PredictionMarketHook.Direction.UP);
        
        vm.prank(address(0x1234));
        hook.placeBet{value: 0.5 ether}(poolId, PredictionMarketHook.Direction.DOWN);
        
        (uint256 up, uint256 down,,) = hook.getOdds(poolId);
        assertEq(up, 1 ether);
        assertEq(down, 0.5 ether);
    }

    function testPlaceBetFailsWhenSkewed() public {
        hook.createMarket{value: 1 ether}(key, 1 hours, PredictionMarketHook.Direction.UP);
        
        // 1 ETH up, try 0.3 ETH down → 1:0.3 = 3.33:1 > 3:1
        vm.prank(address(0x1234));
        vm.expectRevert("Odds too skewed >3:1");
        hook.placeBet{value: 0.3 ether}(poolId, PredictionMarketHook.Direction.DOWN);
    }

    // ============================================================
    //  SETTLE
    // ============================================================

    function testSettleUpWins() public {
        hook.createMarket{value: 1 ether}(key, 1 hours, PredictionMarketHook.Direction.UP);
        
        vm.prank(address(0x1234));
        hook.placeBet{value: 0.5 ether}(poolId, PredictionMarketHook.Direction.DOWN);
        
        // Wait > 1 hour
        vm.warp(block.timestamp + 2 hours);
        
        // Simulate price going UP (swap token1→token0, raising token0's price)
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,         // 1→0, buys token0
                amountSpecified: -5 ether,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(100)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        
        // Now the price went up, settle
        hook.settle(poolId);
        
        (,,, bool settled) = hook.getOdds(poolId);
        assertTrue(settled, "Should be settled");
    }

    function testRefundWhenNoParticipants() public {
        hook.createMarket{value: 1 ether}(key, 1 hours, PredictionMarketHook.Direction.UP);
        
        uint256 balanceBefore = address(this).balance;
        
        vm.warp(block.timestamp + 3 hours); // past participation window
        
        hook.refundIfNoParticipants(poolId);
        
        uint256 balanceAfter = address(this).balance;
        // Should get back ~1 ETH (minus any gas, but test doesn't charge gas)
        assertGt(balanceAfter, balanceBefore, "Should receive refund");
    }

    // ============================================================
    //  GET ODDS
    // ============================================================

    function testGetOdds() public {
        hook.createMarket{value: 2 ether}(key, 1 hours, PredictionMarketHook.Direction.UP);
        
        vm.prank(address(0x1234));
        hook.placeBet{value: 1 ether}(poolId, PredictionMarketHook.Direction.DOWN);
        
        (uint256 up, uint256 down, uint256 upOdds, uint256 downOdds) = hook.getOdds(poolId);
        
        assertEq(up, 2 ether);
        assertEq(down, 1 ether);
        assertEq(upOdds, 66); // 2/3
        assertEq(downOdds, 33); // 1/3
    }

    // ============================================================
    //  MELTDOWN PROTECTION
    // ============================================================

    function testMeltdownRefund() public {
        hook.createMarket{value: 1 ether}(key, 1 hours, PredictionMarketHook.Direction.UP);
        
        vm.prank(address(0x1234));
        hook.placeBet{value: 0.5 ether}(poolId, PredictionMarketHook.Direction.DOWN);
        
        // Wait past end time
        vm.warp(block.timestamp + 2 hours);
        
        // Simulate severe price crash (swap token0→token1, token0's price tanks)
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,          // 0→1, sells token0
                amountSpecified: -9.9 ether, // massive sell
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        
        // Should trigger meltdown and refund everyone
        uint256 bal0Before = address(this).balance;
        uint256 bal1Before = address(0x1234).balance;
        
        vm.prank(address(0x1234));
        hook.settle(poolId);
        
        uint256 bal0After = address(this).balance;
        uint256 bal1After = address(0x1234).balance;
        
        assertGt(bal0After, bal0Before, "Creator should get refund");
        assertGt(bal1After, bal1Before, "Participant should get refund");
    }
}
