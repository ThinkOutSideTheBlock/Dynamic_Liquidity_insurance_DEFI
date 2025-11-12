pragma solidity ^0.8.19;

import "./IInsurancePool.sol";

interface IHoldingProfitDistribution {
    struct CollateralLock {
        address asset;
        uint256 amount;
        uint256 entryPrice;
        uint256 timestamp;
        uint256 peakPrice;
        bool active;
        uint256 id;
    }
    function lockCollateral(
        address asset,
        uint256 amount,
        uint256 entryPrice
    ) external returns (uint256);
    function evaluateAndSell(uint256 lockId) external;
    function claim(uint256 shares, IInsurancePool.Tranche tranche) external;
    function previewSell(
        uint256 lockId
    ) external returns (uint256 estimatedProfit);
    event CollateralLocked(
        uint256 lockId,
        address asset,
        uint256 amount,
        uint256 entryPrice
    );
    event CollateralSold(uint256 lockId, uint256 profit, uint256 salePrice);
    event ProfitDistributed(IInsurancePool.Tranche tranche, uint256 amount);
}
