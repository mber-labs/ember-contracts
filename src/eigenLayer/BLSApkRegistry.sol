// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract BLSApkRegistry is Ownable, ReentrancyGuard {
    // Simplified BLS public key storage (G1 point: x, y coordinates)
    struct BLSPublicKey {
        bytes32 x;
        bytes32 y;
    }

    mapping(address => BLSPublicKey) public operatorBLSPubKey;
    mapping(address => bool) public isOperator;

    event OperatorBLSPubKeyRegistered(address indexed operator, bytes32 x, bytes32 y);
    event OperatorBLSPubKeyRemoved(address indexed operator);

    constructor(address _owner) Ownable(_owner) {}

    function registerOperator(address operator, bytes memory blsPubKey) external nonReentrant {
        require(msg.sender == owner(), "Only coordinator");
        require(!isOperator[operator], "Operator already registered");
        require(blsPubKey.length == 64, "Invalid BLS public key length");

        (bytes32 x, bytes32 y) = abi.decode(blsPubKey, (bytes32, bytes32));
        operatorBLSPubKey[operator] = BLSPublicKey(x, y);
        isOperator[operator] = true;

        emit OperatorBLSPubKeyRegistered(operator, x, y);
    }

    function deregisterOperator(address operator) external nonReentrant {
        require(msg.sender == owner(), "Only coordinator");
        require(isOperator[operator], "Operator not registered");

        delete operatorBLSPubKey[operator];
        isOperator[operator] = false;

        emit OperatorBLSPubKeyRemoved(operator);
    }

    function getBLSPublicKey(address operator) external view returns (bytes32 x, bytes32 y) {
        require(isOperator[operator], "Operator not registered");
        BLSPublicKey memory key = operatorBLSPubKey[operator];
        return (key.x, key.y);
    }
}