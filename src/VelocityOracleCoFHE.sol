// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FHE, euint32, inEuint32} from "fhenix-contracts/FHE.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

/**
 * @title VelocityOracleCoFHE
 * @notice CoFHE-powered oracle that computes velocity scores from encrypted trading data
 * @dev Uses Fhenix FHE to maintain privacy while computing velocity metrics
 */
contract VelocityOracleCoFHE is Owned {
    using PoolIdLibrary for PoolId;

    // ============================================
    // State Variables
    // ============================================

    /// @notice Pool-specific encrypted state and public velocity tier
    struct PoolState {
        euint32 encVolume;        // Encrypted cumulative volume
        euint32 encPriceChange;   // Encrypted price change metric
        euint32 encTradeCount;    // Encrypted number of trades
        uint16 velocityTier;      // Public velocity tier (0-10)
        uint64 lastUpdate;        // Last update timestamp
        uint64 lastIngestion;     // Last data ingestion timestamp
    }

    /// @notice Velocity calculation parameters per pool
    struct VelocityParams {
        uint32 baseBps;           // Base fee in basis points (e.g., 10)
        uint32 minBps;            // Minimum fee in bps (e.g., 5)
        uint32 maxBps;            // Maximum fee in bps (e.g., 120)
        uint64 tauSec;            // EMA half-life in seconds (e.g., 180)
        uint256 target1e18;       // Scaling target for EMA (1e18 fixed-point)
        uint256 k1e18;            // Slope multiplier (1e18 fixed-point)
        uint8 capMultiplier;      // Cap for ratio (e.g., 5 = 5x)
        bool usePrice;            // true: price velocity, false: flow velocity
    }

    /// @notice Observation state for velocity EMA calculation
    struct Observation {
        uint64 lastTimestamp;     // Last observation timestamp
        uint160 lastSqrtPriceX96; // Last sqrtPrice (Q64.96 format)
        uint256 ema1e18;          // Current EMA value (1e18 fixed-point)
    }

    /// @notice Mapping from PoolId to PoolState
    mapping(PoolId => PoolState) public pools;

    /// @notice Mapping from PoolId to VelocityParams
    mapping(PoolId => VelocityParams) public params;

    /// @notice Mapping from PoolId to Observation
    mapping(PoolId => Observation) public obs;

    /// @notice Address authorized to update velocity tiers (CoFHE worker/committee)
    address public updater;

    /// @notice Maximum allowed velocity tier
    uint16 public constant MAX_VELOCITY_TIER = 10;

    /// @notice Minimum time between tier updates (prevents spam)
    uint64 public constant MIN_UPDATE_INTERVAL = 60; // 1 minute

    /// @notice Fixed-point scale (1e18)
    uint256 public constant SCALE_1E18 = 1e18;

    // ============================================
    // Events
    // ============================================

    event DataIngested(PoolId indexed poolId, uint64 timestamp);
    event VelocityTierUpdated(PoolId indexed poolId, uint16 oldTier, uint16 newTier, uint64 timestamp);
    event UpdaterChanged(address indexed oldUpdater, address indexed newUpdater);
    event VelocityUpdated(PoolId indexed poolId, uint256 ema1e18, uint16 tier, uint64 timestamp);
    event VelocityParamsSet(PoolId indexed poolId, VelocityParams params);

    // ============================================
    // Errors
    // ============================================

    error UnauthorizedUpdater();
    error InvalidTier();
    error UpdateTooFrequent();
    error InvalidParams();

    // ============================================
    // Constructor
    // ============================================

    /**
     * @notice Initializes the oracle with owner and updater addresses
     * @param _owner Owner address (can change updater)
     * @param _updater CoFHE worker address authorized to update tiers
     */
    constructor(address _owner, address _updater) Owned(_owner) {
        updater = _updater;
    }

    // ============================================
    // Modifiers
    // ============================================

  
    modifier onlyUpdater() {
        _onlyUpdater();
        _;
    }

   function _onlyUpdater() internal {
        if (msg.sender != updater) revert UnauthorizedUpdater();
    }

    // ============================================
    // Core Functions
    // ============================================

    /**
     * @notice Ingests encrypted trading data for a pool
     * @dev Can be called by anyone (frontends, routers, aggregators)
     * @param poolId The pool identifier
     * @param encVolumeDelta Encrypted volume contribution
     * @param encPriceChangeDelta Encrypted price change contribution
     */
    function ingestTradeData(
        PoolId poolId,
        inEuint32 calldata encVolumeDelta,
        inEuint32 calldata encPriceChangeDelta
    ) external {
        PoolState storage state = pools[poolId];

        // Convert input ciphertexts to euint32
        euint32 volumeDelta = FHE.asEuint32(encVolumeDelta);
        euint32 priceChangeDelta = FHE.asEuint32(encPriceChangeDelta);

        // Update encrypted aggregates
        state.encVolume = FHE.add(state.encVolume, volumeDelta);
        state.encPriceChange = FHE.add(state.encPriceChange, priceChangeDelta);

        // Increment trade count by 1
        euint32 one = FHE.asEuint32(1);
        state.encTradeCount = FHE.add(state.encTradeCount, one);

        state.lastIngestion = uint64(block.timestamp);

        emit DataIngested(poolId, uint64(block.timestamp));
    }

    /**
     * @notice Ingests simple encrypted volume (lightweight version)
     * @param poolId The pool identifier
     * @param encVolumeDelta Encrypted volume delta
     */
    function ingestVolume(PoolId poolId, inEuint32 calldata encVolumeDelta) external {
        PoolState storage state = pools[poolId];
        euint32 volumeDelta = FHE.asEuint32(encVolumeDelta);
        state.encVolume = FHE.add(state.encVolume, volumeDelta);
        state.lastIngestion = uint64(block.timestamp);
        emit DataIngested(poolId, uint64(block.timestamp));
    }

    /**
     * @notice Updates the velocity tier for a pool (called by CoFHE worker)
     * @dev Only updater can call this after off-chain FHE computation
     * @param poolId The pool identifier
     * @param newTier The computed velocity tier (0-10)
     */
    function setVelocityTier(PoolId poolId, uint16 newTier) external onlyUpdater {
        if (newTier > MAX_VELOCITY_TIER) revert InvalidTier();

        PoolState storage state = pools[poolId];

        // Rate limiting
        if (block.timestamp - state.lastUpdate < MIN_UPDATE_INTERVAL) {
            revert UpdateTooFrequent();
        }

        uint16 oldTier = state.velocityTier;
        state.velocityTier = newTier;
        state.lastUpdate = uint64(block.timestamp);

        emit VelocityTierUpdated(poolId, oldTier, newTier, uint64(block.timestamp));
    }

    /**
     * @notice Batch update velocity tiers for multiple pools
     * @param poolIds Array of pool identifiers
     * @param newTiers Array of corresponding velocity tiers
     */
    function batchSetVelocityTiers(
        PoolId[] calldata poolIds,
        uint16[] calldata newTiers
    ) external onlyUpdater {
        require(poolIds.length == newTiers.length, "Length mismatch");

        for (uint256 i = 0; i < poolIds.length; i++) {
            if (newTiers[i] > MAX_VELOCITY_TIER) revert InvalidTier();

            PoolState storage state = pools[poolIds[i]];

            // Skip if too frequent
            if (block.timestamp - state.lastUpdate < MIN_UPDATE_INTERVAL) {
                continue;
            }

            uint16 oldTier = state.velocityTier;
            state.velocityTier = newTiers[i];
            state.lastUpdate = uint64(block.timestamp);

            emit VelocityTierUpdated(poolIds[i], oldTier, newTiers[i], uint64(block.timestamp));
        }
    }

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Gets the current velocity tier for a pool
     * @param poolId The pool identifier
     * @return The velocity tier (0-10)
     */
    function getVelocityTier(PoolId poolId) external view returns (uint16) {
        return pools[poolId].velocityTier;
    }

    /**
     * @notice Gets complete pool state (excluding encrypted data)
     * @param poolId The pool identifier
     * @return velocityTier Current velocity tier
     * @return lastUpdate Last tier update timestamp
     * @return lastIngestion Last data ingestion timestamp
     */
    function getPoolInfo(PoolId poolId)
        external
        view
        returns (uint16 velocityTier, uint64 lastUpdate, uint64 lastIngestion)
    {
        PoolState storage state = pools[poolId];
        return (state.velocityTier, state.lastUpdate, state.lastIngestion);
    }

    // ============================================
    // Velocity Calculation Functions
    // ============================================

    /**
     * @notice Updates velocity EMA and tier from new swap data
     * @dev Called by hook after each swap to update on-chain velocity
     * @param poolId The pool identifier
     * @param newSqrtPriceX96 Post-swap sqrtPrice (Q64.96 format)
     * @param amountSpecified Amount specified in swap
     * @param liquidity Current pool liquidity
     */
    function updateVelocity(
        PoolId poolId,
        uint160 newSqrtPriceX96,
        int256 amountSpecified,
        uint128 liquidity
    ) external {
        Observation storage ob = obs[poolId];
        VelocityParams storage p = params[poolId];

        // Skip if no params configured
        if (p.tauSec == 0) return;

        uint256 dt = block.timestamp - ob.lastTimestamp;

        // Skip if same block or first observation
        if (dt == 0 || ob.lastTimestamp == 0) {
            // Initialize observation
            ob.lastTimestamp = uint64(block.timestamp);
            ob.lastSqrtPriceX96 = newSqrtPriceX96;
            return;
        }

        // Calculate alpha (EMA decay factor)
        uint256 alpha = _calculateAlpha(dt, p.tauSec);

        // Calculate velocity signal based on mode
        uint256 x;
        if (p.usePrice) {
            x = _calculatePriceVelocity(newSqrtPriceX96, ob.lastSqrtPriceX96);
        } else {
            x = _calculateFlowVelocity(amountSpecified, liquidity);
        }

        // Update EMA: ema_new = alpha * x + (1 - alpha) * ema_old
        uint256 emaNew = (alpha * x + (SCALE_1E18 - alpha) * ob.ema1e18) / SCALE_1E18;

        // Calculate new tier from EMA
        uint16 newTier = _calculateTierFromEMA(emaNew, p);

        // Update observation state
        ob.ema1e18 = emaNew;
        ob.lastSqrtPriceX96 = newSqrtPriceX96;
        ob.lastTimestamp = uint64(block.timestamp);

        // Update pool state if tier changed
        PoolState storage state = pools[poolId];
        if (state.velocityTier != newTier) {
            uint16 oldTier = state.velocityTier;
            state.velocityTier = newTier;
            state.lastUpdate = uint64(block.timestamp);
            emit VelocityTierUpdated(poolId, oldTier, newTier, uint64(block.timestamp));
        }

        emit VelocityUpdated(poolId, emaNew, newTier, uint64(block.timestamp));
    }

    /**
     * @notice Calculates EMA decay factor (alpha)
     * @dev alpha = 1 - e^(-dt/tau), approximated as dt/tau for efficiency
     * @param dt Time delta in seconds
     * @param tau EMA half-life in seconds
     * @return alpha Decay factor in 1e18 fixed-point
     */
    function _calculateAlpha(uint256 dt, uint64 tau) internal pure returns (uint256) {
        // For large dt, alpha approaches 1
        if (dt >= tau) return SCALE_1E18;

        // Linear approximation: alpha ≈ dt/tau (accurate for small dt/tau)
        return (dt * SCALE_1E18) / tau;
    }

    /**
     * @notice Calculates price velocity signal
     * @dev |ΔlnP| = |ln(new/old)| ≈ |new - old| / old for small changes
     * @param newPrice New sqrtPriceX96
     * @param oldPrice Old sqrtPriceX96
     * @return velocity Price velocity in 1e18 fixed-point
     */
    function _calculatePriceVelocity(uint160 newPrice, uint160 oldPrice)
        internal
        pure
        returns (uint256)
    {
        if (oldPrice == 0) return 0;

        // Calculate absolute difference
        uint256 diff = newPrice > oldPrice
            ? uint256(newPrice - oldPrice)
            : uint256(oldPrice - newPrice);

        // Return |ΔP| / P_old (approximation of |ΔlnP|)
        return (diff * SCALE_1E18) / oldPrice;
    }

    /**
     * @notice Calculates flow velocity signal
     * @dev |amountSpecified| / liquidity
     * @param amountSpecified Swap amount specified
     * @param liquidity Current pool liquidity
     * @return velocity Flow velocity in 1e18 fixed-point
     */
    function _calculateFlowVelocity(int256 amountSpecified, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        if (liquidity == 0) return 0;

        // Get absolute value of amount
        uint256 absAmount = amountSpecified < 0
            ? uint256(-amountSpecified)
            : uint256(amountSpecified);

        // Return |amount| / L
        return (absAmount * SCALE_1E18) / liquidity;
    }

    /**
     * @notice Calculates velocity tier from EMA value
     * @dev Maps EMA → fee (bps) → tier (0-10)
     * @param ema Current EMA value (1e18 fixed-point)
     * @param p Velocity parameters
     * @return tier Velocity tier (0-10)
     */
    function _calculateTierFromEMA(uint256 ema, VelocityParams storage p)
        internal
        view
        returns (uint16)
    {
        // Calculate ratio = ema / target (capped at capMultiplier)
        uint256 ratio = (ema * SCALE_1E18) / p.target1e18;
        uint256 cap = uint256(p.capMultiplier) * SCALE_1E18;
        if (ratio > cap) ratio = cap;

        // Calculate fee: baseBps + k * ratio
        uint256 feeBps = p.baseBps + (uint256(p.k1e18) * ratio) / SCALE_1E18;

        // Clamp fee to [minBps, maxBps]
        if (feeBps < p.minBps) feeBps = p.minBps;
        if (feeBps > p.maxBps) feeBps = p.maxBps;

        // Map fee linearly to tier (0-10)
        // tier = (fee - min) * 10 / (max - min)
        uint256 feeRange = p.maxBps - p.minBps;
        if (feeRange == 0) return 0;

        return uint16((feeBps - p.minBps) * 10 / feeRange);
    }

    // ============================================
    // Admin Functions
    // ============================================

    /**
     * @notice Sets velocity parameters for a pool
     * @dev Only owner can configure velocity calculation parameters
     * @param poolId The pool identifier
     * @param baseBps Base fee in basis points (e.g., 10)
     * @param minBps Minimum fee in bps (e.g., 5)
     * @param maxBps Maximum fee in bps (e.g., 120)
     * @param tauSec EMA half-life in seconds (e.g., 180)
     * @param target1e18 Scaling target for EMA (1e18 fixed-point)
     * @param k1e18 Slope multiplier (1e18 fixed-point)
     * @param capMultiplier Cap for ratio (e.g., 5 = 5x)
     * @param usePrice true: price velocity, false: flow velocity
     */
    function setVelocityParams(
        PoolId poolId,
        uint32 baseBps,
        uint32 minBps,
        uint32 maxBps,
        uint64 tauSec,
        uint256 target1e18,
        uint256 k1e18,
        uint8 capMultiplier,
        bool usePrice
    ) external onlyOwner {
        // Validate parameters
        if (minBps >= maxBps) revert InvalidParams();
        if (tauSec == 0) revert InvalidParams();
        if (target1e18 == 0) revert InvalidParams();
        if (capMultiplier == 0) revert InvalidParams();

        params[poolId] = VelocityParams({
            baseBps: baseBps,
            minBps: minBps,
            maxBps: maxBps,
            tauSec: tauSec,
            target1e18: target1e18,
            k1e18: k1e18,
            capMultiplier: capMultiplier,
            usePrice: usePrice
        });

        emit VelocityParamsSet(poolId, params[poolId]);
    }

    /**
     * @notice Sets default velocity parameters for a pool
     * @dev Convenient function to set sensible defaults
     * @param poolId The pool identifier
     * @param usePrice true: price velocity, false: flow velocity
     */
    function setDefaultVelocityParams(PoolId poolId, bool usePrice) external onlyOwner {
        params[poolId] = VelocityParams({
            baseBps: 10,              // 0.1% base fee
            minBps: 5,                // 0.05% minimum
            maxBps: 120,              // 1.2% maximum
            tauSec: 180,              // 3 minute half-life
            target1e18: 1e16,         // 1% target (0.01 in 1e18)
            k1e18: 1e18,              // 1:1 slope
            capMultiplier: 5,         // 5x cap
            usePrice: usePrice
        });

        emit VelocityParamsSet(poolId, params[poolId]);
    }

    /**
     * @notice Changes the authorized updater address
     * @param newUpdater New updater address
     */
    function setUpdater(address newUpdater) external onlyOwner {
        address oldUpdater = updater;
        updater = newUpdater;
        emit UpdaterChanged(oldUpdater, newUpdater);
    }

    /**
     * @notice Emergency function to reset a pool's encrypted state
     * @dev Only owner can call this in case of issues
     * @param poolId The pool identifier
     */
    function resetPoolState(PoolId poolId) external onlyOwner {
        // Delete the entire pool state (FHE types cannot be deleted individually)
        delete pools[poolId];

        // Reinitialize with current timestamp
        pools[poolId].lastUpdate = uint64(block.timestamp);
    }
}
