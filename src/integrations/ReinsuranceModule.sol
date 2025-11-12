pragma solidity ^0.8.19;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libraries/MathUtils.sol";
contract ReinsuranceModule is OwnableUpgradeable {
    using SafeERC20 for IERC20;
    struct ReinsuranceProvider {
        address providerAddress;
        uint256 allocatedCapital;
        uint256 coverageLimit;
        uint256 premiumRate;
        uint256 trustScore;
        bool active;
    }
    struct CoverageRequest {
        uint256 requestId;
        uint256 lossAmount;
        uint256 requestedCoverage;
        uint256 approvedCoverage;
        bytes lossProof;
        RequestStatus status;
        uint256 timestamp;
    }
    enum RequestStatus {
        PENDING,
        APPROVED,
        PAID_OUT,
        REJECTED,
        EXPIRED
    }
    mapping(uint256 => ReinsuranceProvider) public providers;
    mapping(uint256 => CoverageRequest) public coverageRequests;
    mapping(address => uint256) public providerIds;
    uint256 public nextProviderId;
    uint256 public nextRequestId;
    uint256 public totalAllocatedCapital;
    uint256 public totalCoverageLimit;
    uint256 public coverageActivationThreshold;
    uint256 public premiumReserve;
    address public stablecoin;
    event CoverageRequested(
        uint256 requestId,
        uint256 lossAmount,
        uint256 requestedCoverage
    );
    event CoverageApproved(uint256 requestId, uint256 approvedAmount);
    event CoveragePaid(uint256 requestId, uint256 paidAmount);
    event ProviderAdded(
        uint256 providerId,
        address provider,
        uint256 coverageLimit
    );
    event ProviderRemoved(uint256 providerId);
    event PremiumCollected(uint256 amount, uint256 fromRequestId);
    function initialize(
        address _stablecoin,
        uint256 _activationThreshold
    ) public initializer {
        __Ownable_init(msg.sender);
        stablecoin = _stablecoin;
        coverageActivationThreshold = _activationThreshold;
    }
    function requestCoverage(
        uint256 lossAmount,
        uint256 totalPoolValue,
        bytes calldata lossProof
    ) external onlyOwner returns (uint256) {
        require(lossAmount > 0, "No loss to cover");
        uint256 lossPercentage = (lossAmount * 10000) / totalPoolValue;
        require(
            lossPercentage >= coverageActivationThreshold,
            "Loss below threshold"
        );
        uint256 requestId = nextRequestId++;
        uint256 requestedCoverage = _calculateCoverageAmount(
            lossAmount,
            totalPoolValue
        );
        coverageRequests[requestId] = CoverageRequest({
            requestId: requestId,
            lossAmount: lossAmount,
            requestedCoverage: requestedCoverage,
            approvedCoverage: 0,
            lossProof: lossProof,
            status: RequestStatus.PENDING,
            timestamp: block.timestamp
        });
        emit CoverageRequested(requestId, lossAmount, requestedCoverage);
        return requestId;
    }
    function processCoverageRequest(uint256 requestId) external onlyOwner {
        CoverageRequest storage request = coverageRequests[requestId];
        require(request.status == RequestStatus.PENDING, "Request processed");
        require(
            block.timestamp <= request.timestamp + 7 days,
            "Request expired"
        );
        bool proofValid = _verifyLossProof(
            request.lossProof,
            request.lossAmount
        );
        require(proofValid, "Invalid proof");
        uint256 approvedCoverage = _calculateApprovedCoverage(
            request.requestedCoverage
        );
        request.approvedCoverage = approvedCoverage;
        request.status = RequestStatus.APPROVED;
        emit CoverageApproved(requestId, approvedCoverage);
        _executePayout(requestId, approvedCoverage);
    }
    function addReinsuranceProvider(
        address provider,
        uint256 coverageLimit,
        uint256 premiumRate,
        uint256 initialCapital
    ) external onlyOwner returns (uint256) {
        require(provider != address(0), "Invalid provider");
        require(coverageLimit > 0, "Invalid limit");
        require(premiumRate <= 500, "Rate too high");
        uint256 providerId = nextProviderId++;
        providers[providerId] = ReinsuranceProvider({
            providerAddress: provider,
            allocatedCapital: initialCapital,
            coverageLimit: coverageLimit,
            premiumRate: premiumRate,
            trustScore: 10000,
            active: true
        });
        providerIds[provider] = providerId;
        totalAllocatedCapital += initialCapital;
        totalCoverageLimit += coverageLimit;
        if (initialCapital > 0) {
            IERC20(stablecoin).safeTransferFrom(
                provider,
                address(this),
                initialCapital
            );
        }
        emit ProviderAdded(providerId, provider, coverageLimit);
        return providerId;
    }
    function provideAdditionalCapital(
        uint256 providerId,
        uint256 amount
    ) external {
        ReinsuranceProvider storage provider = providers[providerId];
        require(provider.active, "Provider not active");
        require(msg.sender == provider.providerAddress, "Only provider");
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), amount);
        provider.allocatedCapital += amount;
        totalAllocatedCapital += amount;
    }
    function _calculateCoverageAmount(
        uint256 lossAmount,
        uint256 totalPoolValue
    ) internal view returns (uint256) {
        uint256 coverageByLoss = (lossAmount * 8000) / 10000;
        uint256 coverageByLimit = (totalCoverageLimit * 9000) / 10000;
        return MathUtils.min(coverageByLoss, coverageByLimit);
    }
    function _calculateApprovedCoverage(
        uint256 requestedCoverage
    ) internal view returns (uint256) {
        return MathUtils.min(requestedCoverage, totalAllocatedCapital);
    }

    function _executePayout(uint256 requestId, uint256 amount) internal {
        CoverageRequest storage request = coverageRequests[requestId];
        uint256 remainingAmount = amount;

        // Calculate total premiums that should be collected from insurance pool
        uint256 totalPremiums = _calculateTotalPremiums(amount);

        // Insurance pool pays premium to reinsurance
        IERC20(stablecoin).safeTransferFrom(owner(), address(this), totalPremiums);
        premiumReserve += totalPremiums;

        // Execute payout from provider capital
        for (uint256 i = 1; i <= nextProviderId; i++) {
            if (!providers[i].active || providers[i].allocatedCapital == 0)
                continue;

            uint256 providerShare = (amount * providers[i].allocatedCapital) /
                totalAllocatedCapital;
            providerShare = MathUtils.min(providerShare, remainingAmount);

            // Deduct payout from provider capital only (no double deduction)
            providers[i].allocatedCapital -= providerShare;
            totalAllocatedCapital -= providerShare;
            remainingAmount -= providerShare;

            if (remainingAmount == 0) break;
        }

        // Transfer net payout to pool
        IERC20(stablecoin).safeTransfer(owner(), amount);
        request.status = RequestStatus.PAID_OUT;

        emit CoveragePaid(requestId, amount);
    }

    function _calculateTotalPremiums(uint256 coverageAmount) internal view returns (uint256 totalPremium) {
        totalPremium = 0;
        for (uint256 i = 1; i <= nextProviderId; i++) {
            if (!providers[i].active || providers[i].allocatedCapital == 0)
                continue;

            uint256 providerPremium = (coverageAmount * providers[i].premiumRate) / 10000;
            totalPremium += providerPremium;
        }
    }

    function _collectPremiums(
        uint256 requestId,
        uint256 coverageAmount
    ) internal returns (uint256 totalPremium) {
        totalPremium = 0;

        for (uint256 i = 1; i <= nextProviderId; i++) {
            if (!providers[i].active || providers[i].allocatedCapital == 0)
                continue;

            uint256 providerPremium = (coverageAmount *
                providers[i].premiumRate) / 10000;

            // Premium capped at available capital
            uint256 collectedPremium = MathUtils.min(
                providerPremium,
                providers[i].allocatedCapital
            );

            providers[i].allocatedCapital -= collectedPremium;
            totalAllocatedCapital -= collectedPremium;
            totalPremium += collectedPremium;
        }

        premiumReserve += totalPremium;
        emit PremiumCollected(totalPremium, requestId);

        return totalPremium;
    }
    function _verifyLossProof(
        bytes memory proof,
        uint256 lossAmount
    ) internal pure returns (bool) {
        return keccak256(proof) == keccak256(abi.encodePacked(lossAmount));
    }
}
