pragma solidity ^0.8.19;
interface IPremiumAdjustment {
    function updatePremiums() external;
    function getCurrentPremiumBps() external view returns (uint256);
    function computeRiskScore() external returns (uint256);
    function overridePremium(uint256 newRate) external;
    event PremiumUpdated(uint256 newRate, uint256 riskScore);
    event PremiumOverridden(uint256 newRate, address governance);
}
