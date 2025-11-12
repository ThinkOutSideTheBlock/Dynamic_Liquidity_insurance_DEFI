pragma solidity ^0.8.19;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IUniswapV3.sol";
import "../libraries/Constants.sol";
import "../libraries/MathUtils.sol";
import "../libraries/Types.sol";
contract UniswapV3DexManager is OwnableUpgradeable {
    using SafeERC20 for IERC20;
    ISwapRouter public swapRouter;
    IQuoter public quoter;

    function initialize(
        address _swapRouter,
        address _quoter
    ) public initializer {
        __Ownable_init(msg.sender);
        swapRouter = ISwapRouter(_swapRouter);
        quoter = IQuoter(_quoter);
    }
    function executeSwap(
        SwapParams memory params
    ) external onlyOwner returns (uint256 amountOut) {
        IERC20(params.tokenIn).forceApprove(
            address(swapRouter),
            params.amountIn
        );
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: params.tokenIn,
                tokenOut: params.tokenOut,
                fee: params.feeTier,
                recipient: address(this),
                deadline: block.timestamp + 300,
                amountIn: params.amountIn,
                amountOutMinimum: params.amountOutMinimum,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            });
        amountOut = swapRouter.exactInputSingle(swapParams);
    }
    function executeChunkedSwap(
        SwapParams memory params,
        uint256 chunkSize,
        uint256 maxSlippageBps
    ) external onlyOwner returns (uint256 totalOut) {
        require(chunkSize > 0, "Invalid chunk size");
        require(maxSlippageBps <= 1000, "Slippage too high");

        uint256 remaining = params.amountIn;
        totalOut = 0;

        while (remaining > 0) {
            uint256 chunk = MathUtils.min(chunkSize, remaining);

            // Get quote for this chunk
            uint256 quotedOut = quoter.quoteExactInputSingle(
                params.tokenIn,
                params.tokenOut,
                params.feeTier,
                chunk,
                0
            );

            uint256 minOut = (quotedOut *
                (Constants.BPS_DENOMINATOR - maxSlippageBps)) /
                Constants.BPS_DENOMINATOR;

            // Execute swap directly (refactor to internal)
            IERC20(params.tokenIn).forceApprove(address(swapRouter), chunk);

            ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter
                .ExactInputSingleParams({
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    fee: params.feeTier,
                    recipient: address(this),
                    deadline: block.timestamp + 300,
                    amountIn: chunk,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                });

            uint256 amountOut = swapRouter.exactInputSingle(swapParams);
            totalOut += amountOut;
            remaining -= chunk;
        }
    }
}
