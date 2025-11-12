// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title MultiSourceOracle
 * @notice Production-grade oracle with Chainlink + Chronicle + API3 fallbacks
 * @dev Implements TWAP protection and deviation bounds
 */
contract MultiSourceOracle is OwnableUpgradeable {
    using ECDSA for bytes32;

    struct OracleSource {
        OracleType sourceType;
        address feedAddress;
        uint32 heartbeat; // Max staleness in seconds
        uint16 weight; // Basis points (out of 10000)
        bool active;
    }

    enum OracleType {
        CHAINLINK,
        CHRONICLE,
        API3,
        SIGNED_OFFCHAIN
    }

    struct PriceData {
        uint256 price;
        uint256 timestamp;
        uint256 confidence; // 0-10000 bps
        uint256 roundId;
    }

    struct TWAPState {
        uint256 cumulativePrice;
        uint256 lastUpdate;
        uint256 windowSize;
    }

    // Asset => Source Index => OracleSource
    mapping(address => mapping(uint256 => OracleSource)) public assetSources;
    mapping(address => uint256) public sourceCount;

    // TWAP tracking (prevents flash loan manipulation)
    mapping(address => TWAPState) public twapState;

    // Circuit breakers
    mapping(address => uint256) public maxDeviationBps; // e.g., 500 = 5%
    mapping(address => uint256) public minConfidenceBps; // e.g., 9500 = 95%

    // Security
    mapping(address => bool) public authorizedUpdaters;
    mapping(bytes32 => bool) public usedSignatures;

    uint256 public constant BPS = 10000;
    uint256 public constant TWAP_WINDOW = 30 minutes;

    event PriceUpdated(
        address indexed asset,
        uint256 price,
        uint256 confidence
    );
    event CircuitBreakerTriggered(address indexed asset, uint256 deviation);
    event SourceAdded(address indexed asset, OracleType sourceType);

    function initialize() public initializer {
        __Ownable_init(msg.sender);
    }

    /**
     * @notice Get price with multi-source validation
     * @dev Reverts if confidence < threshold or deviation > max
     */
    function getPrice(address asset) external returns (PriceData memory) {
        require(sourceCount[asset] > 0, "No sources configured");

        uint256 weightedPrice = 0;
        uint256 totalWeight = 0;
        uint256 validSources = 0;
        uint256 minPrice = type(uint256).max;
        uint256 maxPrice = 0;

        // Aggregate from all sources
        for (uint256 i = 0; i < sourceCount[asset]; i++) {
            OracleSource memory source = assetSources[asset][i];
            if (!source.active) continue;

            (uint256 price, uint256 timestamp, bool valid) = _fetchPrice(
                asset,
                source
            );

            if (!valid || block.timestamp > timestamp + source.heartbeat) {
                continue; // Skip stale/invalid
            }

            weightedPrice += price * source.weight;
            totalWeight += source.weight;
            validSources++;

            if (price < minPrice) minPrice = price;
            if (price > maxPrice) maxPrice = price;
        }

        require(validSources >= 2, "Insufficient valid sources");
        require(totalWeight > 0, "No valid weights");

        uint256 finalPrice = weightedPrice / totalWeight;

        // Check deviation
        uint256 deviation = maxPrice > minPrice
            ? ((maxPrice - minPrice) * BPS) / finalPrice
            : 0;

        require(
            deviation <= maxDeviationBps[asset],
            "Price deviation too high"
        );

        // Calculate confidence
        uint256 confidence = (validSources * BPS) / sourceCount[asset];
        require(confidence >= minConfidenceBps[asset], "Low confidence");

        // Update TWAP
        _updateTWAP(asset, finalPrice);

        return
            PriceData({
                price: finalPrice,
                timestamp: block.timestamp,
                confidence: confidence,
                roundId: block.number
            });
    }

    /**
     * @notice Get TWAP price (manipulation-resistant)
     */
    function getTWAPPrice(address asset) external view returns (uint256) {
        TWAPState memory state = twapState[asset];
        require(state.lastUpdate > 0, "TWAP not initialized");

        uint256 elapsed = block.timestamp - state.lastUpdate;
        if (elapsed > state.windowSize) {
            elapsed = state.windowSize; // Cap at window
        }

        return state.cumulativePrice / elapsed;
    }

    /**
     * @notice Add Chainlink source
     */
    function addChainlinkSource(
        address asset,
        address feedAddress,
        uint32 heartbeat,
        uint16 weight
    ) external onlyOwner {
        uint256 index = sourceCount[asset]++;
        assetSources[asset][index] = OracleSource({
            sourceType: OracleType.CHAINLINK,
            feedAddress: feedAddress,
            heartbeat: heartbeat,
            weight: weight,
            active: true
        });

        emit SourceAdded(asset, OracleType.CHAINLINK);
    }

    /**
     * @notice Fetch price from specific source
     */
    function _fetchPrice(
        address asset,
        OracleSource memory source
    ) internal view returns (uint256 price, uint256 timestamp, bool valid) {
        if (source.sourceType == OracleType.CHAINLINK) {
            return _fetchChainlink(source.feedAddress);
        } else if (source.sourceType == OracleType.CHRONICLE) {
            return _fetchChronicle(source.feedAddress);
        } else if (source.sourceType == OracleType.API3) {
            return _fetchAPI3(source.feedAddress);
        }

        return (0, 0, false);
    }

    /**
     * @notice Fetch from Chainlink with staleness check
     */
    function _fetchChainlink(
        address feed
    ) internal view returns (uint256, uint256, bool) {
        try AggregatorV3Interface(feed).latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 /* answeredInRound */
        ) {
            if (roundId == 0 || answer <= 0) {
                return (0, 0, false);
            }

            return (uint256(answer), updatedAt, true);
        } catch {
            return (0, 0, false);
        }
    }

    /**
     * @notice Fetch from Chronicle (Maker oracles)
     */
    function _fetchChronicle(
        address feed
    ) internal view returns (uint256, uint256, bool) {
        // Chronicle uses read() interface
        try IChronicle(feed).read() returns (uint256 value) {
            return (value, block.timestamp, true);
        } catch {
            return (0, 0, false);
        }
    }

    /**
     * @notice Fetch from API3
     */
    function _fetchAPI3(
        address dataFeed
    ) internal view returns (uint256, uint256, bool) {
        try IAPI3(dataFeed).read() returns (int224 value, uint32 timestamp) {
            if (value <= 0) {
                return (0, 0, false);
            }
            return (uint256(int256(value)), uint256(timestamp), true);
        } catch {
            return (0, 0, false);
        }
    }

    /**
     * @notice Update TWAP state
     */
    function _updateTWAP(address asset, uint256 price) internal {
        TWAPState storage state = twapState[asset];

        if (state.lastUpdate == 0) {
            // Initialize
            state.cumulativePrice = price;
            state.lastUpdate = block.timestamp;
            state.windowSize = TWAP_WINDOW;
        } else {
            uint256 elapsed = block.timestamp - state.lastUpdate;
            state.cumulativePrice += price * elapsed;

            // Keep window rolling
            if (elapsed > state.windowSize) {
                state.cumulativePrice = price * state.windowSize;
            }

            state.lastUpdate = block.timestamp;
        }
    }

    /**
     * @notice Emergency circuit breaker
     */
    function pauseAsset(address asset) external onlyOwner {
        for (uint256 i = 0; i < sourceCount[asset]; i++) {
            assetSources[asset][i].active = false;
        }
    }

    /**
     * @notice Configure deviation bounds
     */
    function setDeviationBounds(
        address asset,
        uint256 maxDeviation,
        uint256 minConfidence
    ) external onlyOwner {
        require(maxDeviation <= 2000, "Max deviation too high"); // 20%
        require(minConfidence >= 8000, "Min confidence too low"); // 80%

        maxDeviationBps[asset] = maxDeviation;
        minConfidenceBps[asset] = minConfidence;
    }
}

// Interfaces for external oracles
interface IChronicle {
    function read() external view returns (uint256);
}

interface IAPI3 {
    function read() external view returns (int224 value, uint32 timestamp);
}
