pragma solidity ^0.8.19;

interface IInsurancePool {
    enum Tranche {
        SENIOR,
        JUNIOR
    }

    struct WithdrawRequest {
        address user;
        uint256 shares;
        Tranche tranche;
        uint256 timestamp;
        uint256 queueId;
        bool fulfilled;
        address stablecoin;
    }

    // Deposit and withdrawal functions
    function deposit(
        address stablecoin,
        uint256 amount,
        Tranche tranche
    ) external;
    function requestWithdraw(uint256 shares, Tranche tranche, address stablecoin) external;
    function fulfillWithdraw(uint256 queueId) external;
    function previewWithdraw(
        uint256 shares,
        Tranche tranche
    ) external view returns (uint256);

    // Liquidation module functions
    function reserveFunds(uint256 amount, address stablecoin) external;
    function triggerReinsurance(uint256 loss) external;

    // View functions - ADDED
    function liquidationModule() external view returns (address);
    function getUserShares(
        address user,
        Tranche tranche
    ) external view returns (uint256);
    function getTotalShares(Tranche tranche) external view returns (uint256);
    function getTotalValue(
        address stablecoin,
        Tranche tranche
    ) external view returns (uint256);
    function totalPool(address stablecoin) external view returns (uint256);
    function reservedFunds(address stablecoin) external view returns (uint256);

    // Events
    event Deposit(
        address indexed user,
        address stablecoin,
        uint256 amount,
        Tranche tranche,
        uint256 shares
    );
    event WithdrawRequested(
        address indexed user,
        uint256 queueId,
        uint256 shares,
        Tranche tranche
    );
    event WithdrawFulfilled(uint256 queueId, address user, uint256 amount);
    event ReinsuranceTriggered(uint256 loss, uint256 topUpAmount);
}
