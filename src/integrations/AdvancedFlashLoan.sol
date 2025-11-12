pragma solidity ^0.8.19;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IAave.sol";
import "../utils/ProductionLiquidationExecutor.sol";

contract AdvancedFlashLoan is
    IFlashLoanSimpleReceiver,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    IPool public aavePool;
    ProductionLiquidationExecutor public liquidationExecutor;

    function initialize(
        address _aavePool,
        address _liquidationExecutor
    ) public initializer {
        __Ownable_init(msg.sender);
        aavePool = IPool(_aavePool);
        liquidationExecutor = ProductionLiquidationExecutor(_liquidationExecutor);
    }
    function executeFlashLoan(
        address asset,
        uint256 amount,
        bytes calldata executionData,
        uint256 deadline
    ) external nonReentrant returns (bool) {
        require(deadline > block.timestamp, "Flash loan expired");
        aavePool.flashLoanSimple(
            address(this),
            asset,
            amount,
            executionData,
            0
        );
        return true;
    }
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(aavePool), "Only Aave Pool");
        require(initiator == address(this), "Invalid initiator");

        // Decode liquidation params
        ProductionLiquidationExecutor.LiquidationParams memory liquidationParams = abi.decode(
            params,
            (ProductionLiquidationExecutor.LiquidationParams)
        );

        // Transfer borrowed funds to liquidation executor
        IERC20(asset).safeTransfer(address(liquidationExecutor), amount);

        // Execute protocol-specific liquidation
        ProductionLiquidationExecutor.LiquidationResult memory result;

        if (liquidationParams.protocol == ProductionLiquidationExecutor.Protocol.AAVE_V3) {
            result = liquidationExecutor.executeAaveLiquidation(liquidationParams);
        } else if (liquidationParams.protocol == ProductionLiquidationExecutor.Protocol.COMPOUND_V3) {
            result = liquidationExecutor.executeCompoundLiquidation(liquidationParams);
        } else if (liquidationParams.protocol == ProductionLiquidationExecutor.Protocol.LIQUITY_V2) {
            result = liquidationExecutor.executeLiquityLiquidation(liquidationParams);
        } else if (liquidationParams.protocol == ProductionLiquidationExecutor.Protocol.MORPHO_BLUE) {
            result = liquidationExecutor.executeMorphoLiquidation(liquidationParams);
        } else {
            revert("Unsupported protocol");
        }

        // Verify collateral received
        require(
            result.collateralReceived >= liquidationParams.minCollateralOut,
            "Insufficient collateral received"
        );

        // Transfer collateral back to LiquidationPurchase contract (initiator)
        IERC20(liquidationParams.collateralAsset).safeTransferFrom(
            address(liquidationExecutor),
            initiator,
            result.collateralReceived
        );

        // Repay flash loan
        uint256 totalAmount = amount + premium;
        IERC20(asset).approve(address(aavePool), totalAmount);

        return true;
    }
}
