pragma solidity ^0.8.19;

struct RiskParams {
    uint256 baseRate;
    uint256 riskMultiplier;
    uint256 hysteresisBand;
    uint256 emaAlpha;
}

struct PoolConfig {
    uint256 maxExposurePercent;
    uint256 withdrawCooldown;
    uint256 maxWithdrawPercentPerEpoch;
    uint256 juniorThreshold;
}

struct PurchaseConfig {
    uint256 maxSlippageBps;
    uint256 chunkSizePercent;
    uint256 purchaseTimeout;
}

struct HoldingConfig {
    uint256 recoveryThreshold;
    uint256 maxHoldDuration;
    uint256 trailingStop;
    uint256 sellChunkSize;
}

struct SwapParams {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
    uint24 feeTier;
}
