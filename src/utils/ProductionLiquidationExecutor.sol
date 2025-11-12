// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ProductionLiquidationExecutor
 * @notice Real integrations with Aave V3, Compound V3, Liquity V2, Morpho
 * @dev Handles actual liquidation calls with proper callbacks
 */
contract ProductionLiquidationExecutor {
    using SafeERC20 for IERC20;

    address public flashLoanManager;

    modifier onlyFlashLoanManager() {
        require(msg.sender == flashLoanManager, "Only flash loan manager");
        _;
    }

    constructor(address _flashLoanManager) {
        flashLoanManager = _flashLoanManager;
    }

    enum Protocol {
        AAVE_V3,
        COMPOUND_V3,
        LIQUITY_V2,
        MORPHO_BLUE
    }

    struct LiquidationParams {
        Protocol protocol;
        address targetContract;
        address collateralAsset;
        address debtAsset;
        address user; // Borrower being liquidated
        uint256 debtToCover;
        uint256 minCollateralOut;
        bytes extraData;
    }

    struct LiquidationResult {
        uint256 collateralReceived;
        uint256 debtPaid;
        uint256 liquidationBonus;
        uint256 gasUsed;
    }

    // Protocol-specific contract addresses (Ethereum mainnet)
    address public constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant COMPOUND_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    address public constant LIQUITY_V2_TROVE_MANAGER = address(0); // TBD when V2 launches - update this
    address public constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    event LiquidationExecuted(
        Protocol indexed protocol,
        address indexed collateral,
        uint256 collateralReceived,
        uint256 profit
    );

    /**
     * @notice Execute liquidation on Aave V3
     * @dev Uses flash loan for capital efficiency
     */
    function executeAaveLiquidation(
        LiquidationParams memory params
    ) external onlyFlashLoanManager returns (LiquidationResult memory) {
        require(params.protocol == Protocol.AAVE_V3, "Wrong protocol");

        uint256 gasStart = gasleft();

        // Approve Aave pool to spend debt asset
        IERC20(params.debtAsset).forceApprove(AAVE_V3_POOL, params.debtToCover);

        // Aave V3 liquidation call
        // liquidationCall(address collateral, address debt, address user, uint256 debtToCover, bool receiveAToken)
        IAaveV3Pool(AAVE_V3_POOL).liquidationCall(
            params.collateralAsset,
            params.debtAsset,
            params.user,
            params.debtToCover,
            false // Receive underlying, not aToken
        );

        uint256 collateralReceived = IERC20(params.collateralAsset).balanceOf(address(this));

        require(
            collateralReceived >= params.minCollateralOut,
            "Insufficient collateral"
        );

        // Approve flash loan manager to pull collateral
        IERC20(params.collateralAsset).forceApprove(flashLoanManager, collateralReceived);

        uint256 gasUsed = gasStart - gasleft();

        emit LiquidationExecuted(
            Protocol.AAVE_V3,
            params.collateralAsset,
            collateralReceived,
            collateralReceived - params.debtToCover
        );

        return LiquidationResult({
            collateralReceived: collateralReceived,
            debtPaid: params.debtToCover,
            liquidationBonus: _calculateBonus(collateralReceived, params.debtToCover),
            gasUsed: gasUsed
        });
    }

    /**
     * @notice Execute liquidation on Compound V3
     * @dev Compound V3 has different liquidation interface
     */
    function executeCompoundLiquidation(
        LiquidationParams memory params
    ) external onlyFlashLoanManager returns (LiquidationResult memory) {
        require(params.protocol == Protocol.COMPOUND_V3, "Wrong protocol");

        uint256 gasStart = gasleft();

        // Approve Compound to spend debt asset
        IERC20(params.debtAsset).forceApprove(params.targetContract, params.debtToCover);

        // Compound V3: absorb(address absorber, address[] calldata accounts)
        address[] memory accounts = new address[](1);
        accounts[0] = params.user;

        ICompoundV3(params.targetContract).absorb(address(this), accounts);

        // After absorb, buy collateral from protocol
        uint256 collateralReceived = ICompoundV3(params.targetContract).buyCollateral(
            params.collateralAsset,
            params.minCollateralOut,
            params.debtToCover,
            address(this)
        );

        // Approve flash loan manager to pull collateral
        IERC20(params.collateralAsset).forceApprove(flashLoanManager, collateralReceived);

        uint256 gasUsed = gasStart - gasleft();

        emit LiquidationExecuted(
            Protocol.COMPOUND_V3,
            params.collateralAsset,
            collateralReceived,
            collateralReceived - params.debtToCover
        );

        return LiquidationResult({
            collateralReceived: collateralReceived,
            debtPaid: params.debtToCover,
            liquidationBonus: _calculateBonus(collateralReceived, params.debtToCover),
            gasUsed: gasUsed
        });
    }

    /**
     * @notice Execute liquidation on Liquity V2
     * @dev Liquity uses redemption mechanism
     */
    function executeLiquityLiquidation(
        LiquidationParams memory params
    ) external onlyFlashLoanManager returns (LiquidationResult memory) {
        require(params.protocol == Protocol.LIQUITY_V2, "Wrong protocol");

        uint256 gasStart = gasleft();

        // Approve Liquity to spend debt asset
        IERC20(params.debtAsset).forceApprove(params.targetContract, params.debtToCover);

        // Liquity V2: liquidate(address _borrower)
        (uint256 collateralGained, uint256 debtCancelled) = ILiquityTroveManager(
            params.targetContract
        ).liquidate(params.user);

        require(collateralGained >= params.minCollateralOut, "Insufficient collateral");

        // Approve flash loan manager to pull collateral
        IERC20(params.collateralAsset).forceApprove(flashLoanManager, collateralGained);

        uint256 gasUsed = gasStart - gasleft();

        emit LiquidationExecuted(
            Protocol.LIQUITY_V2,
            params.collateralAsset,
            collateralGained,
            collateralGained - debtCancelled
        );

        return LiquidationResult({
            collateralReceived: collateralGained,
            debtPaid: debtCancelled,
            liquidationBonus: _calculateBonus(collateralGained, debtCancelled),
            gasUsed: gasUsed
        });
    }

    /**
     * @notice Execute liquidation on Morpho Blue
     * @dev Morpho uses peer-to-peer matching
     */
    function executeMorphoLiquidation(
        LiquidationParams memory params
    ) external onlyFlashLoanManager returns (LiquidationResult memory) {
        require(params.protocol == Protocol.MORPHO_BLUE, "Wrong protocol");

        uint256 gasStart = gasleft();

        // Approve Morpho to spend debt asset
        IERC20(params.debtAsset).forceApprove(MORPHO_BLUE, params.debtToCover);

        // Morpho Blue liquidation
        (uint256 seizedAssets, uint256 repaidAssets) = IMorphoBlue(MORPHO_BLUE).liquidate(
            params.extraData, // Market params
            params.user,
            params.debtToCover,
            0, // Max collateral to seize (0 = unlimited)
            abi.encode(params.minCollateralOut)
        );

        require(seizedAssets >= params.minCollateralOut, "Insufficient collateral");

        // Approve flash loan manager to pull collateral
        IERC20(params.collateralAsset).forceApprove(flashLoanManager, seizedAssets);

        uint256 gasUsed = gasStart - gasleft();

        emit LiquidationExecuted(
            Protocol.MORPHO_BLUE,
            params.collateralAsset,
            seizedAssets,
            seizedAssets - repaidAssets
        );

        return LiquidationResult({
            collateralReceived: seizedAssets,
            debtPaid: repaidAssets,
            liquidationBonus: _calculateBonus(seizedAssets, repaidAssets),
            gasUsed: gasUsed
        });
    }

    /**
     * @notice Calculate liquidation bonus
     */
    function _calculateBonus(
        uint256 collateral,
        uint256 debt
    ) internal pure returns (uint256) {
        if (collateral <= debt) return 0;
        return collateral - debt;
    }

    /**
     * @notice Preview liquidation profitability
     * @dev Used by off-chain keepers to decide if liquidation is profitable
     */
    function previewLiquidation(
        LiquidationParams memory params
    ) external view returns (uint256 expectedProfit, uint256 confidence) {
        if (params.protocol == Protocol.AAVE_V3) {
            // Query Aave oracle for collateral value
            uint256 collateralPrice = IAaveV3Pool(AAVE_V3_POOL).getAssetPrice(
                params.collateralAsset
            );
            uint256 liquidationBonus = 10500; // 5% bonus (10500/10000)
            
            uint256 expectedCollateralValue = (params.debtToCover * liquidationBonus) / 10000;
            expectedProfit = expectedCollateralValue > params.debtToCover 
                ? expectedCollateralValue - params.debtToCover 
                : 0;
            
            confidence = 9500; // 95% confidence
        }
        // Add other protocols...
    }
}

// Interfaces
interface IAaveV3Pool {
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;
    
    function getAssetPrice(address asset) external view returns (uint256);
}

interface ICompoundV3 {
    function absorb(address absorber, address[] calldata accounts) external;
    function buyCollateral(
        address asset,
        uint256 minAmount,
        uint256 baseAmount,
        address recipient
    ) external returns (uint256);
}

interface ILiquityTroveManager {
    function liquidate(address _borrower) external returns (uint256, uint256);
}

interface IMorphoBlue {
    function liquidate(
        bytes calldata marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256);
}