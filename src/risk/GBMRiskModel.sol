pragma solidity ^0.8.19;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../libraries/MathUtils.sol";
import "../libraries/MathLib.sol";

contract GBMRiskModel is OwnableUpgradeable {
    struct GBMParameters {
        uint256 mu;
        uint256 sigma;
        uint256 S0;
        uint256 T;
        uint256 dt;
    }

    struct MonteCarloResult {
        uint256 meanPrice;
        uint256 volatility;
        uint256 var95;
        uint256 var99;
        uint256 expectedShortfall95;
        uint256 confidence;
    }

    uint256 public constant BPS = 1e4;
    uint256 public constant PRECISION = 1e18;

    mapping(address => uint256[]) public priceHistory;
    mapping(address => uint256) public lastUpdate;
    uint256 public maxHistoryLength;

    function initialize(uint256 _maxHistoryLength) public initializer {
        __Ownable_init(msg.sender);
        maxHistoryLength = _maxHistoryLength;
    }

    function addPriceData(
        address asset,
        uint256[] memory prices
    ) external onlyOwner {
        for (uint256 i = 0; i < prices.length; i++) {
            _addPrice(asset, prices[i]);
        }
        lastUpdate[asset] = block.timestamp;
    }

    function simulateGBM(
        address asset,
        uint256 timeHorizon,
        uint256 numSimulations,
        uint256 confidenceLevel
    ) external view returns (MonteCarloResult memory) {
        require(priceHistory[asset].length >= 2, "Insufficient data");
        require(confidenceLevel <= 9999, "Confidence too high");

        GBMParameters memory params = _estimateGBMParameters(
            asset,
            timeHorizon
        );

        uint256[] memory finalPrices = new uint256[](numSimulations);
        for (uint256 i = 0; i < numSimulations; i++) {
            finalPrices[i] = _simulateGBMPath(params, i);
        }

        return
            _analyzeSimulationResults(finalPrices, params.S0, confidenceLevel);
    }

    function calculateValueAtRisk(
        address asset,
        uint256 positionSize,
        uint256 timeHorizon,
        uint256 confidenceLevel
    ) external view returns (uint256 varAmount, uint256 expectedShortfall) {
        MonteCarloResult memory result = this.simulateGBM(
            asset,
            timeHorizon,
            50, // Reduced for gas limits
            confidenceLevel
        );

        uint256 lossPercent = (PRECISION -
            (result.var95 * PRECISION) /
            result.meanPrice);
        varAmount = (positionSize * lossPercent) / PRECISION;

        lossPercent = (PRECISION -
            (result.expectedShortfall95 * PRECISION) /
            result.meanPrice);
        expectedShortfall = (positionSize * lossPercent) / PRECISION;
    }

    function _estimateGBMParameters(
        address asset,
        uint256 timeHorizon
    ) internal view returns (GBMParameters memory) {
        uint256[] memory prices = priceHistory[asset];
        uint256 n = prices.length;
        require(n >= 2, "Need at least 2 prices");

        int256 sumReturns = 0;
        uint256 sumSquared = 0;
        uint256 validReturns = 0;

        for (uint256 i = 1; i < n; i++) {
            uint256 prev = prices[i - 1];
            uint256 curr = prices[i];

            if (prev > 0) {
                // FIXED: Use MathLib.ln()
                int256 logReturn = MathLib.ln((curr * PRECISION) / prev);
                sumReturns += logReturn;
                sumSquared += uint256(logReturn * logReturn) / PRECISION;
                validReturns++;
            }
        }

        require(validReturns > 0, "No valid returns");

        int256 meanReturn = sumReturns / int256(validReturns);
        uint256 meanReturnSquared = uint256(meanReturn * meanReturn) /
            PRECISION;
        uint256 variance = (sumSquared / validReturns) > meanReturnSquared
            ? (sumSquared / validReturns) - meanReturnSquared
            : 0;

        // FIXED: Use MathLib.sqrt()
        uint256 volatility = MathLib.sqrt(variance * 365);

        return
            GBMParameters({
                mu: uint256(meanReturn > 0 ? meanReturn : -meanReturn) * 365,
                sigma: volatility,
                S0: prices[n - 1],
                T: (timeHorizon * PRECISION) / 365,
                dt: PRECISION / 365
            });
    }

    function _simulateGBMPath(
        GBMParameters memory params,
        uint256 seed
    ) internal view returns (uint256) {
        uint256 currentPrice = params.S0;
        uint256 steps = (params.T * PRECISION) / params.dt;

        // Limit steps to prevent gas issues
        if (steps > 100) steps = 100;

        for (uint256 t = 0; t < steps; t++) {
            uint256 random = uint256(
                keccak256(
                    abi.encodePacked(blockhash(block.number - 1), seed, t)
                )
            );

            // FIXED: Use MathLib.boxMuller()
            int256 normal = MathLib.boxMuller(random);

            // Drift term
            int256 drift = int256((params.mu * params.dt) / PRECISION);

            // Diffusion term: sigma * sqrt(dt) * Z
            uint256 sqrtDt = MathLib.sqrt(params.dt);
            int256 diffusion = (int256(params.sigma) *
                normal *
                int256(sqrtDt)) / int256(PRECISION * PRECISION);

            int256 change = drift + diffusion;

            // FIXED: Use MathLib.exp()
            uint256 expChange = MathLib.exp(change);
            currentPrice = (currentPrice * expChange) / PRECISION;
        }

        return currentPrice;
    }

    function _analyzeSimulationResults(
        uint256[] memory finalPrices,
        uint256 initialPrice,
        uint256 confidenceLevel
    ) internal pure returns (MonteCarloResult memory) {
        uint256 n = finalPrices.length;
        uint256 sum = 0;
        uint256 sumSquared = 0;

        for (uint256 i = 0; i < n; i++) {
            sum += finalPrices[i];
            sumSquared += (finalPrices[i] * finalPrices[i]) / PRECISION;
        }

        uint256 mean = sum / n;
        uint256 meanSquared = (mean * mean) / PRECISION;
        uint256 variance = (sumSquared / n) > meanSquared
            ? (sumSquared / n) - meanSquared
            : 0;

        // FIXED: Use MathLib.sqrt()
        uint256 stdDev = MathLib.sqrt(variance);

        // Sort prices for VaR calculation - FIXED: Use MathLib.bubbleSort()
        MathLib.bubbleSort(finalPrices);

        uint256 varIndex = (n * (10000 - confidenceLevel)) / 10000;
        if (varIndex >= n) varIndex = n - 1;

        uint256 var95 = finalPrices[varIndex];

        uint256 esSum = 0;
        for (uint256 i = 0; i <= varIndex; i++) {
            esSum += finalPrices[i];
        }
        uint256 expectedShortfall = varIndex > 0 ? esSum / (varIndex + 1) : 0;

        return
            MonteCarloResult({
                meanPrice: mean,
                volatility: (stdDev * BPS) / initialPrice,
                var95: var95,
                var99: finalPrices[(n * 1) / 100],
                expectedShortfall95: expectedShortfall,
                confidence: confidenceLevel
            });
    }

    function _addPrice(address asset, uint256 price) internal {
        priceHistory[asset].push(price);

        if (priceHistory[asset].length > maxHistoryLength) {
            // Remove oldest
            for (uint256 i = 0; i < priceHistory[asset].length - 1; i++) {
                priceHistory[asset][i] = priceHistory[asset][i + 1];
            }
            priceHistory[asset].pop();
        }
    }
}
