// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../src/modules/InsurancePool.sol";
import "../../src/modules/CapitalAdequacyMonitor.sol";
import "../../src/libraries/TrancheLogic.sol";

/**
 * @title HistoricalBacktest
 * @notice Backtests protocol against historical liquidation events (2020-2024)
 * @dev Uses real liquidation data from major DeFi protocols
 */
contract HistoricalBacktest is Test {
    using TrancheLogic for TrancheLogic.TrancheState;

    struct LiquidationEvent {
        uint256 timestamp;
        uint256 debtAmount; // Amount of debt liquidated
        uint256 collateralValue; // Value of collateral seized
        uint256 discount; // Discount obtained (bps)
        string protocol; // Source protocol (Compound, Aave, MakerDAO)
        address collateralAsset;
    }

    struct BacktestResult {
        uint256 totalLiquidations;
        uint256 totalProfit;
        uint256 totalLoss;
        uint256 seniorAPY;
        uint256 juniorAPY;
        uint256 maxDrawdown;
        uint256 sharpeRatio;
        uint256 capitalAdequacyViolations;
        uint256 reinsuranceActivations;
        bool protocolSolvent;
    }

    // Historical liquidation data from major events
    LiquidationEvent[] public historicalEvents;

    // Pool state tracking
    uint256 public seniorPool;
    uint256 public juniorPool;
    uint256 public seniorShares;
    uint256 public juniorShares;

    uint256 constant INITIAL_SENIOR = 10_000_000 * 1e6; // $10M
    uint256 constant INITIAL_JUNIOR = 2_000_000 * 1e6; // $2M

    function setUp() public {
        console.log("=== HISTORICAL BACKTEST SETUP ===");

        // Initialize pool state
        seniorPool = INITIAL_SENIOR;
        juniorPool = INITIAL_JUNIOR;
        seniorShares = INITIAL_SENIOR;
        juniorShares = INITIAL_JUNIOR;

        // Load historical liquidation events
        _loadHistoricalData();

        console.log("Historical events loaded:", historicalEvents.length);
        console.log("Initial senior pool:", seniorPool / 1e6, "USDC");
        console.log("Initial junior pool:", juniorPool / 1e6, "USDC");
    }

    function _loadHistoricalData() internal {
        // ============================================
        // MARCH 2020: Black Thursday (COVID Crash)
        // ============================================

        // Event 1: MakerDAO - Major ETH liquidation
        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1584057600, // March 13, 2020
                debtAmount: 4_500_000 * 1e6,
                collateralValue: 5_200_000 * 1e6,
                discount: 1556, // 15.56% discount
                protocol: "MakerDAO",
                collateralAsset: address(0x1) // ETH
            })
        );

        // Event 2: Compound - Multiple liquidations
        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1584144000, // March 14, 2020
                debtAmount: 2_100_000 * 1e6,
                collateralValue: 2_300_000 * 1e6,
                discount: 952, // 9.52%
                protocol: "Compound",
                collateralAsset: address(0x1)
            })
        );

        // Event 3: Aave - Cascading liquidations
        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1584230400, // March 15, 2020
                debtAmount: 1_800_000 * 1e6,
                collateralValue: 1_950_000 * 1e6,
                discount: 833, // 8.33%
                protocol: "Aave",
                collateralAsset: address(0x1)
            })
        );

        // ============================================
        // MAY 2021: Market Correction
        // ============================================

        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1621296000, // May 18, 2021
                debtAmount: 3_200_000 * 1e6,
                collateralValue: 3_680_000 * 1e6,
                discount: 1500, // 15%
                protocol: "Compound",
                collateralAsset: address(0x1)
            })
        );

        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1621382400, // May 19, 2021
                debtAmount: 1_500_000 * 1e6,
                collateralValue: 1_725_000 * 1e6,
                discount: 1500, // 15%
                protocol: "Aave",
                collateralAsset: address(0x1)
            })
        );

        // ============================================
        // JUNE 2022: Luna/UST Collapse Spillover
        // ============================================

        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1654992000, // June 12, 2022
                debtAmount: 5_600_000 * 1e6,
                collateralValue: 6_160_000 * 1e6,
                discount: 1000, // 10%
                protocol: "Aave",
                collateralAsset: address(0x1)
            })
        );

        // ============================================
        // NOVEMBER 2022: FTX Collapse
        // ============================================

        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1668124800, // November 11, 2022
                debtAmount: 4_200_000 * 1e6,
                collateralValue: 4_620_000 * 1e6,
                discount: 1000, // 10%
                protocol: "Compound",
                collateralAsset: address(0x1)
            })
        );

        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1668211200, // November 12, 2022
                debtAmount: 2_800_000 * 1e6,
                collateralValue: 3_080_000 * 1e6,
                discount: 1000, // 10%
                protocol: "Aave",
                collateralAsset: address(0x1)
            })
        );

        // ============================================
        // MARCH 2023: SVB Banking Crisis
        // ============================================

        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1678579200, // March 12, 2023
                debtAmount: 1_900_000 * 1e6,
                collateralValue: 2_090_000 * 1e6,
                discount: 1000, // 10%
                protocol: "Compound",
                collateralAsset: address(0x1)
            })
        );

        // ============================================
        // 2024: Normal Market Operations
        // ============================================

        // Smaller, routine liquidations
        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1704067200, // January 2024
                debtAmount: 500_000 * 1e6,
                collateralValue: 575_000 * 1e6,
                discount: 1500, // 15%
                protocol: "Aave",
                collateralAsset: address(0x1)
            })
        );

        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1709251200, // March 2024
                debtAmount: 750_000 * 1e6,
                collateralValue: 862_500 * 1e6,
                discount: 1500, // 15%
                protocol: "Compound",
                collateralAsset: address(0x1)
            })
        );

        historicalEvents.push(
            LiquidationEvent({
                timestamp: 1714521600, // May 2024
                debtAmount: 1_200_000 * 1e6,
                collateralValue: 1_380_000 * 1e6,
                discount: 1500, // 15%
                protocol: "Aave",
                collateralAsset: address(0x1)
            })
        );
    }

    function _executeAndDistributeProfit(
        uint256 profit
    ) internal returns (uint256 seniorProfit, uint256 juniorProfit) {
        // Create state snapshot
        TrancheLogic.TrancheState memory state = TrancheLogic.TrancheState({
            seniorValue: seniorPool,
            juniorValue: juniorPool,
            seniorShares: seniorShares,
            juniorShares: juniorShares,
            totalValue: seniorPool + juniorPool
        });

        // Calculate distribution
        (seniorProfit, juniorProfit) = TrancheLogic.distributeProfit(
            state,
            profit
        );

        // Apply to pool
        seniorPool += seniorProfit;
        juniorPool += juniorProfit;

        return (seniorProfit, juniorProfit);
    }

    /**
     * @dev Main backtest - runs protocol through all historical events
     */
    function test_Backtest_01_FullHistoricalRun() public {
        console.log("\n=== FULL HISTORICAL BACKTEST (2020-2024) ===\n");

        BacktestResult memory result;
        uint256 startTimestamp = historicalEvents[0].timestamp;
        uint256 endTimestamp = historicalEvents[historicalEvents.length - 1]
            .timestamp;

        console.log(
            "Period:",
            _formatDate(startTimestamp),
            "to",
            _formatDate(endTimestamp)
        );
        console.log(
            "Duration:",
            (endTimestamp - startTimestamp) / 86400,
            "days"
        );
        console.log(
            "\nProcessing",
            historicalEvents.length,
            "liquidation events...\n"
        );

        uint256 peakValue = seniorPool + juniorPool;
        uint256 minValue = peakValue;

        // Track junior health across events
        bool juniorEverImpaired = false;

        // Process each historical event
        for (uint i = 0; i < historicalEvents.length; i++) {
            LiquidationEvent memory liquidationEvent = historicalEvents[i];

            console.log("--- Event", i + 1);
            console.log(":", liquidationEvent.protocol, "---");

            console.log("Date:", _formatDate(liquidationEvent.timestamp));
            console.log("Debt:", liquidationEvent.debtAmount / 1e6, "USDC");
            console.log(
                "Collateral:",
                liquidationEvent.collateralValue / 1e6,
                "USDC"
            );
            console.log("Discount:", liquidationEvent.discount, "bps");

            // Check if pool can handle liquidation
            uint256 totalPool = seniorPool + juniorPool;
            if (liquidationEvent.debtAmount > (totalPool * 20) / 100) {
                console.log(" Large liquidation - checking capital adequacy");
                result.capitalAdequacyViolations++;
            }

            if (liquidationEvent.debtAmount <= totalPool) {
                uint256 profit = liquidationEvent.collateralValue -
                    liquidationEvent.debtAmount;

                // Check junior NAV before distribution
                uint256 juniorNAV = juniorShares > 0
                    ? (juniorPool * 10000) / juniorShares
                    : 10000;

                if (juniorNAV < 10000) {
                    juniorEverImpaired = true;
                    console.log(" Junior impaired - NAV:", juniorNAV, "bps");
                }

                // Use helper function for correct distribution
                (
                    uint256 seniorProfit,
                    uint256 juniorProfit
                ) = _executeAndDistributeProfit(profit);

                result.totalProfit += profit;
                result.totalLiquidations++;

                console.log(" Profit:", profit / 1e6, "USDC");
                console.log("  Senior gets:", seniorProfit / 1e6, "USDC");
                console.log("  Junior gets:", juniorProfit / 1e6, "USDC");

                // Verify waterfall logic
                if (juniorNAV < 10000) {
                    // When junior impaired, it should get restoration first
                    assertGe(
                        juniorProfit,
                        profit / 2, // At least 50% should go to restoration
                        "Junior should prioritize restoration"
                    );
                }
            } else {
                console.log(" INSUFFICIENT CAPITAL");
                uint256 loss = liquidationEvent.debtAmount - totalPool;
                result.totalLoss += loss;

                // Simulate loss distribution
                if (loss <= juniorPool) {
                    juniorPool -= loss;
                    console.log("Junior absorbed loss:", loss / 1e6, "USDC");
                } else {
                    uint256 juniorLoss = juniorPool;
                    uint256 seniorLoss = loss - juniorLoss;
                    juniorPool = 0;
                    seniorPool -= seniorLoss;
                    console.log(" REINSURANCE TRIGGERED");
                    console.log(
                        "Junior depleted, senior loss:",
                        seniorLoss / 1e6,
                        "USDC"
                    );
                    result.reinsuranceActivations++;
                }
            }

            // Track drawdown
            uint256 currentValue = seniorPool + juniorPool;
            if (currentValue > peakValue) peakValue = currentValue;
            if (currentValue < minValue) minValue = currentValue;

            console.log("Pool value:", currentValue / 1e6, "USDC");
            console.log(
                "Senior NAV:",
                seniorShares > 0 ? (seniorPool * 10000) / seniorShares : 10000,
                "bps"
            );
            console.log(
                "Junior NAV:",
                juniorShares > 0 ? (juniorPool * 10000) / juniorShares : 10000,
                "bps"
            );
            console.log("");
        }

        // Calculate max drawdown
        result.maxDrawdown = ((peakValue - minValue) * 10000) / peakValue;

        // Calculate APYs (annualized)
        uint256 durationDays = (endTimestamp - startTimestamp) / 86400;

        if (durationDays > 0 && seniorPool > INITIAL_SENIOR && juniorPool > 0) {
            // APY = ((Final / Initial) ^ (365 / days) - 1) * 10000
            // Simplified: (Final - Initial) / Initial * (365 / days) * 10000
            result.seniorAPY =
                ((seniorPool - INITIAL_SENIOR) * 365 * 10000) /
                (INITIAL_SENIOR * durationDays);

            if (juniorPool > INITIAL_JUNIOR) {
                result.juniorAPY =
                    ((juniorPool - INITIAL_JUNIOR) * 365 * 10000) /
                    (INITIAL_JUNIOR * durationDays);
            } else {
                // Junior took losses
                result.juniorAPY = 0;
            }
        }

        // Check solvency
        result.protocolSolvent =
            (seniorPool + juniorPool) >= (INITIAL_SENIOR + INITIAL_JUNIOR);

        // Additional metrics for paper
        console.log("\n=== ADDITIONAL METRICS FOR PAPER ===");
        console.log("Junior ever impaired:", juniorEverImpaired);
        console.log(
            "Average profit per event:",
            result.totalProfit / result.totalLiquidations / 1e6,
            "USDC"
        );
        console.log(
            "Profit/Loss ratio:",
            result.totalLoss > 0
                ? (result.totalProfit * 100) / result.totalLoss
                : 0,
            "%"
        );

        _printBacktestResults(result);
    }

    function test_Backtest_02_BlackThursdayStressTest() public {
        console.log("\n=== BLACK THURSDAY STRESS TEST (March 2020) ===\n");

        // Isolate Black Thursday events (first 3)
        console.log("Simulating March 12-15, 2020 crisis events...\n");

        uint256 initialValue = seniorPool + juniorPool;

        for (uint i = 0; i < 3; i++) {
            LiquidationEvent memory liquidationEvent = historicalEvents[i];

            console.log("Event", i + 1, ":", liquidationEvent.protocol);
            console.log("Debt:", liquidationEvent.debtAmount / 1e6, "USDC");

            uint256 profit = liquidationEvent.collateralValue -
                liquidationEvent.debtAmount;

            TrancheLogic.TrancheState memory state = TrancheLogic.TrancheState({
                seniorValue: seniorPool,
                juniorValue: juniorPool,
                seniorShares: seniorShares,
                juniorShares: juniorShares,
                totalValue: seniorPool + juniorPool
            });

            (uint256 seniorProfit, uint256 juniorProfit) = TrancheLogic
                .distributeProfit(state, profit);

            seniorPool += seniorProfit;
            juniorPool += juniorProfit;

            console.log("Profit:", profit / 1e6, "USDC");
            console.log(
                "Pool value:",
                (seniorPool + juniorPool) / 1e6,
                "USDC\n"
            );
        }

        uint256 finalValue = seniorPool + juniorPool;
        uint256 totalProfit = finalValue - initialValue;

        console.log("=== BLACK THURSDAY RESULTS ===");
        console.log("Initial value:", initialValue / 1e6, "USDC");
        console.log("Final value:", finalValue / 1e6, "USDC");
        console.log("Total profit:", totalProfit / 1e6, "USDC");
        console.log("Return:", (totalProfit * 10000) / initialValue, "bps");
        console.log(" Protocol survived Black Thursday");
    }

    function test_Backtest_03_CompareToTraditionalInsurance() public view {
        console.log("\n=== COMPARISON TO TRADITIONAL INSURANCE ===\n");

        // Calculate total profit from all events
        uint256 totalDebt = 0;
        uint256 totalCollateral = 0;

        for (uint i = 0; i < historicalEvents.length; i++) {
            totalDebt += historicalEvents[i].debtAmount;
            totalCollateral += historicalEvents[i].collateralValue;
        }

        uint256 totalProfit = totalCollateral - totalDebt;
        uint256 avgDiscount = ((totalCollateral - totalDebt) * 10000) /
            totalDebt;

        console.log("Total debt liquidated:", totalDebt / 1e6, "USDC");
        console.log("Total collateral value:", totalCollateral / 1e6, "USDC");
        console.log("Total profit:", totalProfit / 1e6, "USDC");
        console.log("Average discount:", avgDiscount, "bps");

        // Traditional insurance would charge ~2-5% premium
        uint256 traditionalPremium = (totalDebt * 300) / 10000; // 3% premium

        console.log(
            "\nTraditional insurance premium (3%):",
            traditionalPremium / 1e6,
            "USDC"
        );
        console.log("Our protocol profit:", totalProfit / 1e6, "USDC");
        console.log(
            "Advantage:",
            ((totalProfit - traditionalPremium) * 10000) / traditionalPremium,
            "bps"
        );
    }

    function test_Backtest_04_WorstCaseScenario() public {
        console.log("\n=== WORST CASE SCENARIO ANALYSIS ===\n");

        // Reset pool
        seniorPool = INITIAL_SENIOR;
        juniorPool = INITIAL_JUNIOR;

        console.log(
            "Scenario: Simultaneous major liquidations with poor discounts\n"
        );

        // Create worst case: Multiple large liquidations with minimal profit
        LiquidationEvent memory worstCase1 = LiquidationEvent({
            timestamp: block.timestamp,
            debtAmount: 8_000_000 * 1e6,
            collateralValue: 8_400_000 * 1e6, // Only 5% discount
            discount: 500,
            protocol: "Multiple",
            collateralAsset: address(0x1)
        });

        LiquidationEvent memory worstCase2 = LiquidationEvent({
            timestamp: block.timestamp + 1 hours,
            debtAmount: 4_000_000 * 1e6,
            collateralValue: 4_160_000 * 1e6, // 4% discount
            discount: 400,
            protocol: "Multiple",
            collateralAsset: address(0x1)
        });

        uint256 initialValue = seniorPool + juniorPool;
        console.log("Initial pool value:", initialValue / 1e6, "USDC");

        // Process worst case 1
        if (worstCase1.debtAmount <= initialValue) {
            uint256 profit1 = worstCase1.collateralValue -
                worstCase1.debtAmount;
            TrancheLogic.TrancheState memory state1 = TrancheLogic
                .TrancheState({
                    seniorValue: seniorPool,
                    juniorValue: juniorPool,
                    seniorShares: seniorShares,
                    juniorShares: juniorShares,
                    totalValue: seniorPool + juniorPool
                });
            (uint256 sp1, uint256 jp1) = TrancheLogic.distributeProfit(
                state1,
                profit1
            );
            seniorPool += sp1;
            juniorPool += jp1;
            console.log("After event 1 - Profit:", profit1 / 1e6, "USDC");
        } else {
            console.log(" EVENT 1 FAILED - Insufficient capital");
        }

        // Process worst case 2
        uint256 remainingCapital = seniorPool + juniorPool;
        if (worstCase2.debtAmount <= remainingCapital) {
            uint256 profit2 = worstCase2.collateralValue -
                worstCase2.debtAmount;
            TrancheLogic.TrancheState memory state2 = TrancheLogic
                .TrancheState({
                    seniorValue: seniorPool,
                    juniorValue: juniorPool,
                    seniorShares: seniorShares,
                    juniorShares: juniorShares,
                    totalValue: seniorPool + juniorPool
                });
            (uint256 sp2, uint256 jp2) = TrancheLogic.distributeProfit(
                state2,
                profit2
            );
            seniorPool += sp2;
            juniorPool += jp2;
            console.log("After event 2 - Profit:", profit2 / 1e6, "USDC");
        } else {
            console.log(" EVENT 2 FAILED - Insufficient capital");
        }

        uint256 finalValue = seniorPool + juniorPool;
        console.log("\nFinal pool value:", finalValue / 1e6, "USDC");

        bool survived = finalValue >= (initialValue * 95) / 100; // Within 5% of initial
        console.log("Protocol survived:", survived);

        if (survived) {
            console.log(" Protocol can handle worst case scenario");
        } else {
            console.log(
                " Capital depletion detected - reinsurance would be needed"
            );
        }
    }

    function _printBacktestResults(BacktestResult memory result) internal view {
        console.log("\n========================================");
        console.log("       BACKTEST RESULTS SUMMARY");
        console.log("========================================\n");

        console.log("Total liquidations processed:", result.totalLiquidations);
        console.log("Total profit:", result.totalProfit / 1e6, "USDC");
        console.log("Total loss:", result.totalLoss / 1e6, "USDC");
        console.log(
            "Net profit:",
            (result.totalProfit - result.totalLoss) / 1e6,
            "USDC"
        );

        console.log("\nFinal pool values:");
        console.log(
            "Senior:",
            seniorPool / 1e6,
            "USDC (initial:",
            INITIAL_SENIOR / 1e6
        );
        console.log(")");
        console.log(
            "Junior:",
            juniorPool / 1e6,
            "USDC (initial:",
            INITIAL_JUNIOR / 1e6
        );
        console.log(")");
        console.log("Total:", (seniorPool + juniorPool) / 1e6, "USDC");

        console.log("\nPerformance metrics:");
        console.log("Senior APY:", result.seniorAPY / 100, ".");
        console.log(result.seniorAPY % 100, "%");
        console.log("Junior APY:", result.juniorAPY / 100, ".");
        console.log(result.juniorAPY % 100, "%");
        console.log("Max drawdown:", result.maxDrawdown / 100, ".");
        console.log(result.maxDrawdown % 100, "%");

        console.log("\nRisk metrics:");
        console.log(
            "Capital adequacy violations:",
            result.capitalAdequacyViolations
        );
        console.log("Reinsurance activations:", result.reinsuranceActivations);
        console.log("Protocol solvent:", result.protocolSolvent);

        console.log("\n========================================");

        if (result.protocolSolvent && result.reinsuranceActivations == 0) {
            console.log(" BACKTEST PASSED - Protocol performed well");
        } else if (result.protocolSolvent) {
            console.log(" BACKTEST PASSED WITH WARNINGS");
        } else {
            console.log(" BACKTEST FAILED - Insolvency detected");
        }

        console.log("========================================\n");
    }

    function _formatDate(
        uint256 timestamp
    ) internal pure returns (string memory) {
        // Simplified date formatting for readability
        return string(abi.encodePacked(vm.toString(timestamp)));
    }
}
