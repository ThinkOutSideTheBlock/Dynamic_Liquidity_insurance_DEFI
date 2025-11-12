pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../interfaces/IAave.sol";
import "../libraries/Constants.sol";
contract AaveV3YieldManager is OwnableUpgradeable {
    using SafeERC20 for IERC20;
    IPool public aavePool;
    IAaveOracle public aaveOracle;
    mapping(address => address) public aTokenMapping;
    mapping(address => uint256) public totalSupplied;
    event AaveDeposit(
        address indexed asset,
        uint256 amount,
        address indexed aToken
    );
    event AaveWithdraw(address indexed asset, uint256 amount, uint256 yield);
    function initialize(
        address _aavePool,
        address _aaveOracle
    ) public initializer {
        __Ownable_init(msg.sender);
        aavePool = IPool(_aavePool);
        aaveOracle = IAaveOracle(_aaveOracle);
        _setupAsset(Constants.USDC);
        _setupAsset(Constants.DAI);
    }
    function deposit(
        address asset,
        uint256 amount
    ) external onlyOwner returns (uint256) {
        require(aTokenMapping[asset] != address(0), "Asset not supported");
        uint256 initialATokenBalance = IERC20(aTokenMapping[asset]).balanceOf(
            address(this)
        );
        IERC20(asset).forceApprove(address(aavePool), amount);
        aavePool.supply(asset, amount, address(this), 0);
        totalSupplied[asset] += amount;
        emit AaveDeposit(asset, amount, aTokenMapping[asset]);
        return
            IERC20(aTokenMapping[asset]).balanceOf(address(this)) -
            initialATokenBalance;
    }
    function withdraw(
        address asset,
        uint256 amount
    ) external onlyOwner returns (uint256) {
        require(aTokenMapping[asset] != address(0), "Asset not supported");

        address aToken = aTokenMapping[asset];
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));
        require(aTokenBalance > 0, "No aTokens to withdraw");

        uint256 initialBalance = IERC20(asset).balanceOf(address(this));

        // Aave V3 automatically converts aTokens 1:1 to underlying + interest
        // Just withdraw the amount directly
        uint256 withdrawn = aavePool.withdraw(asset, amount, address(this));

        uint256 actualReceived = IERC20(asset).balanceOf(address(this)) -
            initialBalance;
        require(actualReceived >= amount, "Insufficient withdrawal");

        // Calculate yield
        uint256 yield = actualReceived > amount ? actualReceived - amount : 0;

        // Update tracking
        if (totalSupplied[asset] >= amount) {
            totalSupplied[asset] -= amount;
        } else {
            totalSupplied[asset] = 0;
        }

        // ADD THIS LINE:
        IERC20(asset).safeTransfer(msg.sender, actualReceived);

        emit AaveWithdraw(asset, actualReceived, yield);
        return actualReceived;
    }
    function getCurrentBalance(address asset) public view returns (uint256) {
        address aToken = aTokenMapping[asset];
        if (aToken == address(0)) return 0;
        return IERC20(aToken).balanceOf(address(this));
    }
    function _setupAsset(address asset) internal {
        address aToken = aavePool.getReserveData(asset).aTokenAddress;
        require(aToken != address(0), "Invalid aToken");
        aTokenMapping[asset] = aToken;
    }
}
