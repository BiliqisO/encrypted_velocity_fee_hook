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

    /// @notice Mapping from PoolId to PoolState
    mapping(PoolId => PoolState) public pools;

    /// @notice Address authorized to update velocity tiers (CoFHE worker/committee)
    address public updater;

    /// @notice Maximum allowed velocity tier
    uint16 public constant MAX_VELOCITY_TIER = 10;

    /// @notice Minimum time between tier updates (prevents spam)
    uint64 public constant MIN_UPDATE_INTERVAL = 60; // 1 minute

    // ============================================
    // Events
    // ============================================

    event DataIngested(PoolId indexed poolId, uint64 timestamp);
    event VelocityTierUpdated(PoolId indexed poolId, uint16 oldTier, uint16 newTier, uint64 timestamp);
    event UpdaterChanged(address indexed oldUpdater, address indexed newUpdater);

    // ============================================
    // Errors
    // ============================================

    error UnauthorizedUpdater();
    error InvalidTier();
    error UpdateTooFrequent();

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
        if (msg.sender != updater) revert UnauthorizedUpdater();
        _;
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

        // Increment trade count (we can use sealed computation)
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
    // Admin Functions
    // ============================================

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
        PoolState storage state = pools[poolId];
        delete state.encVolume;
        delete state.encPriceChange;
        delete state.encTradeCount;
        state.velocityTier = 0;
        state.lastUpdate = uint64(block.timestamp);
        state.lastIngestion = 0;
    }
}
