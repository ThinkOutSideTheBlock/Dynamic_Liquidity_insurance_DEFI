// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library MathLib {
    uint256 constant PRECISION = 1e18;

    /**
     * @dev Babylonian method for square root
     */
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /**
     * @dev Natural logarithm using Taylor series approximation
     * ln(x) = 2 * [((x-1)/(x+1)) + 1/3*((x-1)/(x+1))^3 + 1/5*((x-1)/(x+1))^5 + ...]
     */
    function ln(uint256 x) internal pure returns (int256) {
        require(x > 0, "ln(0) undefined");

        if (x == PRECISION) return 0;

        bool negative = x < PRECISION;
        uint256 absX = negative ? (PRECISION * PRECISION) / x : x;

        uint256 y = ((absX - PRECISION) * PRECISION) / (absX + PRECISION);
        uint256 yPower = y;
        uint256 sum = y;

        // Taylor series with 10 terms for accuracy
        for (uint256 i = 3; i <= 21; i += 2) {
            yPower = (yPower * y * y) / (PRECISION * PRECISION);
            sum += yPower / i;
        }

        int256 result = int256(2 * sum);
        return negative ? -result : result;
    }

    /**
     * @dev Exponential function using Taylor series
     * e^x = 1 + x + x^2/2! + x^3/3! + ...
     */
    function exp(int256 x) internal pure returns (uint256) {
        bool negative = x < 0;
        uint256 absX = uint256(negative ? -x : x);

        uint256 sum = PRECISION;
        uint256 term = PRECISION;

        // Taylor series with 20 terms
        for (uint256 i = 1; i <= 20; i++) {
            term = (term * absX) / (i * PRECISION);
            sum += term;
            if (term < 100) break; // Convergence threshold
        }

        return negative ? (PRECISION * PRECISION) / sum : sum;
    }

    /**
     * @dev Box-Muller transform for normal distribution from uniform random
     * Converts uniform [0,1] to standard normal N(0,1)
     */
    function boxMuller(uint256 uniformRandom) internal pure returns (int256) {
        // Split random into two uniform values
        uint256 u1 = (uniformRandom % PRECISION) + 1; // Avoid log(0)
        uint256 u2 = ((uniformRandom / PRECISION) % PRECISION);

        // Box-Muller: z = sqrt(-2*ln(u1)) * cos(2*pi*u2)
        // Simplified: use sin approximation for efficiency
        uint256 logPart = uint256(-2 * ln(u1));
        uint256 sqrtPart = sqrt(logPart);

        // Approximate cos(2*pi*u2) with Chebyshev polynomial
        int256 angle = int256((u2 * 2 * 314159) / 100000); // 2*pi scaled
        int256 cosApprox = _fastCos(angle);

        return (int256(sqrtPart) * cosApprox) / int256(PRECISION);
    }

    /**
     * @dev Fast cosine approximation using polynomial
     */
    function _fastCos(int256 x) private pure returns (int256) {
        // Normalize to [-pi, pi]
        int256 pi = 3141592653589793238; // pi * 1e18
        x = x % (2 * pi);
        if (x > pi) x -= 2 * pi;
        if (x < -pi) x += 2 * pi;

        // cos(x) ≈ 1 - x^2/2 + x^4/24 (Taylor series)
        int256 x2 = (x * x) / int256(PRECISION);
        int256 x4 = (x2 * x2) / int256(PRECISION);

        return int256(PRECISION) - x2 / 2 + x4 / 24;
    }

    /**
     * @dev Bubble sort for price arrays (used in VaR calculation)
     */
    function bubbleSort(uint256[] memory arr) internal pure {
        uint256 n = arr.length;
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = 0; j < n - i - 1; j++) {
                if (arr[j] > arr[j + 1]) {
                    (arr[j], arr[j + 1]) = (arr[j + 1], arr[j]);
                }
            }
        }
    }

    /**
     * @dev Safe multiplication with overflow check
     */
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256) {
        require(denominator > 0, "Division by zero");
        
        // Handle edge cases
        if (a == 0 || b == 0) return 0;
        
        // For small numbers, use simple division
        if (a <= type(uint128).max && b <= type(uint128).max) {
            return (a * b) / denominator;
        }
        
        // For larger numbers, use safe algorithm
        // Based on Remco Bloemen's algorithm
        uint256 result = a / denominator;
        uint256 remainder = a % denominator;
        
        // Check if result * b would overflow
        if (result > 0 && type(uint256).max / result < b) {
            revert("Overflow in mulDiv");
        }
        
        result = result * b;
        
        // Add remainder contribution
        if (remainder > 0 && b > 0) {
            uint256 extraContribution = (remainder * b) / denominator;
            
            // Check for overflow in final addition
            if (type(uint256).max - result < extraContribution) {
                revert("Overflow in mulDiv");
            }
            
            result += extraContribution;
        }
        
        return result;
    }
}
