// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./StakeRegistry.sol";
import "./IndexRegistry.sol";
import "./BLSApkRegistry.sol";

contract RegistryCoordinator is Ownable, ReentrancyGuard {
    StakeRegistry public stakeRegistry;
    IndexRegistry public indexRegistry;
    BLSApkRegistry public blsApkRegistry;

    // Events
    event OperatorRegistered(address indexed operator, string ip);
    event OperatorDeregistered(address indexed operator);
    event OperatorUpdated(address indexed operator, string ip);

    constructor(
        address _stakeRegistry,
        address _indexRegistry,
        address _blsApkRegistry,
        address _owner
    ) Ownable(_owner) {
        stakeRegistry = StakeRegistry(_stakeRegistry);
        indexRegistry = IndexRegistry(_indexRegistry);
        blsApkRegistry = BLSApkRegistry(_blsApkRegistry);
    }

    // Register a new operator with stake, index, and BLS public key
    function registerOperator(string memory ip, bytes memory blsPubKey) external payable nonReentrant {
        require(bytes(ip).length > 0, "IP address required");
        require(msg.value >= 1 ether, "Minimum stake is 1 ETH");
        require(!stakeRegistry.isOperator(msg.sender), "Operator already registered");

        // Register in each registry
        stakeRegistry.registerOperator{value: msg.value}(msg.sender);
        indexRegistry.registerOperator(msg.sender);
        blsApkRegistry.registerOperator(msg.sender, blsPubKey);

        emit OperatorRegistered(msg.sender, ip);
    }

    // Deregister an operator
    function deregisterOperator() external nonReentrant {
        require(stakeRegistry.isOperator(msg.sender), "Operator not registered");

        // Deregister from each registry
        stakeRegistry.deregisterOperator(msg.sender);
        indexRegistry.deregisterOperator(msg.sender);
        blsApkRegistry.deregisterOperator(msg.sender);

        emit OperatorDeregistered(msg.sender);
    }

    // Update operator details (e.g., IP address)
    function updateOperator(string memory ip) external nonReentrant {
        require(stakeRegistry.isOperator(msg.sender), "Operator not registered");
        require(bytes(ip).length > 0, "IP address required");

        emit OperatorUpdated(msg.sender, ip);
    }

    // Get all registered operators
    function getOperators() external view returns (address[] memory) {
        return indexRegistry.getOperators();
    }

    // Get operator IP (stored off-chain or in a mapping if needed)
    function getOperatorIP(address operator) external view returns (string memory) {
        require(stakeRegistry.isOperator(operator), "Operator not registered");
        // Note: IP storage moved to EmberManager for compatibility
        return "";
    }
}