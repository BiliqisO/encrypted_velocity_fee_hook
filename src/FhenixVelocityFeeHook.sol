// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/**
 * @title IVelocityOracle
 * @notice Interface for the CoFHE-powered velocity oracle
 */
interface IVelocityOracle {
    function getVelocityTier(PoolId id) external view returns (uint16);
    function updateVelocity(
        PoolId poolId,
        uint160 newSqrtPriceX96,
        int256 amountSpecified,
        uint128 liquidity
    ) external;
}

/**
 * @title FhenixVelocityFeeHook
 * @notice Uniswap v4 hook that implements dynamic fees based on encrypted velocity metrics from Fhenix
 * @dev Reads velocity tier from VelocityOracleCoFHE and adjusts LP fees accordingly
 *
 * Architecture:
 * - CoFHE Oracle handles encrypted trade data and computes velocity scores off-chain
 * - This hook reads the public velocity tier and maps it to dynamic fees
 * - All privacy-preserving computation happens in the oracle layer
 * - Hook remains pure, synchronous, and deterministic
 */
contract FhenixVelocityFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // ============================================
    // State Variables
    // ============================================

    /// @notice CoFHE velocity oracle contract
    IVelocityOracle public immutable ORACLE;

    /// @notice Fee mapping: velocity tier => LP fee in basis points
    /// @dev tier 0 = calm, tier 10 = extreme velocity
    mapping(uint16 => uint24) public tierToFee;

    /// @notice Default base fee when velocity tier is 0
    uint24 public constant BASE_FEE = 500; // 5 bps = 0.05%

    /// @notice Maximum fee cap
    uint24 public constant MAX_FEE = 10000; // 100 bps = 1%

    /// @notice Flag indicating dynamic fees are enabled
    uint24 public constant DYNAMIC_FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG;

    // ============================================
    // Events
    // ============================================

    event VelocityFeeApplied(
        PoolId indexed poolId,
        uint16 velocityTier,
        uint24 feeBps,
        uint256 timestamp
    );

    event FeeConfigUpdated(uint16 indexed tier, uint24 oldFee, uint24 newFee);

    // ============================================
    // Errors
    // ============================================

    error InvalidFee();
    error InvalidTier();

    // ============================================
    // Constructor
    // ============================================

    /**
     * @notice Initializes the hook with pool manager and oracle
     * @param _poolManager Uniswap v4 PoolManager address
     * @param _oracle VelocityOracleCoFHE address
     */
    constructor(IPoolManager _poolManager, IVelocityOracle _oracle) BaseHook(_poolManager) {
        ORACLE = _oracle;
        _initializeDefaultFees();
    }

    /**
     * @notice Sets up default fee tiers
     * @dev Maps velocity tiers (0-10) to fees in basis points
     */
    function _initializeDefaultFees() private {
        // Conservative fee curve: exponential-ish growth
        tierToFee[0] = 500;   // 0.05% - calm market
        tierToFee[1] = 750;   // 0.075%
        tierToFee[2] = 1000;  // 0.1%
        tierToFee[3] = 1500;  // 0.15%
        tierToFee[4] = 2000;  // 0.2%
        tierToFee[5] = 3000;  // 0.3%
        tierToFee[6] = 4000;  // 0.4%
        tierToFee[7] = 5000;  // 0.5%
        tierToFee[8] = 6500;  // 0.65%
        tierToFee[9] = 8000;  // 0.8%
        tierToFee[10] = 10000; // 1.0% - extreme velocity
    }

    // ============================================
    // Hook Permissions
    // ============================================

    /**
     * @notice Defines which hook callbacks are implemented
     * @return Hooks.Permissions struct with beforeSwap and afterSwap enabled
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,        //  Read velocity tier, set fee
            afterSwap: true,         //  Update velocity EMA
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============================================
    // Core Hook Logic
    // ============================================

    /**
     * @notice Called before each swap to set dynamic fee based on velocity
     * @dev Reads velocity tier from oracle and updates pool fee accordingly
     * @param sender The address initiating the swap
     * @param key The pool key
     * @param params Swap parameters
     * @param hookData Additional hook data
     * @return selector The function selector to indicate successful execution
     * @return delta BeforeSwapDelta (not used, returns zero)
     * @return lpFeeOverride The dynamic LP fee to apply
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    )
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Get pool ID
        PoolId poolId = key.toId();

        // Fetch velocity tier from CoFHE oracle 
        uint16 velocityTier = ORACLE.getVelocityTier(poolId);

        // Map tier to fee (with safety bounds)
        uint24 dynamicFee = _calculateFee(velocityTier);

        // Emit event for monitoring
        emit VelocityFeeApplied(poolId, velocityTier, dynamicFee, block.timestamp);

        // Return: selector, no delta, fee override with DYNAMIC flag
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            dynamicFee | DYNAMIC_FEE_FLAG
        );
    }

    /**
     * @notice Called after each swap to update velocity metrics
     * @dev Updates the oracle's EMA with swap data
     * @param sender The address initiating the swap
     * @param key The pool key
     * @param params Swap parameters
     * @param delta Balance changes from the swap
     * @param hookData Additional hook data
     * @return selector The function selector
     * @return hookDelta Hook's balance delta (zero)
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    )
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

 
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        // Update velocity oracle with post-swap data
        ORACLE.updateVelocity(
            poolId,
            sqrtPriceX96,
            params.amountSpecified,
            liquidity
        );

        return (this.afterSwap.selector, 0);
    }

    // ============================================
    // Internal Functions
    // ============================================

    /**
     * @notice Calculates LP fee from velocity tier
     * @param tier Velocity tier (0-10)
     * @return fee LP fee in basis points
     */
    function _calculateFee(uint16 tier) internal view returns (uint24 fee) {
        // Clamp tier to valid range
        if (tier > 10) tier = 10;

        // Lookup configured fee
        fee = tierToFee[tier];

        // Safety: ensure fee doesn't exceed max
        if (fee > MAX_FEE) fee = MAX_FEE;

        // Ensure minimum fee
        if (fee == 0) fee = BASE_FEE;

        return fee;
    }

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Get the current fee for a pool based on its velocity tier
     * @param key Pool key
     * @return velocityTier Current tier from oracle
     * @return fee Corresponding LP fee in bps
     */
    function getCurrentFee(PoolKey calldata key)
        external
        view
        returns (uint16 velocityTier, uint24 fee)
    {
        PoolId poolId = key.toId();
        velocityTier = ORACLE.getVelocityTier(poolId);
        fee = _calculateFee(velocityTier);
    }

    /**
     * @notice Preview what fee would be applied for a given tier
     * @param tier Velocity tier to check
     * @return fee LP fee in basis points
     */
    function previewFeeForTier(uint16 tier) external view returns (uint24 fee) {
        return _calculateFee(tier);
    }
}
