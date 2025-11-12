// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../libraries/Constants.sol";
import "../libraries/MathUtils.sol";
import "../interfaces/IInsurancePool.sol";

/**
 * @title TrancheLogic
 * @notice Implements proper waterfall distribution for senior/junior tranches
 * @dev Ensures game-theoretic soundness with junior-first losses and senior priority
 */
library TrancheLogic {
    struct TrancheState {
        uint256 seniorValue;
        uint256 juniorValue;
        uint256 seniorShares;
        uint256 juniorShares;
        uint256 totalValue;
    }

    /**
     * @dev Calculate loss distribution respecting tranche priorities
     * Losses flow:
     * 1. Junior absorbs first loss up to 100% of NAV
     * 2. Senior absorbs remaining loss
     * 3. If senior NAV < threshold, trigger reinsurance
     */
    function distributeLoss(
        TrancheState memory state,
        uint256 loss
    )
        internal
        pure
        returns (uint256 seniorLoss, uint256 juniorLoss, bool reinsuranceNeeded)
    {
        // Junior absorbs first loss
        uint256 juniorCapacity = state.juniorValue;

        if (loss <= juniorCapacity) {
            // Loss fully absorbed by junior
            juniorLoss = loss;
            seniorLoss = 0;
            reinsuranceNeeded = false;
        } else {
            // Junior depleted, senior takes remaining loss
            juniorLoss = juniorCapacity;
            seniorLoss = loss - juniorCapacity;

            // Check if senior NAV falls below threshold (80% of original)
            uint256 newSeniorValue = state.seniorValue - seniorLoss;
            uint256 seniorNAV = state.seniorShares > 0
                ? (newSeniorValue * Constants.BPS_DENOMINATOR) /
                    state.seniorShares
                : 0;

            reinsuranceNeeded =
                seniorNAV < (Constants.DEFAULT_JUNIOR_THRESHOLD);
        }
    }

    function distributeProfit(
        TrancheState memory state,
        uint256 profit
    ) internal pure returns (uint256 seniorProfit, uint256 juniorProfit) {
        // Protect against division by zero
        if (state.juniorShares == 0 && state.seniorShares == 0) {
            return (0, 0); // No one to distribute to
        }

        if (state.juniorShares == 0) {
            // Only senior exists, give all profit to senior
            return (profit, 0);
        }

        uint256 juniorNAV = (state.juniorValue * Constants.BPS_DENOMINATOR) /
            state.juniorShares;

        // Calculate junior impairment
        if (juniorNAV < Constants.BPS_DENOMINATOR) {
            // Calculate exact deficit to restore junior to par (NAV = 10000)
            // targetJuniorValue would make NAV = 10000 when divided by juniorShares
            uint256 targetJuniorValue = (state.juniorShares * Constants.BPS_DENOMINATOR) / Constants.BPS_DENOMINATOR;
            uint256 juniorDeficit = targetJuniorValue > state.juniorValue 
                ? targetJuniorValue - state.juniorValue 
                : 0;

            if (profit <= juniorDeficit) {
                // Entire profit goes to junior restoration
                return (0, profit);
            } else {
                // Restore junior FIRST
                juniorProfit = juniorDeficit;
                uint256 excessProfit = profit - juniorDeficit;

                // After restoration, check if junior is NOW at par
                uint256 restoredJuniorValue = state.juniorValue + juniorProfit;
                uint256 restoredJuniorNAV = (restoredJuniorValue *
                    Constants.BPS_DENOMINATOR) / state.juniorShares;

                if (restoredJuniorNAV >= Constants.BPS_DENOMINATOR) {
                    // Junior now healthy, apply 80/20 split to excess
                    seniorProfit =
                        (excessProfit * 8000) /
                        Constants.BPS_DENOMINATOR;
                    juniorProfit +=
                        (excessProfit * 2000) /
                        Constants.BPS_DENOMINATOR;
                } else {
                    // Still impaired, all excess to junior
                    juniorProfit += excessProfit;
                    seniorProfit = 0;
                }
            }
        } else {
            // Both tranches healthy - standard 80/20 split
            seniorProfit = (profit * 8000) / Constants.BPS_DENOMINATOR;
            juniorProfit = (profit * 2000) / Constants.BPS_DENOMINATOR;
        }
    }

    function calculateWithdrawal(
        TrancheState memory state,
        uint256 shares,
        IInsurancePool.Tranche tranche
    ) internal pure returns (uint256 entitlement, bool restricted) {
        if (tranche == IInsurancePool.Tranche.SENIOR) {
            if (state.seniorShares == 0) {
                return (0, false);
            }

            uint256 juniorNAV = state.juniorShares > 0
                ? (state.juniorValue * Constants.BPS_DENOMINATOR) /
                    state.juniorShares
                : Constants.BPS_DENOMINATOR;

            if (juniorNAV < Constants.DEFAULT_JUNIOR_THRESHOLD) {
                // Apply haircut
                uint256 impairmentRatio = Constants.BPS_DENOMINATOR - juniorNAV;
                uint256 haircut = (impairmentRatio * state.seniorValue) /
                    (Constants.BPS_DENOMINATOR * 2);

                uint256 adjustedSeniorValue = state.seniorValue > haircut
                    ? state.seniorValue - haircut
                    : 0;

                entitlement =
                    (shares * adjustedSeniorValue) /
                    state.seniorShares;
                restricted = true;
            } else {
                entitlement = (shares * state.seniorValue) / state.seniorShares;
                restricted = false;
            }
        } else {
            if (state.juniorShares == 0) {
                return (0, false);
            }
            entitlement = (shares * state.juniorValue) / state.juniorShares;
            restricted = false;
        }
    }

    /**
     * @dev Calculate premium adjustments based on tranche utilization
     * Higher utilization = higher premiums for risk compensation
     */
    function calculateTranchePremium(
        TrancheState memory state,
        uint256 baseRate,
        IInsurancePool.Tranche tranche
    ) internal pure returns (uint256 adjustedRate) {
        uint256 utilizationBps;

        if (tranche == IInsurancePool.Tranche.SENIOR) {
            // Senior utilization based on total pool exposure
            utilizationBps = state.totalValue > 0
                ? (state.seniorValue * Constants.BPS_DENOMINATOR) /
                    state.totalValue
                : 0;
        } else {
            // Junior utilization affects risk premium more
            utilizationBps = state.totalValue > 0
                ? (state.juniorValue * Constants.BPS_DENOMINATOR) /
                    state.totalValue
                : 0;

            // Junior pays lower base rate but higher multiplier
            baseRate = (baseRate * 150) / 100; // 1.5x multiplier
        }

        // Adjust rate based on utilization (higher util = higher premium)
        uint256 utilizationAdjustment = (utilizationBps * 50) /
            Constants.BPS_DENOMINATOR; // Max 0.5% increase
        adjustedRate = baseRate + utilizationAdjustment;
    }

    /**
     * @dev Validate tranche invariants to prevent accounting bugs
     */
    function validateInvariants(
        TrancheState memory state
    ) internal pure returns (bool) {
        // Total value must equal sum of tranches
        if (state.seniorValue + state.juniorValue != state.totalValue) {
            return false;
        }

        // Shares must be non-zero if value is non-zero
        if (state.seniorValue > 0 && state.seniorShares == 0) {
            return false;
        }
        if (state.juniorValue > 0 && state.juniorShares == 0) {
            return false;
        }

        return true;
    }
}
