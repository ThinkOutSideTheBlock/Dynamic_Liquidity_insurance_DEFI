pragma solidity ^0.8.19;
interface IPool {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
    function getReserveData(
        address asset
    ) external view returns (ReserveData memory);
    struct ReserveData {
        address aTokenAddress;
    }
}
interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}
interface IFlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}
