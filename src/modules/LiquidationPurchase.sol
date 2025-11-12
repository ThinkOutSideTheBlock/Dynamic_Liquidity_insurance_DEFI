pragma solidity ^0.8.19;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ILiquidationPurchase.sol";
import "../interfaces/IInsurancePool.sol";
import "../interfaces/IHoldingProfitDistribution.sol";
import "../interfaces/IRiskMetrics.sol";
import "../integrations/AdvancedFlashLoan.sol";
import "../libraries/Types.sol";
import "../libraries/Constants.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../security/KeeperRegistry.sol";
import "../utils/ProductionLiquidationExecutor.sol";

contract LiquidationPurchase is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard,
    ILiquidationPurchase
{
    using SafeERC20 for IERC20; // ADD THIS
    KeeperRegistry public keeperRegistry; // ADD THIS

    IInsurancePool public insurancePool;
    IRiskMetrics public riskMetrics;
    AdvancedFlashLoan public flashLoanManager;
    IHoldingProfitDistribution public holdingModule;
    ProductionLiquidationExecutor public liquidationExecutor;
    struct CommitmentData {
        bytes32 commitment;
        uint256 commitBlock;
        address keeper;
        bool revealed;
    }

    struct LiquidationOpportunity {
        uint256 troveId;
        uint256 discount; // Discount percentage (higher = better)
        uint256 collateralValue;
        uint256 debtAmount;
        uint256 timestamp;
        uint256 priority; // Calculated score
    }

    mapping(bytes32 => PurchaseAttempt) public purchaseAttempts;
    mapping(uint256 => bool) public processedTroves;
    mapping(address => uint256) public reservedFunds;
    mapping(bytes32 => CommitmentData) public commitments; // Commit-reveal mapping
    mapping(uint256 => LiquidationOpportunity) public liquidationQueue;
    mapping(bytes32 => bool) public purchaseFinalized; // Track if purchase has been finalized
    uint256[] public queueIds; // Sorted by priority
    PurchaseConfig public config;
    uint256 public nonce;
    modifier onlyKeeper() {
        require(
            keeperRegistry.isAuthorizedKeeper(msg.sender),
            "Only authorized keepers"
        );
        _;
    }
    function initialize(
        address _insurancePool,
        address _riskMetrics,
        address _flashLoanManager,
        address _holdingModule,
        address _keeperRegistry,
        address _liquidationExecutor,
        PurchaseConfig memory _config
    ) public initializer {
        __Ownable_init(msg.sender);
        insurancePool = IInsurancePool(_insurancePool);
        riskMetrics = IRiskMetrics(_riskMetrics);
        flashLoanManager = AdvancedFlashLoan(_flashLoanManager);
        holdingModule = IHoldingProfitDistribution(_holdingModule);
        keeperRegistry = KeeperRegistry(_keeperRegistry);
        liquidationExecutor = ProductionLiquidationExecutor(_liquidationExecutor);
        config = _config;
    }

    function commitPurchase(bytes32 commitment) external onlyKeeper returns (bytes32) {
        bytes32 commitId = keccak256(abi.encodePacked(
            commitment,
            block.number,
            msg.sender,
            nonce++
        ));
        
        commitments[commitId] = CommitmentData({
            commitment: commitment,
            commitBlock: block.number,
            keeper: msg.sender,
            revealed: false
        });
        
        return commitId;
    }
    
    function revealAndExecute(
        bytes32 commitId,
        uint256 troveId,
        bytes calldata reveal,
        bytes32 salt
    ) external onlyKeeper nonReentrant {
        CommitmentData storage commit = commitments[commitId];
        
        // Must wait at least 1 block
        require(block.number > commit.commitBlock, "Too early");
        require(block.number <= commit.commitBlock + 10, "Expired");
        require(msg.sender == commit.keeper, "Wrong keeper");
        require(!commit.revealed, "Already revealed");
        
        // Verify commitment
        bytes32 computedCommitment = keccak256(abi.encodePacked(reveal, salt));
        require(computedCommitment == commit.commitment, "Invalid reveal");
        
        // Decode liquidation parameters from reveal
        (address protocol, address collateralAsset, uint256 minCollateral) = abi
            .decode(reveal, (address, address, uint256));

        require(!processedTroves[troveId], "Trove already processed");
        
        (uint256 cost, uint256 expectedCollateral) = previewPurchase(troveId);
        require(cost > 0, "Invalid purchase");

        insurancePool.reserveFunds(cost, Constants.USDC);

        bytes32 executionId = keccak256(
            abi.encodePacked(
                commit.commitment,
                block.timestamp,
                troveId,
                nonce++,
                msg.sender
            )
        );

        purchaseAttempts[executionId] = PurchaseAttempt({
            executionId: executionId,
            troveId: troveId,
            amount: cost,
            asset: address(0),
            targetPrice: 0,
            status: Status.EXECUTING, // Changed to EXECUTING state to prevent reentrancy
            timestamp: block.timestamp
        });

        processedTroves[troveId] = true;
        emit PurchaseAttempted(executionId, troveId, address(0), cost);

        // Mark commitment as revealed
        commit.revealed = true;

        // Decode protocol type and borrower from reveal data
        // New format: (uint8 protocolType, address targetContract, address collateralAsset, address borrower, uint256 minCollateral)
        (uint8 protocolType, address targetContract, address collateral, address borrower, uint256 minColl) = abi
            .decode(reveal, (uint8, address, address, address, uint256));

        // Build liquidation params for the executor
        ProductionLiquidationExecutor.LiquidationParams memory liquidationParams = ProductionLiquidationExecutor.LiquidationParams({
            protocol: ProductionLiquidationExecutor.Protocol(protocolType),
            targetContract: targetContract,
            collateralAsset: collateral,
            debtAsset: Constants.USDC,
            user: borrower,
            debtToCover: cost,
            minCollateralOut: minColl,
            extraData: ""
        });

        // Execute flash loan with liquidation executor callback
        bytes memory flashData = abi.encode(liquidationParams);

        bool success = flashLoanManager.executeFlashLoan(
            Constants.USDC,
            cost,
            flashData,
            block.timestamp + 300
        );

        require(success, "Flash loan failed");

        // Transfer acquired collateral to holding module
        uint256 collateralReceived = IERC20(collateral).balanceOf(
            address(this)
        );
        require(collateralReceived >= minColl, "Insufficient collateral");

        IERC20(collateral).safeTransfer(
            address(holdingModule),
            collateralReceived
        );

        // Get current price for profit calculation
        (uint256 currentPrice, ) = riskMetrics.getPrice(collateral);

        // Lock collateral in holding module
        holdingModule.lockCollateral(
            collateral,
            collateralReceived,
            currentPrice
        );

        purchaseAttempts[executionId].status = Status.COMPLETED;
        emit PurchaseFinalized(executionId, 0, collateralReceived);
    }
    function cancelPurchase(bytes32 executionId) external override onlyKeeper {
        PurchaseAttempt storage attempt = purchaseAttempts[executionId];
        require(attempt.status == Status.PENDING, "Cannot cancel");
        attempt.status = Status.CANCELLED;
        reservedFunds[Constants.USDC] -= attempt.amount;
        emit PurchaseCancelled(executionId, "Keeper cancelled");
    }
    function attemptPurchase(uint256 troveId, bytes32 commitment) external override onlyKeeper returns (bytes32) {
        require(!processedTroves[troveId], "Trove already processed");
        
        (uint256 cost, ) = previewPurchase(troveId);
        require(cost > 0, "Invalid purchase");
        
        // Reserve funds for the purchase
        insurancePool.reserveFunds(cost, Constants.USDC);
        
        bytes32 executionId = keccak256(
            abi.encodePacked(
                commitment,
                block.timestamp,
                troveId,
                nonce++,
                msg.sender
            )
        );
        
        purchaseAttempts[executionId] = PurchaseAttempt({
            executionId: executionId,
            troveId: troveId,
            amount: cost,
            asset: Constants.USDC,
            targetPrice: 0,
            status: Status.PENDING,
            timestamp: block.timestamp
        });
        
        processedTroves[troveId] = true;
        emit PurchaseAttempted(executionId, troveId, Constants.USDC, cost);
        
        return executionId;
    }

    function finalizePurchase(
        bytes32 executionId,
        bytes calldata reveal,
        bytes32 salt
    ) external override onlyKeeper nonReentrant {
        PurchaseAttempt storage attempt = purchaseAttempts[executionId];
        require(attempt.status == Status.PENDING, "Invalid status");
        require(!purchaseFinalized[executionId], "Already finalized"); // Use the mapping

        // Update state BEFORE external calls (checks-effects-interactions)
        attempt.status = Status.EXECUTING; // Changed to EXECUTING state to prevent reentrancy

        // Decode liquidation parameters from reveal
        // Format: (uint8 protocolType, address targetContract, address collateralAsset, address borrower, uint256 minCollateral)
        (uint8 protocolType, address targetContract, address collateralAsset, address borrower, uint256 minCollateral) = abi
            .decode(reveal, (uint8, address, address, address, uint256));

        // Build liquidation params for the executor
        ProductionLiquidationExecutor.LiquidationParams memory liquidationParams = ProductionLiquidationExecutor.LiquidationParams({
            protocol: ProductionLiquidationExecutor.Protocol(protocolType),
            targetContract: targetContract,
            collateralAsset: collateralAsset,
            debtAsset: Constants.USDC,
            user: borrower,
            debtToCover: attempt.amount,
            minCollateralOut: minCollateral,
            extraData: ""
        });

        // Execute flash loan with liquidation executor callback
        bytes memory flashData = abi.encode(liquidationParams);

        bool success = flashLoanManager.executeFlashLoan(
            Constants.USDC,
            attempt.amount,
            flashData,
            block.timestamp + 300 // 5 min deadline
        );

        require(success, "Flash loan failed");

        // Transfer acquired collateral to holding module
        uint256 collateralReceived = IERC20(collateralAsset).balanceOf(
            address(this)
        );
        require(collateralReceived >= minCollateral, "Insufficient collateral");

        IERC20(collateralAsset).safeTransfer(
            address(holdingModule),
            collateralReceived
        );

        // Get current price for profit calculation
        (uint256 currentPrice, ) = riskMetrics.getPrice(collateralAsset);

        // Lock collateral in holding module
        holdingModule.lockCollateral(
            collateralAsset,
            collateralReceived,
            currentPrice
        );

        // Final state update
        attempt.status = Status.COMPLETED;
        purchaseFinalized[executionId] = true; // Mark as finalized
        
        emit PurchaseFinalized(executionId, 0, collateralReceived);
    }

    function previewPurchase(
        uint256 troveId
    ) public view override returns (uint256 cost, uint256 expectedCollateral) {
        cost = ((troveId % 1000) + 1) * 1e6; // CHANGE THIS LINE
        expectedCollateral = (cost * 11500) / Constants.BPS_DENOMINATOR;
    }
    
    function addLiquidationOpportunity(
        uint256 troveId,
        uint256 collateralValue,
        uint256 debtAmount
    ) external onlyKeeper {
        uint256 discount = ((collateralValue - debtAmount) * Constants.BPS_DENOMINATOR) / collateralValue;
        
        // Priority = discount * size * (1/time_decay)
        uint256 priority = (discount * collateralValue) / 1e18;
        
        liquidationQueue[troveId] = LiquidationOpportunity({
            troveId: troveId,
            discount: discount,
            collateralValue: collateralValue,
            debtAmount: debtAmount,
            timestamp: block.timestamp,
            priority: priority
        });
        
        _insertSorted(troveId, priority);
    }
    
    function getTopLiquidation() external view returns (uint256 troveId) {
        require(queueIds.length > 0, "Queue empty");
        return queueIds[0];
    }
    
    function _insertSorted(uint256 troveId, uint256 priority) private {
        // Find the correct position to insert based on priority (descending order)
        uint256 insertIndex = queueIds.length;
        for (uint256 i = 0; i < queueIds.length; i++) {
            if (liquidationQueue[queueIds[i]].priority < priority) {
                insertIndex = i;
                break;
            }
        }
        
        // Insert the troveId at the correct position
        if (insertIndex == queueIds.length) {
            // Adding to end
            queueIds.push(troveId);
        } else {
            // Insert at index - we'll push to end and shift elements
            queueIds.push(0); // Create space at end
            for (uint256 i = queueIds.length - 1; i > insertIndex; i--) {
                queueIds[i] = queueIds[i - 1];
            }
            queueIds[insertIndex] = troveId;
        }
    }
    
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
