pragma solidity ^0.8.19;
interface IRiskMetrics {
    struct PriceData {
        uint256 price;
        uint256 timestamp;
        uint256 confidence;
    }
    function getPrice(
        address asset
    ) external returns (uint256 price, uint256 confidence);
    function getVolatility(
        address asset,
        uint256 lookback
    ) external view returns (uint256 volatility);
    function getRiskScore() external view returns (uint256 riskScore);
    function getPriceHistory(address asset) external view returns (uint256[] memory);
    function pushFeedResponse(bytes calldata payload) external;
    event PriceUpdated(address asset, uint256 price, uint256 confidence);
}
