# Fhenix Velocity Fee Hook

A Uniswap v4 hook that implements dynamic fees based on velocity metrics computed on-chain with EMA smoothing. The architecture supports Fhenix's CoFHE (Confidential on-chain Fully Homomorphic Encryption) for optional encrypted data ingestion.

## Overview

This project combines Uniswap v4's dynamic fee mechanism with real-time velocity calculation to create responsive fees that adapt to market conditions. The oracle computes velocity scores on-chain using exponential moving averages (EMA), with optional support for privacy-preserving encrypted data via Fhenix FHE.

### Architecture

```
┌─────────────────────────────────────┐
│  Swap Initiated                     │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  FhenixVelocityFeeHook              │
│  • beforeSwap: Read velocity tier   │
│  • Map tier → dynamic LP fee        │
│  • Apply fee to swap                │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  Swap Executes                      │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  FhenixVelocityFeeHook              │
│  • afterSwap: Get post-swap state   │
│  • Send data to oracle              │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  VelocityOracleCoFHE                │
│  • Calculate velocity signal        │
│    - Price: |ΔP|/P (volatility)     │
│    - Flow: |amount|/L (volume)      │
│  • Update EMA (α decay)             │
│  • Map EMA → fee → tier (0-10)      │
│  • Optional: Store encrypted data   │
└─────────────────────────────────────┘
```

### Key Components

1. **VelocityOracleCoFHE** (`src/VelocityOracleCoFHE.sol`)
   - **On-chain velocity calculation** with EMA smoothing
   - Two velocity modes:
     - **Price velocity**: `|ΔP|/P` (captures volatility/price impact)
     - **Flow velocity**: `|amount|/L` (captures trade size relative to depth)
   - Configurable parameters per pool (tau, target, k, min/max fees)
   - Automatic tier calculation (0-10) from velocity signals
   - **Optional**: Stores encrypted trading metrics using Fhenix FHE for privacy

2. **FhenixVelocityFeeHook** (`src/FhenixVelocityFeeHook.sol`)
   - Uniswap v4 hook with `beforeSwap` and `afterSwap` enabled
   - **beforeSwap**: Reads velocity tier and applies dynamic fee
   - **afterSwap**: Updates oracle with post-swap price and liquidity
   - Maps tier to dynamic LP fee (500-10000 bps / 0.05%-1.0%)
   - Synchronous and deterministic

3. **Velocity Calculation** (On-chain)
   - **EMA update**: `ema_new = α × x + (1-α) × ema_old`
   - **Alpha (decay)**: `α = dt/τ` (linear approximation)
   - **Fee mapping**: `fee = base + k × (ema/target)`
   - **Tier mapping**: Linear map from fee to tier (0-10)

## Fee Curve

| Velocity Tier | LP Fee (bps) | LP Fee (%) | Market Condition |
|---------------|--------------|------------|------------------|
| 0             | 500          | 0.05%      | Calm             |
| 1             | 750          | 0.075%     | Low              |
| 2             | 1000         | 0.1%       | Moderate         |
| 3             | 1500         | 0.15%      | Elevated         |
| 4             | 2000         | 0.2%       | Active           |
| 5             | 3000         | 0.3%       | High             |
| 6             | 4000         | 0.4%       | Very High        |
| 7             | 5000         | 0.5%       | Volatile         |
| 8             | 6500         | 0.65%      | Extreme          |
| 9             | 8000         | 0.8%       | Critical         |
| 10            | 10000        | 1.0%       | Maximum          |

## Installation

```bash
# Clone the repository
git clone <your-repo>
cd encrypted_velocity_fee_hook

# Install dependencies
forge install

# Build contracts
forge build
```

## Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/FhenixVelocityFeeHook.t.sol

# Gas report
forge test --gas-report
```

## Deployment

### Prerequisites

- Deployed Uniswap v4 PoolManager
- Fhenix network access (for FHE operations)
- Owner and updater addresses configured

### Environment Variables

Create a `.env` file:

```env
# Required
POOL_MANAGER=0x... # Uniswap v4 PoolManager address
PRIVATE_KEY=0x...  # Deployer private key
RPC_URL=<fhenix-rpc-url>

# Optional
OWNER=0x...        # Oracle owner (defaults to deployer)
UPDATER=0x...      # CoFHE worker address (defaults to deployer)
TOKEN0=0x...       # First pool token
TOKEN1=0x...       # Second pool token
```

### Deploy

```bash
# Load environment variables
source .env

# Deploy contracts
forge script script/Deploy.s.sol:DeployFhenixVelocityHook \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify
```

### Post-Deployment

1. **Verify Contracts** on block explorer
2. **Initialize Pool** with dynamic fees enabled (`LPFeeLibrary.DYNAMIC_FEE_FLAG`)
3. **Configure CoFHE Worker** to:
   - Watch `DataIngested` events
   - Compute velocity scores using FHE
   - Call `setVelocityTier()` with results
4. **Start Ingesting Data** via `ingestTradeData()` or `ingestVolume()`

## Usage

### For Integrators

```solidity
// Initialize pool with dynamic fees
poolManager.initialize(
    poolKey,
    sqrtPriceX96,
    hookData
);

// Swaps automatically use velocity-based fees
swapRouter.swap(poolKey, params, testSettings, hookData);
```

### For CoFHE Workers

```typescript
// Listen for data ingestion events
oracle.on('DataIngested', async (poolId, timestamp) => {
  // Fetch encrypted state
  const encryptedData = await oracle.pools(poolId);

  // Perform FHE computation off-chain
  const velocityTier = await computeVelocityTierFHE(encryptedData);

  // Update oracle
  await oracle.setVelocityTier(poolId, velocityTier);
});
```

### For Data Providers

```solidity
// Encrypt trading data client-side
bytes memory encVolume = fhenixClient.encrypt(volumeDelta, publicKey);
bytes memory encPriceChange = fhenixClient.encrypt(priceChangeDelta, publicKey);

// Ingest into oracle
oracle.ingestTradeData(poolId, encVolume, encPriceChange);
```

## Security Considerations

### Privacy Model

- **Private**: Volume, price changes, trade counts (stored as FHE ciphertexts)
- **Public**: Velocity tier (0-10), bounded scalar
- **Threat Model**: Oracle sees encrypted data only; tier reveals bounded market activity

### Access Control

- **Owner**: Can change updater, reset pool state
- **Updater**: Can set velocity tiers (should be CoFHE worker/committee)
- **Anyone**: Can ingest encrypted data

### Rate Limiting

- Tier updates limited to 1 per minute per pool
- Prevents spam and manipulation

### Invariants

1. Hook is pure and deterministic
2. All FHE computation happens off-chain
3. Velocity tier ∈ [0, 10]
4. LP fee ∈ [500, 10000] bps

## Development

### Project Structure

```
encrypted_velocity_fee_hook/
├── src/
│   ├── VelocityOracleCoFHE.sol      # CoFHE oracle contract
│   └── FhenixVelocityFeeHook.sol    # Uniswap v4 hook
├── test/
│   ├── VelocityOracleCoFHE.t.sol    # Oracle tests
│   └── FhenixVelocityFeeHook.t.sol  # Hook tests
├── script/
│   └── Deploy.s.sol                 # Deployment script
├── lib/                              # Dependencies
│   ├── v4-core/                     # Uniswap v4 core
│   ├── v4-periphery/                # Uniswap v4 periphery
│   └── fhenix-contracts/            # Fhenix FHE contracts
└── foundry.toml                     # Foundry config
```

### Adding Custom Fee Curves

Modify `_initializeDefaultFees()` in `FhenixVelocityFeeHook.sol`:

```solidity
function _initializeDefaultFees() private {
    tierToFee[0] = 100;   // 0.01% - ultra low
    tierToFee[5] = 2500;  // 0.25% - medium
    tierToFee[10] = 5000; // 0.5% - high (custom cap)
}
```

### Implementing Custom Velocity Metrics

In your CoFHE worker, implement custom FHE computations:

```typescript
async function computeVelocityTierFHE(encryptedState) {
  // Example: EMA-based volatility
  const ema = await fhe.computeEMA(encryptedState.encPriceChange);
  const volatility = await fhe.computeStdDev(ema);

  // Map to tier (0-10)
  return mapVolatilityToTier(volatility);
}
```

## Resources

- [Uniswap v4 Documentation](https://docs.uniswap.org/contracts/v4/overview)
- [Fhenix CoFHE Documentation](https://docs.fhenix.zone/)
- [Foundry Book](https://book.getfoundry.sh/)

## License

MIT

## Disclaimer

This is experimental software. Use at your own risk. Not audited.
