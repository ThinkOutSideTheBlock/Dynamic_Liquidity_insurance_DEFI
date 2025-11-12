pragma solidity ^0.8.19;
interface ILiquidationPurchase {
    struct PurchaseAttempt {
        bytes32 executionId;
        uint256 troveId;
        uint256 amount;
        address asset;
        uint256 targetPrice;
        Status status;
        uint256 timestamp;
    }
    enum Status {
        PENDING,
        EXECUTING,
        COMPLETED,
        CANCELLED,
        FAILED
    }
    function attemptPurchase(uint256 troveId, bytes32 commitment) external returns (bytes32);
    function finalizePurchase(
        bytes32 executionId,
        bytes calldata reveal,
        bytes32 salt
    ) external;
    function cancelPurchase(bytes32 executionId) external;
    function previewPurchase(
        uint256 troveId
    ) external view returns (uint256 cost, uint256 expectedCollateral);
    event PurchaseAttempted(
        bytes32 executionId,
        uint256 troveId,
        address asset,
        uint256 amount
    );
    event PurchaseFinalized(
        bytes32 executionId,
        uint256 profit,
        uint256 collateralAcquired
    );
    event PurchaseCancelled(bytes32 executionId, string reason);
}
