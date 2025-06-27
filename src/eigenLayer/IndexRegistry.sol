// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract IndexRegistry is Ownable, ReentrancyGuard {
    address[] public operators;
    mapping(address => uint256) public operatorIndex;
    address public lastSelectedOperator;

    event OperatorIndexed(address indexed operator, uint256 index);
    event OperatorRemoved(address indexed operator);
    event OperatorSelected(address indexed operator);

    constructor(address _owner) Ownable(_owner) {}

    function registerOperator(address operator) external nonReentrant {
        require(msg.sender == owner(), "Only coordinator");
        require(operatorIndex[operator] == 0 && !isOperator(operator), "Operator already indexed");

        operators.push(operator);
        operatorIndex[operator] = operators.length - 1;

        emit OperatorIndexed(operator, operators.length - 1);
    }

    function deregisterOperator(address operator) external nonReentrant {
        require(msg.sender == owner(), "Only coordinator");
        require(isOperator(operator), "Operator not indexed");

        uint256 index = operatorIndex[operator];
        operators[index] = operators[operators.length - 1];
        operatorIndex[operators[index]] = index;
        operators.pop();
        delete operatorIndex[operator];

        emit OperatorRemoved(operator);
    }

    function getOperators() external view returns (address[] memory) {
        return operators;
    }

    function isOperator(address operator) public view returns (bool) {
        return operatorIndex[operator] != 0 || (operators.length > 0 && operators[operatorIndex[operator]] == operator);
    }

    function getLastSelectedOperator() external view returns (address) {
        return lastSelectedOperator;
    }
}