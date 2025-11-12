pragma solidity ^0.8.19;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IHoldingProfitDistribution.sol";
import "../interfaces/IInsurancePool.sol";
import "../interfaces/IRiskMetrics.sol";
import "../interfaces/IUniswapV3.sol";
import "../integrations/UniswapV3DexManager.sol";
import "../libraries/Types.sol";
import "../libraries/Constants.sol";
import "../libraries/MathUtils.sol";
import "../libraries/TrancheLogic.sol";
contract HoldingProfitDistribution is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    IHoldingProfitDistribution
{
    using SafeERC20 for IERC20;
    IInsurancePool public insurancePool;
    IRiskMetrics public riskMetrics;
    UniswapV3DexManager public dexManager;
    mapping(uint256 => CollateralLock) public collateralLocks;
    mapping(IInsurancePool.Tranche => uint256) public distributedProfits;
    mapping(address => mapping(IInsurancePool.Tranche => uint256))
        public claimedProfits;
    uint256 public nextLockId;
    HoldingConfig public config;
    modifier onlyLiquidationModule() {
        require(
            msg.sender == insurancePool.liquidationModule(),
            "Only liquidation module"
        );
        _;
    }
    function initialize(
        address _insurancePool,
        address _riskMetrics,
        address _dexManager,
        HoldingConfig memory _config
    ) public initializer {
        __Ownable_init(msg.sender);
        //
        insurancePool = IInsurancePool(_insurancePool);
        riskMetrics = IRiskMetrics(_riskMetrics);
        dexManager = UniswapV3DexManager(_dexManager);
        config = _config;
    }
    function lockCollateral(
        address asset,
        uint256 amount,
        uint256 entryPrice
    ) external override onlyLiquidationModule returns (uint256) {
        require(amount > 0, "Amount must be > 0");
        require(entryPrice > 0, "Invalid entry price");
        uint256 lockId = nextLockId++;
        collateralLocks[lockId] = CollateralLock({
            asset: asset,
            amount: amount,
            entryPrice: entryPrice,
            timestamp: block.timestamp,
            peakPrice: entryPrice,
            active: true,
            id: lockId
        });
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralLocked(lockId, asset, amount, entryPrice);
        return lockId;
    }
    function evaluateAndSell(uint256 lockId) external override {
        CollateralLock storage lock = collateralLocks[lockId];
        require(lock.active, "Lock not active");
        (uint256 currentPrice, uint256 confidence) = riskMetrics.getPrice(
            lock.asset
        );
        require(confidence >= 9500, "Low oracle confidence");
        bool shouldSell = _shouldSell(lock, currentPrice);
        if (shouldSell) {
            _executeSale(lockId, currentPrice);
        } else {
            if (currentPrice > lock.peakPrice) {
                lock.peakPrice = currentPrice;
            }
        }
    }
    function claim(
        uint256 shares,
        IInsurancePool.Tranche tranche
    ) external override {
        require(shares > 0, "Shares must be > 0");
        uint256 userShare = insurancePool.getUserShares(msg.sender, tranche);
        require(userShare >= shares, "Insufficient shares");
        uint256 totalDistributed = distributedProfits[tranche];
        uint256 totalShares = insurancePool.getTotalShares(tranche);
        uint256 userEntitlement = (totalDistributed * shares) / totalShares;
        require(userEntitlement > 0, "No profits to claim");
        claimedProfits[msg.sender][tranche] += userEntitlement;
        IERC20(Constants.USDC).safeTransfer(msg.sender, userEntitlement);
        emit ProfitDistributed(tranche, userEntitlement);
    }
    function previewSell(uint256 lockId) external override returns (uint256) {
        CollateralLock memory lock = collateralLocks[lockId];
        require(lock.active, "Lock not active");
        (uint256 currentPrice, ) = riskMetrics.getPrice(lock.asset);
        uint256 currentValue = (lock.amount * currentPrice) /
            Constants.PRICE_DECIMALS;
        uint256 entryValue = (lock.amount * lock.entryPrice) /
            Constants.PRICE_DECIMALS;
        return currentValue > entryValue ? currentValue - entryValue : 0;
    }
    function _shouldSell(
        CollateralLock memory lock,
        uint256 currentPrice
    ) internal view returns (bool) {
        if (
            currentPrice >=
            (lock.entryPrice *
                (Constants.BPS_DENOMINATOR + config.recoveryThreshold)) /
                Constants.BPS_DENOMINATOR
        ) {
            return true;
        }
        if (block.timestamp >= lock.timestamp + config.maxHoldDuration) {
            return true;
        }
        if (
            currentPrice <=
            (lock.peakPrice *
                (Constants.BPS_DENOMINATOR - config.trailingStop)) /
                Constants.BPS_DENOMINATOR
        ) {
            return true;
        }
        return false;
    }
    uint256 private lastChunkBlock;

    function _executeSale(uint256 lockId, uint256 currentPrice) internal {
        CollateralLock storage lock = collateralLocks[lockId];
        uint256 sellAmount = lock.amount;
        if (sellAmount > 0) {
            uint256 chunkSize = (sellAmount * config.sellChunkSize) /
                Constants.BPS_DENOMINATOR;
            uint256 remaining = sellAmount;
            uint256 totalOut = 0;
            while (remaining > 0) {
                uint256 chunk = MathUtils.min(chunkSize, remaining);

                // GET FRESH PRICE FOR EACH CHUNK
                (uint256 livePrice, uint256 confidence) = riskMetrics.getPrice(
                    lock.asset
                );
                require(confidence >= 9500, "Low confidence during sale");

                // Add price deviation check to prevent adverse price moves
                uint256 priceDiff = livePrice > lock.entryPrice
                    ? ((livePrice - lock.entryPrice) *
                        Constants.BPS_DENOMINATOR) / lock.entryPrice
                    : ((lock.entryPrice - livePrice) *
                        Constants.BPS_DENOMINATOR) / lock.entryPrice;
                require(priceDiff <= 1000, "Price moved too much"); // Max 10% deviation

                // Use quoter for actual expected output
                uint256 quotedOut = dexManager.quoter().quoteExactInputSingle(
                    lock.asset,
                    Constants.USDC,
                    3000, // fee tier
                    chunk,
                    0
                );

                // Apply max slippage to QUOTED price (not stale oracle)
                uint256 minOut = (quotedOut *
                    (Constants.BPS_DENOMINATOR - config.trailingStop)) /
                    Constants.BPS_DENOMINATOR;

                SwapParams memory params = SwapParams({
                    tokenIn: lock.asset,
                    tokenOut: Constants.USDC,
                    amountIn: chunk,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0,
                    feeTier: 3000
                });

                uint256 amountOut = dexManager.executeSwap(params);
                totalOut += amountOut;
                remaining -= chunk;

                // Add delay between chunks to prevent MEV
                if (remaining > 0) {
                    require(block.number > lastChunkBlock, "Wait next block");
                    lastChunkBlock = block.number;
                }
            }
            uint256 entryValue = (sellAmount * lock.entryPrice) /
                Constants.PRICE_DECIMALS;
            uint256 profit = totalOut > entryValue ? totalOut - entryValue : 0;
            if (profit > 0) {
                _distributeProfit(profit);
            }
            lock.active = false;
            emit CollateralSold(lockId, profit, currentPrice);
        }
    }
    function _distributeProfit(uint256 profit) internal {
        // Get current pool values for each tranche directly from InsurancePool
        uint256 seniorValue = insurancePool.getTotalValue(
            Constants.USDC,
            IInsurancePool.Tranche.SENIOR
        );
        uint256 juniorValue = insurancePool.getTotalValue(
            Constants.USDC,
            IInsurancePool.Tranche.JUNIOR
        );

        // Calculate total pool value for both tranches
        uint256 totalPoolValue = seniorValue + juniorValue;

        // Get total shares for each tranche
        uint256 totalSeniorShares = insurancePool.getTotalShares(
            IInsurancePool.Tranche.SENIOR
        );
        uint256 totalJuniorShares = insurancePool.getTotalShares(
            IInsurancePool.Tranche.JUNIOR
        );

        TrancheLogic.TrancheState memory state = TrancheLogic.TrancheState({
            seniorValue: seniorValue,
            juniorValue: juniorValue,
            seniorShares: totalSeniorShares,
            juniorShares: totalJuniorShares,
            totalValue: totalPoolValue
        });

        (uint256 seniorProfit, uint256 juniorProfit) = TrancheLogic
            .distributeProfit(state, profit);

        distributedProfits[IInsurancePool.Tranche.SENIOR] += seniorProfit;
        distributedProfits[IInsurancePool.Tranche.JUNIOR] += juniorProfit;
    }

    function _getTotalPoolValue() internal view returns (uint256) {
        // Calculate total pool value considering both USDC and DAI
        uint256 usdcValue = insurancePool.totalPool(Constants.USDC) -
            insurancePool.reservedFunds(Constants.USDC);
        uint256 daiValue = insurancePool.totalPool(Constants.DAI) -
            insurancePool.reservedFunds(Constants.DAI);
        // Convert DAI to USD equivalent if needed, for now just adding them
        return usdcValue + daiValue;
    }
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
