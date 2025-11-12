pragma solidity ^0.8.19;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IRiskMetrics.sol";
import "../libraries/Constants.sol";
import "../libraries/MathLib.sol"; // FIXED: Import MathLib
import "../libraries/MathUtils.sol";
import "../oracles/MultiSourceOracle.sol";

contract RiskMetrics is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    IRiskMetrics
{
    MultiSourceOracle public multiOracle;
    mapping(address => uint256[]) public priceHistory;
    mapping(address => uint256) public lastUpdate;
    uint256 public maxHistoryLength;

    function initialize(
        address _multiOracle,
        uint256 _maxHistoryLength
    ) public initializer {
        __Ownable_init(msg.sender);

        multiOracle = MultiSourceOracle(_multiOracle);
        maxHistoryLength = _maxHistoryLength;
    }

    function getPrice(
        address asset
    ) external override returns (uint256 price, uint256 confidence) {
        MultiSourceOracle.PriceData memory priceData = multiOracle.getPrice(
            asset
        );
        return (priceData.price, priceData.confidence);
    }

    function getVolatility(
        address asset,
        uint256 lookback
    ) external view override returns (uint256 volatility) {
        uint256[] storage history = priceHistory[asset];
        if (history.length < 2) return 0;

        uint256 sumSquared = 0;
        uint256 count = 0;
        uint256 actualLookback = MathUtils.min(lookback, history.length - 1);

        for (uint256 i = 1; i <= actualLookback; i++) {
            uint256 prev = history[history.length - i - 1];
            uint256 curr = history[history.length - i];

            if (prev > 0) {
                // FIXED: Use MathLib.ln() instead of method call
                int256 logReturn = MathLib.ln(
                    (curr * MathLib.PRECISION) / prev
                );
                sumSquared +=
                    uint256(logReturn * logReturn) /
                    MathLib.PRECISION;
                count++;
            }
        }

        if (count == 0) return 0;

        uint256 variance = sumSquared / count;
        // FIXED: Use MathLib.sqrt() instead of method call
        volatility =
            (MathLib.sqrt(variance) * MathLib.sqrt(365 * MathLib.PRECISION)) /
            MathLib.PRECISION;
    }

    function getRiskScore() external view override returns (uint256 riskScore) {
        uint256 volatility = this.getVolatility(
            address(0),
            7 * Constants.SECONDS_PER_DAY
        );
        riskScore = (volatility / Constants.PRICE_DECIMALS) + 5000 + 3000;
    }

    function pushFeedResponse(bytes calldata payload) external override {
        // Decode payload and update price history
        (address asset, uint256 price, uint256 timestamp) = abi.decode(
            payload,
            (address, uint256, uint256)
        );

        require(timestamp <= block.timestamp, "Future timestamp");
        require(price > 0, "Invalid price");

        _addPriceToHistory(asset, price);
        lastUpdate[asset] = timestamp;
    }

    function _addPriceToHistory(address asset, uint256 price) internal {
        priceHistory[asset].push(price);

        if (priceHistory[asset].length > maxHistoryLength) {
            // Remove oldest price
            for (uint256 i = 0; i < priceHistory[asset].length - 1; i++) {
                priceHistory[asset][i] = priceHistory[asset][i + 1];
            }
            priceHistory[asset].pop();
        }

        emit PriceUpdated(asset, price, 10000);
    }

    function getPriceHistory(address asset) external view returns (uint256[] memory) {
        return priceHistory[asset];
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
