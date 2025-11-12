pragma solidity ^0.8.19;
library Constants {
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 public constant PRICE_DECIMALS = 1e8;
    uint256 public constant DEFAULT_BASE_RATE = 200;
    uint256 public constant DEFAULT_HYSTERESIS = 500;
    uint256 public constant DEFAULT_MAX_EXPOSURE = 2000;
    uint256 public constant DEFAULT_COOLDOWN = 1 days;
    uint256 public constant DEFAULT_JUNIOR_THRESHOLD = 8000;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    uint256 public constant EMERGENCY_SHUTDOWN_DELAY = 2 days;
}