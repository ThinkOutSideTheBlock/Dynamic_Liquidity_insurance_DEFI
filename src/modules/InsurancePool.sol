pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../interfaces/IInsurancePool.sol";
import "../interfaces/IPremiumAdjustment.sol";
import "../tokens/SeniorShareToken.sol";
import "../tokens/JuniorShareToken.sol";
import "../libraries/Types.sol";
import "../libraries/Constants.sol";
import "../libraries/MathUtils.sol";
import "../integrations/AaveV3YieldManager.sol";
import "../integrations/ReinsuranceModule.sol";
import "../libraries/TrancheLogic.sol";
contract InsurancePool is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable,
    IInsurancePool
{
    using SafeERC20 for IERC20;
    using MathUtils for uint256;
    uint256 public constant MIN_DEPOSIT = 1000000; // Minimum deposit amount to prevent dust attacks
    SeniorShareToken public seniorToken;
    JuniorShareToken public juniorToken;
    IPremiumAdjustment public premiumModule;
    address public liquidationModule;
    address public distributionModule;
    AaveV3YieldManager public yieldManager;
    ReinsuranceModule public reinsurance;
    mapping(address => uint256) public totalPool;
    mapping(address => mapping(Tranche => uint256)) public userShares;
    mapping(uint256 => WithdrawRequest) public withdrawRequests;
    mapping(address => uint256) public reservedFunds;
    mapping(address => uint256) public lastDepositTime;
    mapping(address => mapping(Tranche => uint256)) public userDepositBlock; // Track deposit block number
    uint256 public totalWithdrawQueue;
    uint256 public nextQueueId;
    // Track pending withdrawals to prevent double spending
    mapping(address => mapping(Tranche => uint256)) public pendingWithdrawals;
    // Track withdraw requests in FIFO queue for batch processing
    uint256[] public pendingWithdrawalQueue;
    PoolConfig public config;
    bool public emergencyShutdown;
    uint256 public shutdownTime;
    modifier onlyGovernance() {
        require(msg.sender == owner(), "Only governance");
        _;
    }
    modifier onlyLiquidationModule() {
        require(msg.sender == liquidationModule, "Only liquidation module");
        _;
    }
    constructor() {
        _disableInitializers();
    }
    function initialize(
        address _premiumModule,
        address _seniorToken,
        address _juniorToken,
        address _yieldManager,
        address _reinsurance,
        PoolConfig memory _config
    ) public initializer {
        __Ownable_init(msg.sender);
        //
        premiumModule = IPremiumAdjustment(_premiumModule);
        seniorToken = SeniorShareToken(_seniorToken);
        juniorToken = JuniorShareToken(_juniorToken);
        yieldManager = AaveV3YieldManager(_yieldManager);
        reinsurance = ReinsuranceModule(_reinsurance);
        config = _config;
        if (config.maxExposurePercent == 0)
            config.maxExposurePercent = Constants.DEFAULT_MAX_EXPOSURE;
        if (config.withdrawCooldown == 0)
            config.withdrawCooldown = Constants.DEFAULT_COOLDOWN;
        if (config.maxWithdrawPercentPerEpoch == 0)
            config.maxWithdrawPercentPerEpoch = 1000;
        if (config.juniorThreshold == 0)
            config.juniorThreshold = Constants.DEFAULT_JUNIOR_THRESHOLD;
    }
    function deposit(
        address stablecoin,
        uint256 amount,
        Tranche tranche
    ) external override nonReentrant whenNotPaused {
        require(amount >= MIN_DEPOSIT, "Below minimum");
        require(!emergencyShutdown, "Emergency shutdown active");
        require(
            stablecoin == Constants.USDC || stablecoin == Constants.DAI,
            "Unsupported stablecoin"
        );
        // Calculate maximum allowed deposit based on existing pool and exposure config
        // This prevents a single deposit from being disproportionately large compared to existing pool
        if (totalPool[stablecoin] > 0) {
            uint256 maxDeposit = (totalPool[stablecoin] *
                config.maxExposurePercent) / Constants.BPS_DENOMINATOR;
            require(amount <= maxDeposit, "Exceeds exposure limit");
        } else {
            // First deposit: allow up to a reasonable maximum (e.g., 10M)
            require(amount <= 10_000_000 * 1e6, "First deposit too large");
        }
        // When totalPool[stablecoin] is 0, allow the first deposit without this specific limit
        // Other validations like MIN_DEPOSIT still apply
        uint256 premiumRate = premiumModule.getCurrentPremiumBps();
        uint256 fee = (amount * premiumRate) / Constants.BPS_DENOMINATOR;
        uint256 netAmount = amount - fee;
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), amount);
        if (fee > 0) {
            IERC20(stablecoin).safeTransfer(owner(), fee);
        }
        uint256 totalShares = getTotalShares(tranche);
        uint256 totalValue = getTotalValue(stablecoin, tranche);
        uint256 shares = totalShares == 0
            ? netAmount
            : (netAmount * totalShares) / totalValue;
        _mintShares(msg.sender, shares, tranche);
        totalPool[stablecoin] += netAmount;
        lastDepositTime[msg.sender] = block.timestamp;
        userDepositBlock[msg.sender][tranche] = block.number; // Track deposit block number to prevent same-block withdrawals

        // Transfer the netAmount to the yield manager and then have it deposit to Aave
        IERC20(stablecoin).safeTransfer(address(yieldManager), netAmount);
        yieldManager.deposit(stablecoin, netAmount);
        emit Deposit(msg.sender, stablecoin, amount, tranche, shares);
    }
    function requestWithdraw(
        uint256 shares,
        Tranche tranche,
        address stablecoin
    ) external override nonReentrant whenNotPaused {
        require(shares > 0, "Shares must be > 0");
        require(
            stablecoin == Constants.USDC || stablecoin == Constants.DAI,
            "Unsupported stablecoin"
        );

        // Check if user has enough shares considering pending withdrawals
        uint256 availableShares = userShares[msg.sender][tranche] -
            pendingWithdrawals[msg.sender][tranche];
        require(availableShares >= shares, "Insufficient shares");

        // Prevent same-block manipulation
        require(
            block.number > userDepositBlock[msg.sender][tranche],
            "Same block deposit"
        );

        // Enforce minimum holding period
        require(
            block.timestamp >=
                lastDepositTime[msg.sender] + config.withdrawCooldown,
            "Cooldown active"
        );

        // Track pending withdrawal to prevent double spending
        pendingWithdrawals[msg.sender][tranche] += shares;

        uint256 queueId = nextQueueId++;
        withdrawRequests[queueId] = WithdrawRequest({
            user: msg.sender,
            shares: shares,
            tranche: tranche,
            timestamp: block.timestamp,
            queueId: queueId,
            fulfilled: false,
            stablecoin: stablecoin
        });
        totalWithdrawQueue += shares;
        pendingWithdrawalQueue.push(queueId); // Add to batch processing queue
        emit WithdrawRequested(msg.sender, queueId, shares, tranche);
    }

    function fulfillWithdraw(uint256 queueId) external override nonReentrant {
        WithdrawRequest storage request = withdrawRequests[queueId];
        require(!request.fulfilled, "Already fulfilled");
        require(request.user != address(0), "Invalid request");
        require(msg.sender == request.user, "Not request owner");

        // Add minimum delay (e.g., 24 hours) between request and fulfillment to prevent sandwich attacks
        require(
            block.timestamp >= request.timestamp + 1 days,
            "Withdrawal delay not met"
        );

        // Calculate entitlement
        uint256 totalValue = getTotalValue(request.stablecoin, request.tranche);
        uint256 totalShares = getTotalShares(request.tranche);

        require(totalShares > 0, "No shares in tranche");

        uint256 entitlement = (request.shares * totalValue) / totalShares;
        require(entitlement > 0, "Zero entitlement");

        // Apply withdrawal limits
        uint256 maxWithdraw = (totalValue * config.maxWithdrawPercentPerEpoch) /
            Constants.BPS_DENOMINATOR;

        if (entitlement > maxWithdraw) {
            entitlement = maxWithdraw;
        }

        // Check for junior impairment and apply haircut if needed
        if (request.tranche == Tranche.SENIOR) {
            uint256 juniorValue = getTotalValue(
                request.stablecoin,
                Tranche.JUNIOR
            );
            uint256 juniorShares = getTotalShares(Tranche.JUNIOR);

            if (juniorShares > 0) {
                uint256 juniorNAV = (juniorValue * Constants.BPS_DENOMINATOR) /
                    juniorShares;

                if (juniorNAV < Constants.DEFAULT_JUNIOR_THRESHOLD) {
                    // Apply haircut - senior shares junior pain
                    uint256 impairmentRatio = Constants.BPS_DENOMINATOR -
                        juniorNAV;
                    uint256 haircut = (impairmentRatio * entitlement) /
                        (Constants.BPS_DENOMINATOR * 2);
                    entitlement = entitlement > haircut
                        ? entitlement - haircut
                        : 0;
                }
            }
        }

        // Burn shares
        _burnShares(request.user, request.shares, request.tranche);

        // Update pending withdrawals
        pendingWithdrawals[request.user][request.tranche] -= request.shares;

        // Withdraw from yield manager
        uint256 withdrawn = yieldManager.withdraw(
            request.stablecoin,
            entitlement
        );

        // Transfer to user
        IERC20(request.stablecoin).safeTransfer(request.user, withdrawn);

        request.fulfilled = true;
        totalWithdrawQueue -= request.shares;

        // Remove fulfilled request from pending queue
        _removeFromPendingQueue(queueId);

        emit WithdrawFulfilled(queueId, request.user, withdrawn);
    }

    // Helper function to remove fulfilled requests from pending queue
    function _removeFromPendingQueue(uint256 queueId) internal {
        for (uint256 i = 0; i < pendingWithdrawalQueue.length; i++) {
            if (pendingWithdrawalQueue[i] == queueId) {
                // Move the last element to current position to avoid gaps
                if (i != pendingWithdrawalQueue.length - 1) {
                    pendingWithdrawalQueue[i] = pendingWithdrawalQueue[
                        pendingWithdrawalQueue.length - 1
                    ];
                }
                pendingWithdrawalQueue.pop(); // Remove last element
                break;
            }
        }
    }

    // Function to batch fulfill withdrawals to prevent death spiral
    function batchFulfillWithdrawals(uint256 maxAmount) external nonReentrant {
        // Calculate total pending withdrawals to determine fulfillment ratio
        uint256 totalRequested = calculateTotalPendingWithdrawals();

        if (totalRequested == 0) {
            return; // No pending withdrawals
        }

        uint256 fulfillmentRatio = (maxAmount * Constants.BPS_DENOMINATOR) /
            totalRequested;

        // Process withdrawals pro-rata up to maxAmount available
        uint256 fulfilledAmount = 0;
        uint256 i = 0;
        while (
            i < pendingWithdrawalQueue.length && fulfilledAmount < maxAmount
        ) {
            uint256 queueId = pendingWithdrawalQueue[i];
            WithdrawRequest storage request = withdrawRequests[queueId];

            if (!request.fulfilled && request.user != address(0)) {
                uint256 totalValue = getTotalValue(
                    request.stablecoin,
                    request.tranche
                );
                uint256 totalShares = getTotalShares(request.tranche);

                require(totalShares > 0, "No shares in tranche");

                uint256 originalEntitlement = (request.shares * totalValue) /
                    totalShares;

                // Apply withdrawal limits
                uint256 maxWithdraw = (totalValue *
                    config.maxWithdrawPercentPerEpoch) /
                    Constants.BPS_DENOMINATOR;

                if (originalEntitlement > maxWithdraw) {
                    originalEntitlement = maxWithdraw;
                }

                // Calculate partial fulfillment based on available funds
                uint256 partialAmount = (originalEntitlement *
                    fulfillmentRatio) / Constants.BPS_DENOMINATOR;

                // Ensure we don't exceed maxAmount
                if (fulfilledAmount + partialAmount > maxAmount) {
                    partialAmount = maxAmount - fulfilledAmount;
                }

                if (partialAmount > 0) {
                    // Check for junior impairment and apply haircut if needed
                    if (request.tranche == Tranche.SENIOR) {
                        uint256 juniorValue = getTotalValue(
                            request.stablecoin,
                            Tranche.JUNIOR
                        );
                        uint256 juniorShares = getTotalShares(Tranche.JUNIOR);

                        if (juniorShares > 0) {
                            uint256 juniorNAV = (juniorValue *
                                Constants.BPS_DENOMINATOR) / juniorShares;

                            if (
                                juniorNAV < Constants.DEFAULT_JUNIOR_THRESHOLD
                            ) {
                                // Apply haircut - senior shares junior pain
                                uint256 impairmentRatio = Constants
                                    .BPS_DENOMINATOR - juniorNAV;
                                uint256 haircut = (impairmentRatio *
                                    partialAmount) /
                                    (Constants.BPS_DENOMINATOR * 2);
                                partialAmount = partialAmount > haircut
                                    ? partialAmount - haircut
                                    : 0;
                            }
                        }
                    }

                    // Burn partial shares equivalent
                    uint256 sharesToBurn = (request.shares * partialAmount) /
                        originalEntitlement;
                    _burnShares(request.user, sharesToBurn, request.tranche);

                    // Update pending withdrawals
                    pendingWithdrawals[request.user][
                        request.tranche
                    ] -= sharesToBurn;

                    // Withdraw from yield manager
                    uint256 withdrawn = yieldManager.withdraw(
                        request.stablecoin,
                        partialAmount
                    );

                    // Transfer to user
                    IERC20(request.stablecoin).safeTransfer(
                        request.user,
                        withdrawn
                    );

                    // Mark as fulfilled if completely processed
                    if (partialAmount >= originalEntitlement) {
                        request.fulfilled = true;
                        totalWithdrawQueue -= request.shares;
                        _removeFromPendingQueue(queueId); // Remove from pending queue
                    } else {
                        // Partial fulfillment - adjust the shares and entitlement
                        uint256 remainingShares = request.shares - sharesToBurn;
                        request.shares = remainingShares;
                    }

                    emit WithdrawFulfilled(
                        queueId,
                        request.user,
                        partialAmount
                    );
                    fulfilledAmount += partialAmount;
                }
            }
            i++;
        }
    }

    // Helper function to calculate total pending withdrawals
    function calculateTotalPendingWithdrawals()
        public
        view
        returns (uint256 total)
    {
        for (uint256 i = 0; i < pendingWithdrawalQueue.length; i++) {
            uint256 queueId = pendingWithdrawalQueue[i];
            WithdrawRequest memory request = withdrawRequests[queueId];

            if (!request.fulfilled && request.user != address(0)) {
                uint256 totalValue = getTotalValue(
                    request.stablecoin,
                    request.tranche
                );
                uint256 totalShares = getTotalShares(request.tranche);

                if (totalShares > 0) {
                    uint256 entitlement = (request.shares * totalValue) /
                        totalShares;

                    // Apply withdrawal limits
                    uint256 maxWithdraw = (totalValue *
                        config.maxWithdrawPercentPerEpoch) /
                        Constants.BPS_DENOMINATOR;

                    if (entitlement > maxWithdraw) {
                        entitlement = maxWithdraw;
                    }

                    total += entitlement;
                }
            }
        }
    }

    function previewWithdraw(
        uint256 shares,
        Tranche tranche
    ) external view override returns (uint256) {
        uint256 totalValue = getTotalValue(Constants.USDC, tranche);
        uint256 totalShares = getTotalShares(tranche);
        return totalShares == 0 ? 0 : (shares * totalValue) / totalShares;
    }
    function reserveFunds(
        uint256 amount,
        address stablecoin
    ) external override onlyLiquidationModule {
        require(
            totalPool[stablecoin] >= amount + reservedFunds[stablecoin],
            "Insufficient pool funds"
        );
        reservedFunds[stablecoin] += amount;
    }
    function triggerReinsurance(
        uint256 loss
    ) external override onlyLiquidationModule {
        uint256 totalPoolValue = totalPool[Constants.USDC];
        uint256 deductible = (totalPoolValue * 500) / Constants.BPS_DENOMINATOR; // 5% deductible

        require(loss > deductible, "Loss below deductible");

        uint256 coveredLoss = loss - deductible;

        // Request coverage from reinsurance module for covered portion only
        uint256 requestId = reinsurance.requestCoverage(
            coveredLoss,
            totalPool[Constants.USDC],
            abi.encodePacked(coveredLoss)
        );

        // Note: In production, the reinsurance request would need to be processed
        // by calling reinsurance.processCoverageRequest(requestId) by authorized party
        // For now, we emit with 0 top-up and handle it separately

        emit ReinsuranceTriggered(loss, coveredLoss);

        // The actual capital injection would happen through a separate admin function
        // after the reinsurance claim is approved and processed
        // Pool absorbs first 5% of loss automatically
    }

    // Add this helper function for admin to inject capital after reinsurance approval
    function injectReinsuranceCapital(uint256 amount) external onlyGovernance {
        require(amount > 0, "Invalid amount");
        IERC20(Constants.USDC).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        totalPool[Constants.USDC] += amount;
    }
    function initiateShutdown() external onlyGovernance {
        require(!emergencyShutdown, "Shutdown already initiated");
        emergencyShutdown = true;
        shutdownTime = block.timestamp + Constants.EMERGENCY_SHUTDOWN_DELAY;
    }
    function emergencyWithdraw() external nonReentrant {
        require(
            emergencyShutdown && block.timestamp >= shutdownTime,
            "Shutdown not ready"
        );
        for (uint8 i = 0; i <= 1; i++) {
            Tranche tranche = Tranche(i);
            uint256 userSharesVal = userShares[msg.sender][tranche];
            if (userSharesVal > 0) {
                uint256 entitlement = this.previewWithdraw(
                    userSharesVal,
                    tranche
                );
                _burnShares(msg.sender, userSharesVal, tranche);
                yieldManager.withdraw(Constants.USDC, entitlement);
                IERC20(Constants.USDC).safeTransfer(msg.sender, entitlement);
            }
        }
    }
    function _mintShares(
        address user,
        uint256 shares,
        Tranche tranche
    ) internal {
        userShares[user][tranche] += shares;
        if (tranche == Tranche.SENIOR) {
            seniorToken.mint(user, shares);
        } else {
            juniorToken.mint(user, shares);
        }
    }
    function _burnShares(
        address user,
        uint256 shares,
        Tranche tranche
    ) internal {
        require(userShares[user][tranche] >= shares, "Insufficient shares");
        userShares[user][tranche] -= shares;
        if (tranche == Tranche.SENIOR) {
            seniorToken.burn(user, shares);
        } else {
            juniorToken.burn(user, shares);
        }
    }
    function _getTrancheState(
        address stablecoin
    ) internal view returns (TrancheLogic.TrancheState memory) {
        return
            TrancheLogic.TrancheState({
                seniorValue: getTotalValue(stablecoin, Tranche.SENIOR),
                juniorValue: getTotalValue(stablecoin, Tranche.JUNIOR),
                seniorShares: getTotalShares(Tranche.SENIOR),
                juniorShares: getTotalShares(Tranche.JUNIOR),
                totalValue: totalPool[stablecoin]
            });
    }
    function getTotalShares(Tranche tranche) public view returns (uint256) {
        return
            tranche == Tranche.SENIOR
                ? seniorToken.totalSupply()
                : juniorToken.totalSupply();
    }
    function getTotalValue(
        address stablecoin,
        Tranche tranche
    ) public view returns (uint256) {
        uint256 yieldBalance = yieldManager.getCurrentBalance(stablecoin);
        uint256 totalShares = seniorToken.totalSupply() +
            juniorToken.totalSupply();

        if (totalShares == 0) {
            return 0; // If no shares exist, each tranche has 0 value
        }

        uint256 poolShare = (yieldBalance * getTotalShares(tranche)) /
            totalShares;
        return
            poolShare > reservedFunds[stablecoin]
                ? poolShare - reservedFunds[stablecoin]
                : 0;
    }
    function getUserShares(
        address user,
        Tranche tranche
    ) external view override returns (uint256) {
        return userShares[user][tranche];
    }
    function setLiquidationModule(
        address _liquidationModule
    ) external onlyGovernance {
        liquidationModule = _liquidationModule;
    }
    function setDistributionModule(
        address _distributionModule
    ) external onlyGovernance {
        distributionModule = _distributionModule;
    }
    function setPremiumModule(address _premiumModule) external onlyGovernance {
        premiumModule = IPremiumAdjustment(_premiumModule);
    }
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
