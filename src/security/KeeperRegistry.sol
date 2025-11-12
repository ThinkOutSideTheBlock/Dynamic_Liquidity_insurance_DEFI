// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title KeeperRegistry
 * @notice Centralized registry for authorized keepers across the protocol
 * @dev Use this to manage keeper permissions instead of per-contract mappings
 */
contract KeeperRegistry is OwnableUpgradeable, UUPSUpgradeable {
    mapping(address => bool) public authorizedKeepers;
    mapping(address => uint256) public keeperSince;
    mapping(address => uint256) public keeperTasksExecuted;

    event KeeperAdded(address indexed keeper);
    event KeeperRemoved(address indexed keeper);
    event KeeperTaskExecuted(address indexed keeper, bytes32 taskId);

    function initialize() public initializer {
        __Ownable_init(msg.sender);
    }

    /**
     * @dev Add a new authorized keeper
     */
    function addKeeper(address keeper) external onlyOwner {
        require(keeper != address(0), "Invalid keeper address");
        require(!authorizedKeepers[keeper], "Keeper already authorized");

        authorizedKeepers[keeper] = true;
        keeperSince[keeper] = block.timestamp;

        emit KeeperAdded(keeper);
    }

    /**
     * @dev Remove an authorized keeper
     */
    function removeKeeper(address keeper) external onlyOwner {
        require(authorizedKeepers[keeper], "Keeper not authorized");

        authorizedKeepers[keeper] = false;

        emit KeeperRemoved(keeper);
    }

    /**
     * @dev Batch add multiple keepers (gas efficient)
     */
    function addKeepers(address[] calldata keepers) external onlyOwner {
        for (uint256 i = 0; i < keepers.length; i++) {
            if (!authorizedKeepers[keepers[i]] && keepers[i] != address(0)) {
                authorizedKeepers[keepers[i]] = true;
                keeperSince[keepers[i]] = block.timestamp;
                emit KeeperAdded(keepers[i]);
            }
        }
    }

    /**
     * @dev Check if address is authorized keeper
     */
    function isAuthorizedKeeper(address keeper) external view returns (bool) {
        return authorizedKeepers[keeper];
    }

    /**
     * @dev Record keeper task execution (called by modules)
     */
    function recordKeeperTask(address keeper, bytes32 taskId) external {
        require(authorizedKeepers[keeper], "Keeper not authorized");
        keeperTasksExecuted[keeper]++;
        emit KeeperTaskExecuted(keeper, taskId);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
