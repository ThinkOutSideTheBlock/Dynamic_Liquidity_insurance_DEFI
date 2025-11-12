// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../libraries/Constants.sol";
import "../libraries/MathUtils.sol";
import "../interfaces/IInsurancePool.sol";
import "../interfaces/IRiskMetrics.sol";
import "../risk/GBMRiskModel.sol";

/**
 * @title CapitalAdequacyMonitor
 * @notice Monitors and enforces capital adequacy requirements for the insurance pool
 * @dev Uses Basel-style VaR methodology with configurable confidence levels
 */
contract CapitalAdequacyMonitor is OwnableUpgradeable, UUPSUpgradeable {
    IInsurancePool public insurancePool;
    IRiskMetrics public riskMetrics;
    GBMRiskModel public gbmRiskModel;

    // Capital adequacy parameters (in bps)
    uint256 public targetCapitalRatio; // e.g., 12000 = 120%
    uint256 public minimumCapitalRatio; // e.g., 10000 = 100%
    uint256 public tailCushionBps; // Additional buffer, e.g., 500 = 5%
    uint256 public pauseThresholdBps; // Circuit breaker trigger

    // Historical liquidation data for calibration
    uint256 public totalLiquidationEvents;
    uint256 public totalLiquidationVolume;
    uint256 public averageDiscountBps; // Average discount obtained on liquidations
    uint256 public maxObservedLoss;

    bool public circuitBreakerActive;
    uint256 public lastCapitalCheck;
    uint256 public checkInterval; // Minimum time between checks
    uint256 public lastRecordTime;
    uint256 public constant MIN_RECORD_INTERVAL = 1 hours;

    event CapitalAdequacyChecked(
        uint256 requiredCapital,
        uint256 availableCapital,
        uint256 ratio,
        bool adequate
    );
    event CircuitBreakerTriggered(uint256 currentRatio, uint256 minimumRatio);
    event CircuitBreakerReset(uint256 currentRatio);
    event CapitalDeficit(uint256 shortfall, uint256 reinsuranceNeeded);
    event LiquidationRecorded(
        uint256 eventId,
        uint256 debtAmount,
        uint256 profit
    );

    function initialize(
        address _insurancePool,
        address _riskMetrics,
        address _gbmRiskModel,
        uint256 _targetCapitalRatio,
        uint256 _minimumCapitalRatio,
        uint256 _tailCushionBps,
        uint256 _pauseThresholdBps
    ) public initializer {
        __Ownable_init(msg.sender);
        //

        insurancePool = IInsurancePool(_insurancePool);
        riskMetrics = IRiskMetrics(_riskMetrics);
        gbmRiskModel = GBMRiskModel(_gbmRiskModel);

        targetCapitalRatio = _targetCapitalRatio;
        minimumCapitalRatio = _minimumCapitalRatio;
        tailCushionBps = _tailCushionBps;
        pauseThresholdBps = _pauseThresholdBps;

        // Initialize with conservative defaults
        averageDiscountBps = 1500; // 15% average discount
        totalLiquidationEvents = 0;
        totalLiquidationVolume = 0;
        checkInterval = 1 hours;
    }

    /**
     * @dev Calculate required capital based on current exposures
     * Formula: C = p × D × (1 - d) + α × C
     * Where:
     * - p = liquidation probability (from historical frequency)
     * - D = outstanding debt exposure (reserved funds)
     * - d = average discount obtained
     * - α = tail cushion for extreme events
     * - C = current capital
     */
    function calculateRequiredCapital(
        address stablecoin
    ) public view returns (uint256 requiredCapital) {
        // Get current pool metrics
        uint256 totalPoolValue = insurancePool.totalPool(stablecoin);
        uint256 reservedFunds = insurancePool.reservedFunds(stablecoin);
        uint256 availableCapital = totalPoolValue > reservedFunds
            ? totalPoolValue - reservedFunds
            : 0;

        // Calculate liquidation probability from historical data
        uint256 liquidationProbabilityBps = _calculateLiquidationProbability();

        // Estimate outstanding debt exposure
        uint256 debtExposure = reservedFunds;

        // Required capital for expected losses using MathUtils formula
        uint256 expectedLossCapital = MathUtils.calculateCapitalAdequacy(
            liquidationProbabilityBps,
            debtExposure,
            averageDiscountBps,
            tailCushionBps,
            availableCapital
        );

        // Add VaR-based tail risk capital
        uint256 tailRiskCapital = _calculateTailRiskCapital(
            stablecoin,
            debtExposure
        );

        requiredCapital = expectedLossCapital + tailRiskCapital;

        // Ensure minimum capital requirement
        uint256 minCapital = (totalPoolValue * minimumCapitalRatio) /
            Constants.BPS_DENOMINATOR;
        if (requiredCapital < minCapital) {
            requiredCapital = minCapital;
        }
    }

    /**
     * @dev Check if pool has adequate capital and trigger actions if not
     * This should be called before allowing new liquidation purchases
     */
    function checkCapitalAdequacy(
        address stablecoin
    ) external returns (bool adequate) {
        require(
            block.timestamp >= lastCapitalCheck + checkInterval,
            "Check too frequent"
        );

        uint256 requiredCapital = calculateRequiredCapital(stablecoin);
        uint256 availableCapital = insurancePool.totalPool(stablecoin) -
            insurancePool.reservedFunds(stablecoin);

        uint256 capitalRatio = requiredCapital > 0
            ? (availableCapital * Constants.BPS_DENOMINATOR) / requiredCapital
            : Constants.BPS_DENOMINATOR;

        adequate = capitalRatio >= minimumCapitalRatio;

        emit CapitalAdequacyChecked(
            requiredCapital,
            availableCapital,
            capitalRatio,
            adequate
        );

        lastCapitalCheck = block.timestamp;

        // Trigger circuit breaker if capital falls below pause threshold
        if (capitalRatio < pauseThresholdBps && !circuitBreakerActive) {
            _triggerCircuitBreaker(capitalRatio);
        } else if (capitalRatio >= targetCapitalRatio && circuitBreakerActive) {
            _resetCircuitBreaker(capitalRatio);
        }

        // Calculate reinsurance need if capital is insufficient
        if (!adequate && requiredCapital > availableCapital) {
            uint256 shortfall = requiredCapital - availableCapital;
            emit CapitalDeficit(shortfall, shortfall);

            // Automatically trigger reinsurance if deficit exceeds junior buffer
            uint256 juniorBuffer = _getJuniorBufferValue(stablecoin);
            if (shortfall > juniorBuffer) {
                insurancePool.triggerReinsurance(shortfall);
            }
        }

        return adequate;
    }

    /**
     * @dev Check capital adequacy before liquidation (view function for pre-check)
     */
    function canExecuteLiquidation(
        address stablecoin,
        uint256 liquidationAmount
    ) external view returns (bool canExecute, string memory reason) {
        uint256 requiredCapital = calculateRequiredCapital(stablecoin);
        uint256 availableCapital = insurancePool.totalPool(stablecoin) -
            insurancePool.reservedFunds(stablecoin);

        // Check if liquidation would breach capital requirements
        uint256 newReserved = insurancePool.reservedFunds(stablecoin) +
            liquidationAmount;
        uint256 newAvailable = availableCapital > liquidationAmount
            ? availableCapital - liquidationAmount
            : 0;

        if (circuitBreakerActive) {
            return (false, "Circuit breaker active");
        }

        if (newAvailable < requiredCapital) {
            return (false, "Would breach capital requirements");
        }

        uint256 newRatio = (newAvailable * Constants.BPS_DENOMINATOR) /
            requiredCapital;
        if (newRatio < minimumCapitalRatio) {
            return (false, "Insufficient capital ratio");
        }

        return (true, "");
    }

    /**
     * @dev Update liquidation statistics after each event
     */
    function recordLiquidationEvent(
        uint256 debtAmount,
        uint256 collateralValue,
        uint256 profit
    ) external onlyOwner {
        require(
            block.timestamp >= lastRecordTime + MIN_RECORD_INTERVAL,
            "Too frequent"
        );
        
        totalLiquidationEvents++;
        totalLiquidationVolume += debtAmount;

        // Update average discount using exponential moving average
        if (collateralValue > debtAmount) {
            uint256 discountBps = ((collateralValue - debtAmount) *
                Constants.BPS_DENOMINATOR) / collateralValue;
            
            // Add bounds check
            require(discountBps <= 5000, "Discount too high"); // Max 50%
            
            // EMA with alpha=0.1 (weight of 10% to new value)
            averageDiscountBps = (averageDiscountBps * 9 + discountBps) / 10;
        }

        // Track maximum observed loss for tail risk calibration
        if (profit == 0 && debtAmount > maxObservedLoss) {
            maxObservedLoss = debtAmount;
        }

        lastRecordTime = block.timestamp;
        emit LiquidationRecorded(totalLiquidationEvents, debtAmount, profit);
    }

    /**
     * @dev Calculate liquidation probability from historical frequency
     * Uses simplified Poisson model: λ = events / time
     */
    function _calculateLiquidationProbability()
        internal
        view
        returns (uint256)
    {
        if (totalLiquidationEvents == 0) {
            return 1000; // 10% default for new contracts
        }

        // Calculate events per year (annualized rate)
        // For simplicity, assume 1 event per month = 12% annual probability
        uint256 annualizedEvents = totalLiquidationEvents * 12; // Simplified

        // Convert to bps: probability = min(events * 100, 5000) bps
        uint256 probabilityBps = annualizedEvents * 100;

        // Cap at 50% (5000 bps) for extreme scenarios
        return probabilityBps > 5000 ? 5000 : probabilityBps;
    }

    /**
     * @dev Calculate tail risk capital using simplified VaR
     * In production, this would use full Monte Carlo from GBMRiskModel
     */
    function _calculateTailRiskCapital(
        address stablecoin,
        uint256 exposure
    ) internal view returns (uint256) {
        // Use GBMRiskModel for proper Monte Carlo VaR
        (uint256 var99, uint256 expectedShortfall) = gbmRiskModel
            .calculateValueAtRisk(
                stablecoin,
                exposure,
                365 days, // 1-year horizon
                9900 // 99% confidence
            );

        // Take the worse of VaR99 and Expected Shortfall
        uint256 tailRisk = expectedShortfall > var99
            ? expectedShortfall
            : var99;

        // Add stress scenario buffer (1.5x worst observed loss)
        uint256 stressBuffer = (maxObservedLoss * 15000) /
            Constants.BPS_DENOMINATOR;

        return tailRisk + stressBuffer;
    }

    /**
     * @dev Get junior tranche buffer value
     */
    function _getJuniorBufferValue(
        address stablecoin
    ) internal view returns (uint256) {
        uint256 juniorShares = insurancePool.getTotalShares(
            IInsurancePool.Tranche.JUNIOR
        );
        uint256 seniorShares = insurancePool.getTotalShares(
            IInsurancePool.Tranche.SENIOR
        );
        uint256 totalShares = seniorShares + juniorShares;

        if (totalShares == 0) return 0;

        uint256 totalValue = insurancePool.totalPool(stablecoin);
        return (totalValue * juniorShares) / totalShares;
    }

    /**
     * @dev Trigger circuit breaker to pause risky operations
     */
    function _triggerCircuitBreaker(uint256 currentRatio) internal {
        circuitBreakerActive = true;
        // Note: InsurancePool needs a pause() function - add this via governance
        emit CircuitBreakerTriggered(currentRatio, minimumCapitalRatio);
    }

    /**
     * @dev Reset circuit breaker when capital is restored
     */
    function _resetCircuitBreaker(uint256 currentRatio) internal {
        circuitBreakerActive = false;
        emit CircuitBreakerReset(currentRatio);
    }

    /**
     * @dev Governance function to update capital requirements
     */
    function updateCapitalRatios(
        uint256 _targetCapitalRatio,
        uint256 _minimumCapitalRatio,
        uint256 _pauseThresholdBps,
        uint256 _tailCushionBps
    ) external onlyOwner {
        require(
            _targetCapitalRatio >= _minimumCapitalRatio,
            "Target must be >= minimum"
        );
        require(
            _minimumCapitalRatio >= _pauseThresholdBps,
            "Minimum must be >= pause threshold"
        );

        targetCapitalRatio = _targetCapitalRatio;
        minimumCapitalRatio = _minimumCapitalRatio;
        pauseThresholdBps = _pauseThresholdBps;
        tailCushionBps = _tailCushionBps;
    }

    /**
     * @dev Manual circuit breaker control (emergency only)
     */
    function manualCircuitBreakerControl(bool active) external onlyOwner {
        circuitBreakerActive = active;
        if (active) {
            emit CircuitBreakerTriggered(0, minimumCapitalRatio);
        } else {
            emit CircuitBreakerReset(targetCapitalRatio);
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
