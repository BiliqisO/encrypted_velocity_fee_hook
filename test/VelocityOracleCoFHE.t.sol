// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VelocityOracleCoFHE} from "../src/VelocityOracleCoFHE.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/**
 * @title VelocityOracleCoFHETest
 * @notice Test suite for the CoFHE velocity oracle
 */
contract VelocityOracleCoFHETest is Test {
    VelocityOracleCoFHE public oracle;

    address public owner;
    address public updater;
    address public user;

    PoolId public poolId1;
    PoolId public poolId2;

    event DataIngested(PoolId indexed poolId, uint64 timestamp);
    event VelocityTierUpdated(PoolId indexed poolId, uint16 oldTier, uint16 newTier, uint64 timestamp);
    event UpdaterChanged(address indexed oldUpdater, address indexed newUpdater);
    event VelocityUpdated(PoolId indexed poolId, uint256 ema1e18, uint16 tier, uint64 timestamp);
    event VelocityParamsSet(PoolId indexed poolId, VelocityOracleCoFHE.VelocityParams params);

    function setUp() public {
        owner = makeAddr("owner");
        updater = makeAddr("updater");
        user = makeAddr("user");

        vm.prank(owner);
        oracle = new VelocityOracleCoFHE(owner, updater);

        // Create mock pool IDs
        poolId1 = PoolId.wrap(keccak256("pool1"));
        poolId2 = PoolId.wrap(keccak256("pool2"));
    }

    // ============================================
    // Deployment Tests
    // ============================================

    function test_Deployment() public {
        assertEq(oracle.owner(), owner);
        assertEq(oracle.updater(), updater);
        assertEq(oracle.MAX_VELOCITY_TIER(), 10);
        assertEq(oracle.MIN_UPDATE_INTERVAL(), 60);
    }

    // ============================================
    // Tier Update Tests
    // ============================================

    function test_SetVelocityTier() public {
        // Advance time 
        vm.warp(block.timestamp + 61);

        vm.prank(updater);
        oracle.setVelocityTier(poolId1, 5);

        assertEq(oracle.getVelocityTier(poolId1), 5);
    }

    function test_SetVelocityTier_RevertIf_NotUpdater() public {
        vm.prank(user);
        vm.expectRevert(VelocityOracleCoFHE.UnauthorizedUpdater.selector);
        oracle.setVelocityTier(poolId1, 3);
    }

    function test_SetVelocityTier_RevertIf_TierTooHigh() public {
        vm.prank(updater);
        vm.expectRevert(VelocityOracleCoFHE.InvalidTier.selector);
        oracle.setVelocityTier(poolId1, 11);
    }

    function test_SetVelocityTier_RateLimiting() public {
        // Advance time first
        vm.warp(block.timestamp + 61);

        // First update succeeds
        vm.prank(updater);
        oracle.setVelocityTier(poolId1, 3);

        // Second update too soon fails
        vm.prank(updater);
        vm.expectRevert(VelocityOracleCoFHE.UpdateTooFrequent.selector);
        oracle.setVelocityTier(poolId1, 4);

        // After interval, succeeds
        vm.warp(block.timestamp + 61);
        vm.prank(updater);
        oracle.setVelocityTier(poolId1, 4);
        assertEq(oracle.getVelocityTier(poolId1), 4);
    }

    // ============================================
    // Batch Update Tests
    // ============================================

    function test_BatchSetVelocityTiers() public {
        PoolId[] memory poolIds = new PoolId[](2);
        poolIds[0] = poolId1;
        poolIds[1] = poolId2;

        uint16[] memory tiers = new uint16[](2);
        tiers[0] = 3;
        tiers[1] = 7;

        // Advance time to avoid rate limit
        vm.warp(block.timestamp + 61);

        vm.prank(updater);
        oracle.batchSetVelocityTiers(poolIds, tiers);

        assertEq(oracle.getVelocityTier(poolId1), 3);
        assertEq(oracle.getVelocityTier(poolId2), 7);
    }

    function test_BatchSetVelocityTiers_RevertIf_LengthMismatch() public {
        PoolId[] memory poolIds = new PoolId[](2);
        poolIds[0] = poolId1;
        poolIds[1] = poolId2;

        uint16[] memory tiers = new uint16[](1);
        tiers[0] = 3;

        vm.prank(updater);
        vm.expectRevert("Length mismatch");
        oracle.batchSetVelocityTiers(poolIds, tiers);
    }

    function test_BatchSetVelocityTiers_SkipsRateLimited() public {
        // Advance time first
        vm.warp(block.timestamp + 61);

        // Set initial tier for poolId1
        vm.prank(updater);
        oracle.setVelocityTier(poolId1, 2);

        // Batch update immediately (poolId1 should be skipped due to rate limit)
        PoolId[] memory poolIds = new PoolId[](2);
        poolIds[0] = poolId1;
        poolIds[1] = poolId2;

        uint16[] memory tiers = new uint16[](2);
        tiers[0] = 5; // This should be skipped
        tiers[1] = 7; // This should succeed

        vm.prank(updater);
        oracle.batchSetVelocityTiers(poolIds, tiers);

        assertEq(oracle.getVelocityTier(poolId1), 2); // Unchanged
        assertEq(oracle.getVelocityTier(poolId2), 7); // Updated
    }

    // ============================================
    // View Function Tests
    // ============================================

    function test_GetVelocityTier_Default() public {
        assertEq(oracle.getVelocityTier(poolId1), 0);
    }

    function test_GetPoolInfo() public {
        vm.warp(block.timestamp + 61);
        vm.prank(updater);
        oracle.setVelocityTier(poolId1, 6);

        (uint16 tier, uint64 lastUpdate, uint64 lastIngestion) = oracle.getPoolInfo(poolId1);

        assertEq(tier, 6);
        assertEq(lastUpdate, uint64(block.timestamp));
        assertEq(lastIngestion, 0); // No ingestion yet
    }

    // ============================================
    // Admin Function Tests
    // ============================================

    function test_SetUpdater() public {
        address newUpdater = makeAddr("newUpdater");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit UpdaterChanged(updater, newUpdater);

        oracle.setUpdater(newUpdater);

        assertEq(oracle.updater(), newUpdater);

        // Advance time to avoid rate limit
        vm.warp(block.timestamp + 61);

        // Old updater can't update anymore
        vm.prank(updater);
        vm.expectRevert(VelocityOracleCoFHE.UnauthorizedUpdater.selector);
        oracle.setVelocityTier(poolId1, 5);

        // New updater can update
        vm.prank(newUpdater);
        oracle.setVelocityTier(poolId1, 5);
        assertEq(oracle.getVelocityTier(poolId1), 5);
    }

    function test_SetUpdater_RevertIf_NotOwner() public {
        address newUpdater = makeAddr("newUpdater");

        vm.prank(user);
        vm.expectRevert("UNAUTHORIZED");
        oracle.setUpdater(newUpdater);
    }

    function test_ResetPoolState() public {
        // Advance time
        vm.warp(block.timestamp + 61);

        // Set up a pool with a tier
        vm.prank(updater);
        oracle.setVelocityTier(poolId1, 8);

        // Reset it
        vm.prank(owner);
        oracle.resetPoolState(poolId1);

        (uint16 tier, uint64 lastUpdate, uint64 lastIngestion) = oracle.getPoolInfo(poolId1);

        assertEq(tier, 0);
        assertEq(lastUpdate, uint64(block.timestamp));
        assertEq(lastIngestion, 0);
    }

    function test_ResetPoolState_RevertIf_NotOwner() public {
        vm.prank(user);
        vm.expectRevert("UNAUTHORIZED");
        oracle.resetPoolState(poolId1);
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    function testFuzz_SetVelocityTier(uint16 tier) public {
        tier = uint16(bound(tier, 0, 10));

        // Advance time to avoid rate limit
        vm.warp(block.timestamp + 61);

        vm.prank(updater);
        oracle.setVelocityTier(poolId1, tier);

        assertEq(oracle.getVelocityTier(poolId1), tier);
    }

    function testFuzz_MultiplePools(uint8 numPools) public {
        numPools = uint8(bound(numPools, 1, 20));

        for (uint8 i = 0; i < numPools; i++) {
            PoolId poolId = PoolId.wrap(keccak256(abi.encodePacked("pool", i)));
            uint16 tier = uint16(i % 11); // 0-10

            // Advance time for each pool to avoid rate limit
            vm.warp(block.timestamp + 61);

            vm.prank(updater);
            oracle.setVelocityTier(poolId, tier);

            assertEq(oracle.getVelocityTier(poolId), tier);
        }
    }

    // ============================================
    // Velocity Parameter Tests
    // ============================================

    function test_SetVelocityParams() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit VelocityParamsSet(poolId1, VelocityOracleCoFHE.VelocityParams({
            baseBps: 10,
            minBps: 5,
            maxBps: 120,
            tauSec: 180,
            target1e18: 1e16,
            k1e18: 1e18,
            capMultiplier: 5,
            usePrice: true
        }));

        oracle.setVelocityParams(
            poolId1,
            10,      // baseBps
            5,       // minBps
            120,     // maxBps
            180,     // tauSec
            1e16,    // target1e18
            1e18,    // k1e18
            5,       // capMultiplier
            true     // usePrice
        );

        // Verify parameters were set
        (uint32 baseBps, uint32 minBps, uint32 maxBps, uint64 tauSec, uint256 target1e18, uint256 k1e18, uint8 capMultiplier, bool usePrice)
            = oracle.params(poolId1);

        assertEq(baseBps, 10);
        assertEq(minBps, 5);
        assertEq(maxBps, 120);
        assertEq(tauSec, 180);
        assertEq(target1e18, 1e16);
        assertEq(k1e18, 1e18);
        assertEq(capMultiplier, 5);
        assertEq(usePrice, true);
    }

    function test_SetVelocityParams_RevertIf_NotOwner() public {
        vm.prank(user);
        vm.expectRevert("UNAUTHORIZED");
        oracle.setVelocityParams(poolId1, 10, 5, 120, 180, 1e16, 1e18, 5, true);
    }

    function test_SetVelocityParams_RevertIf_InvalidParams() public {
        // minBps >= maxBps
        vm.prank(owner);
        vm.expectRevert(VelocityOracleCoFHE.InvalidParams.selector);
        oracle.setVelocityParams(poolId1, 10, 120, 5, 180, 1e16, 1e18, 5, true);

        // tauSec == 0
        vm.prank(owner);
        vm.expectRevert(VelocityOracleCoFHE.InvalidParams.selector);
        oracle.setVelocityParams(poolId1, 10, 5, 120, 0, 1e16, 1e18, 5, true);

        // target1e18 == 0
        vm.prank(owner);
        vm.expectRevert(VelocityOracleCoFHE.InvalidParams.selector);
        oracle.setVelocityParams(poolId1, 10, 5, 120, 180, 0, 1e18, 5, true);

        // capMultiplier == 0
        vm.prank(owner);
        vm.expectRevert(VelocityOracleCoFHE.InvalidParams.selector);
        oracle.setVelocityParams(poolId1, 10, 5, 120, 180, 1e16, 1e18, 0, true);
    }

    function test_SetDefaultVelocityParams_PriceMode() public {
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, true);

        (uint32 baseBps, uint32 minBps, uint32 maxBps, uint64 tauSec, uint256 target1e18, uint256 k1e18, uint8 capMultiplier, bool usePrice)
            = oracle.params(poolId1);

        assertEq(baseBps, 10);
        assertEq(minBps, 5);
        assertEq(maxBps, 120);
        assertEq(tauSec, 180);
        assertEq(target1e18, 1e16);
        assertEq(k1e18, 1e18);
        assertEq(capMultiplier, 5);
        assertEq(usePrice, true);
    }

    function test_SetDefaultVelocityParams_FlowMode() public {
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, false);

        (, , , , , , , bool usePrice) = oracle.params(poolId1);
        assertEq(usePrice, false);
    }

    function test_SetDefaultVelocityParams_RevertIf_NotOwner() public {
        vm.prank(user);
        vm.expectRevert("UNAUTHORIZED");
        oracle.setDefaultVelocityParams(poolId1, true);
    }

    // ============================================
    // Velocity Update Tests
    // ============================================

    function test_UpdateVelocity_FirstObservation() public {
        // Set up parameters
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, true);

        // First update - should just initialize observation
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // Check observation was initialized
        (uint64 lastTimestamp, uint160 lastSqrtPriceX96, uint256 ema1e18) = oracle.obs(poolId1);
        assertEq(lastTimestamp, block.timestamp);
        assertEq(lastSqrtPriceX96, 1e18);
        assertEq(ema1e18, 0); // EMA not updated on first observation
    }

    function test_UpdateVelocity_PriceMode() public {
        // Set up parameters with price velocity
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, true);

        // Initialize with first observation
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // Advance time and update with new price
        vm.warp(block.timestamp + 10);

        uint160 oldPrice = 1e18;
        uint160 newPrice = 1.1e18; // 10% price increase

        vm.expectEmit(true, false, false, false);
        emit VelocityUpdated(poolId1, 0, 0, uint64(block.timestamp));

        oracle.updateVelocity(poolId1, newPrice, 1000, 1e18);

        // Calculate expected EMA
        // Default params: tauSec = 180
        // dt = 10, so alpha = 10 * 1e18 / 180 ≈ 0.0555 * 1e18
        // x (price velocity) = |1.1e18 - 1e18| * 1e18 / 1e18 = 0.1e18
        // ema_old = 0
        // ema_new = alpha * x / 1e18 = (10 * 1e18 / 180) * 0.1e18 / 1e18
        //         = 10 * 0.1e18 / 180 = 5555555555555555
        uint256 dt = 10;
        uint256 tau = 180;
        uint256 alpha = (dt * 1e18) / tau;
        uint256 x = 1e17; // 0.1 in 1e18 scale
        uint256 expectedEma = (alpha * x) / 1e18;

        // Verify observation was updated
        (uint64 lastTimestamp, uint160 lastSqrtPriceX96, uint256 ema1e18) = oracle.obs(poolId1);
        assertEq(lastTimestamp, block.timestamp);
        assertEq(lastSqrtPriceX96, newPrice);
        assertApproxEqRel(ema1e18, expectedEma, 0.01e18); // Within 1%
        assertGt(ema1e18, 0); // EMA should be updated
    }

    function test_UpdateVelocity_FlowMode() public {
        // Set up parameters with flow velocity
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, false);

        // Initialize with first observation
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // Advance time and update with large amount relative to liquidity
        vm.warp(block.timestamp + 10);

        uint128 liquidity = 1e18;
        int256 largeAmount = int256(uint256(liquidity) / 10); // 10% of liquidity

        vm.expectEmit(true, false, false, false);
        emit VelocityUpdated(poolId1, 0, 0, uint64(block.timestamp));

        oracle.updateVelocity(poolId1, 1e18, largeAmount, liquidity);

        // Calculate expected EMA
        // Default params: tauSec = 180
        // dt = 10, so alpha = 10 * 1e18 / 180 = 0.0555... * 1e18
        // x (flow velocity) = |1e17| * 1e18 / 1e18 = 1e17 (0.1 in 1e18)
        // ema_old = 0
        // ema_new = alpha * x + (1 - alpha) * ema_old
        //         = (10 * 1e18 / 180) * 1e17 / 1e18
        //         = 10 * 1e17 / 180
        //         = 5555555555555555 (approximately)
        uint256 dt2 = 10;
        uint256 tau2 = 180;
        uint256 alpha2 = (dt2 * 1e18) / tau2;
        uint256 x2 = 1e17; // 0.1 in 1e18 scale
        uint256 expectedEma = (alpha2 * x2) / 1e18;

        // Verify observation was updated
        (,, uint256 ema1e18) = oracle.obs(poolId1);
        assertApproxEqRel(ema1e18, expectedEma, 0.01e18); // Within 1%
        assertGt(ema1e18, 0); // EMA should reflect flow velocity
    }

    function test_UpdateVelocity_EMADecay() public {
        // Set up parameters
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, true);

        // Initialize
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // First update with price movement
        vm.warp(block.timestamp + 10);
        oracle.updateVelocity(poolId1, 1.1e18, 1000, 1e18);
        (,, uint256 ema1) = oracle.obs(poolId1);

        // Second update with no price movement - EMA should decay
        vm.warp(block.timestamp + 10);
        oracle.updateVelocity(poolId1, 1.1e18, 1000, 1e18);
        (,, uint256 ema2) = oracle.obs(poolId1);

        // EMA should decrease when velocity signal is 0
        assertLt(ema2, ema1);
    }

    function test_UpdateVelocity_TierChanges() public {
        // Set up parameters
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, true);

        // Initialize
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // Large price movement should increase tier
        vm.warp(block.timestamp + 10);

        // VelocityUpdated event will be emitted (not VelocityTierUpdated unless tier actually changes)
        oracle.updateVelocity(poolId1, 2e18, 1000, 1e18); // 100% price increase

        uint16 tier = oracle.getVelocityTier(poolId1);
        // Tier should be updated based on velocity
        assertLe(tier, 10);
    }

    function test_UpdateVelocity_SkipsIfNoParams() public {
        // No parameters set for poolId1
        // First update should initialize observation
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // Observation should not be updated
        (uint64 lastTimestamp,,) = oracle.obs(poolId1);
        assertEq(lastTimestamp, 0);
    }

    function test_UpdateVelocity_SkipsIfSameBlock() public {
        // Set up parameters
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, true);

        // Initialize
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // Try to update in same block - should skip EMA update
        (,, uint256 emaBefore) = oracle.obs(poolId1);
        oracle.updateVelocity(poolId1, 1.1e18, 1000, 1e18);
        (,, uint256 emaAfter) = oracle.obs(poolId1);

        assertEq(emaBefore, emaAfter); // EMA unchanged
    }

    function test_UpdateVelocity_ZeroLiquidity() public {
        // Set up parameters with flow velocity
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, false);

        // Initialize
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // Update with zero liquidity - should handle gracefully
        vm.warp(block.timestamp + 10);
        oracle.updateVelocity(poolId1, 1e18, 1000, 0);

        // Should not revert
        (,, uint256 ema) = oracle.obs(poolId1);
        // EMA should update with 0 velocity signal
        assertEq(ema, 0);
    }

    function test_UpdateVelocity_NegativeAmount() public {
        // Set up parameters with flow velocity
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, false);

        // Initialize
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // Update with negative amount (exactOutput swap)
        vm.warp(block.timestamp + 10);
        oracle.updateVelocity(poolId1, 1e18, -1000, 1e18);

        // Should handle absolute value correctly
        (,, uint256 ema) = oracle.obs(poolId1);
        assertGt(ema, 0); // Should use absolute value of amount
    }

    // ============================================
    // Edge Case Tests
    // ============================================

    function test_UpdateVelocity_LargeTimeGap() public {
        // Set up parameters (tau = 180s)
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, true);

        // Initialize
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // Large time gap (dt >> tau)
        vm.warp(block.timestamp + 1000);
        oracle.updateVelocity(poolId1, 1.1e18, 1000, 1e18);

        // Alpha should be capped at 1, so EMA should fully update to current signal
        (,, uint256 ema) = oracle.obs(poolId1);
        assertGt(ema, 0);
    }

    function test_UpdateVelocity_MultipleUpdates() public {
        // Set up parameters
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, true);

        // Initialize
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        uint256 lastEma = 0;

        // Simulate multiple swaps with increasing velocity
        for (uint i = 1; i <= 5; i++) {
            vm.warp(block.timestamp + 10);
            uint160 newPrice = uint160(1e18 + (i * 1e17)); // Incremental price increases
            oracle.updateVelocity(poolId1, newPrice, 1000, 1e18);

            (,, uint256 ema) = oracle.obs(poolId1);
            // EMA should generally increase with consistent price movements
            if (i > 1) {
                assertGt(ema, lastEma);
            }
            lastEma = ema;
        }
    }

    function test_GetVelocityTier_AfterVelocityUpdate() public {
        // Set up parameters
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, true);

        uint16 initialTier = oracle.getVelocityTier(poolId1);
        assertEq(initialTier, 0);

        // Initialize
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // Update with significant price movement
        vm.warp(block.timestamp + 10);
        oracle.updateVelocity(poolId1, 1.5e18, 1000, 1e18);

        // Tier may have changed based on velocity
        uint16 newTier = oracle.getVelocityTier(poolId1);
        // Tier should be within valid range
        assertLe(newTier, 10);
    }

    // ============================================
    // Integration Tests
    // ============================================

    function test_VelocityWorkflow_PriceMode() public {
        // Complete workflow test for price velocity mode

        // 1. Owner sets up velocity parameters
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, true);

        // 2. First swap initializes observation
        oracle.updateVelocity(poolId1, 1e18, 1000, 1e18);

        // 3. Series of swaps with varying price movements
        // Default params: tau = 180, dt = 10 each time, so alpha = 10/180 ≈ 0.0555
        uint256 dt = 10;
        uint256 tau = 180;
        uint256 alpha = (dt * 1e18) / tau;

        // Swap 1: 5% price increase (1e18 -> 1.05e18)
        vm.warp(block.timestamp + 10);
        oracle.updateVelocity(poolId1, 1.05e18, 500, 1e18);
        // x1 = |1.05e18 - 1e18| / 1e18 = 0.05
        uint256 expectedEma1 = (alpha * 5e16) / 1e18; // 0.05 in 1e18 scale
        (,, uint256 ema1) = oracle.obs(poolId1);
        assertApproxEqRel(ema1, expectedEma1, 0.01e18);

        // Swap 2: Price goes from 1.05e18 to 1.15e18 (~9.5% increase)
        vm.warp(block.timestamp + 10);
        oracle.updateVelocity(poolId1, 1.15e18, 2000, 1e18);
        // x2 = |1.15e18 - 1.05e18| / 1.05e18 ≈ 0.095
        uint256 diff2 = 1.15e18 - 1.05e18;
        uint256 x2 = (diff2 * 1e18) / 1.05e18;
        uint256 expectedEma2 = (alpha * x2 + (1e18 - alpha) * ema1) / 1e18;
        (,, uint256 ema2) = oracle.obs(poolId1);
        assertApproxEqRel(ema2, expectedEma2, 0.02e18); // 2% tolerance for rounding
        assertGt(ema2, ema1); // EMA should increase

        // Swap 3: Price drops from 1.15e18 to 1.1e18 (~4.3% decrease)
        vm.warp(block.timestamp + 10);
        oracle.updateVelocity(poolId1, 1.1e18, 500, 1e18);
        // x3 = |1.1e18 - 1.15e18| / 1.15e18 ≈ 0.043
        uint256 diff3 = 1.15e18 - 1.1e18;
        uint256 x3 = (diff3 * 1e18) / 1.15e18;
        uint256 expectedEma3 = (alpha * x3 + (1e18 - alpha) * ema2) / 1e18;
        (,, uint256 ema3) = oracle.obs(poolId1);
        assertApproxEqRel(ema3, expectedEma3, 0.02e18); // 2% tolerance

        // 4. Check that tier reflects accumulated velocity
        uint16 finalTier = oracle.getVelocityTier(poolId1);
        assertLe(finalTier, 10);

        // 5. Verify observation state
        (uint64 lastTimestamp, uint160 lastPrice,) = oracle.obs(poolId1);
        assertEq(lastTimestamp, block.timestamp);
        assertEq(lastPrice, 1.1e18);
        assertGt(ema3, 0);
    }

    function test_VelocityWorkflow_FlowMode() public {
        // Complete workflow test for flow velocity mode

        // 1. Owner sets up velocity parameters for flow mode
        vm.prank(owner);
        oracle.setDefaultVelocityParams(poolId1, false);

        uint128 liquidity = 1e18;

        // 2. First swap initializes observation
        oracle.updateVelocity(poolId1, 1e18, 1000, liquidity);

        // 3. Series of swaps with varying amounts
        // Default params: tau = 180, dt = 10 each time, so alpha = 10/180 ≈ 0.0555
        uint256 dt = 10;
        uint256 tau = 180;
        uint256 alpha = (dt * 1e18) / tau;

        // Swap 1: 1% of liquidity
        vm.warp(block.timestamp + 10);
        oracle.updateVelocity(poolId1, 1e18, int256(uint256(liquidity) / 100), liquidity);
        // x1 = 0.01, ema1 = alpha * 0.01 = 0.000555...
        uint256 expectedEma1 = (alpha * 1e16) / 1e18; // 0.01 in 1e18 scale
        (,, uint256 ema1) = oracle.obs(poolId1);
        assertApproxEqRel(ema1, expectedEma1, 0.01e18);

        // Swap 2: 5% of liquidity
        vm.warp(block.timestamp + 10);
        oracle.updateVelocity(poolId1, 1e18, int256(uint256(liquidity) / 20), liquidity);
        // x2 = 0.05, ema2 = alpha * 0.05 + (1-alpha) * ema1
        uint256 x2 = 5e16; // 0.05 in 1e18 scale
        uint256 expectedEma2 = (alpha * x2 + (1e18 - alpha) * ema1) / 1e18;
        (,, uint256 ema2) = oracle.obs(poolId1);
        assertApproxEqRel(ema2, expectedEma2, 0.01e18);
        assertGt(ema2, ema1); // EMA should increase

        // Swap 3: 10% of liquidity
        vm.warp(block.timestamp + 10);
        oracle.updateVelocity(poolId1, 1e18, int256(uint256(liquidity) / 10), liquidity);
        // x3 = 0.1, ema3 = alpha * 0.1 + (1-alpha) * ema2
        uint256 x3 = 1e17; // 0.1 in 1e18 scale
        uint256 expectedEma3 = (alpha * x3 + (1e18 - alpha) * ema2) / 1e18;
        (,, uint256 ema3) = oracle.obs(poolId1);
        assertApproxEqRel(ema3, expectedEma3, 0.01e18);
        assertGt(ema3, ema2); // EMA should continue increasing

        // 4. Check that tier reflects accumulated flow velocity
        uint16 finalTier = oracle.getVelocityTier(poolId1);
        assertLe(finalTier, 10);

        // 5. Verify final EMA is positive and reflects the sequence
        assertGt(ema3, 0);
    }
}
