pragma solidity ^0.8.19;
import "../libraries/Constants.sol";
library MathUtils {
    function calculateEMA(
        uint256 current,
        uint256 previous,
        uint256 alpha
    ) internal pure returns (uint256) {
        return
            (alpha * current +
                (Constants.BPS_DENOMINATOR - alpha) * previous) /
                    Constants.BPS_DENOMINATOR;
    }
    function calculatePremium(
        uint256 baseRate,
        uint256 riskMultiplier,
        uint256 volatility
    ) internal pure returns (uint256) {
        return
            baseRate +
                riskMultiplier * volatility / Constants.BPS_DENOMINATOR;
    }
    function calculateCapitalAdequacy(
        uint256 liquidationFraction,
        uint256 outstandingDebt,
        uint256 averageDiscount,
        uint256 tailCushion,
        uint256 currentCapital
    ) internal pure returns (uint256) {
        return
            (
                liquidationFraction * outstandingDebt *
                    (Constants.BPS_DENOMINATOR - averageDiscount)
            ) / (Constants.BPS_DENOMINATOR * Constants.BPS_DENOMINATOR) +
            tailCushion * currentCapital / Constants.BPS_DENOMINATOR;
    }
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
