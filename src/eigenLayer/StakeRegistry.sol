// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract StakeRegistry is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    mapping(address => uint256) public operatorStake;
    mapping(address => bool) public isOperator;
    uint256 public constant MINIMUM_STAKE = 1 ether;

    event OperatorStaked(address indexed operator, uint256 amount);
    event OperatorUnstaked(address indexed operator, uint256 amount);

    constructor(address _owner) Ownable(_owner) {}

    function registerOperator(address operator) external payable nonReentrant {
        require(msg.sender == owner() || msg.sender == operator, "Unauthorized");
        require(!isOperator[operator], "Operator already registered");
        require(msg.value >= MINIMUM_STAKE, "Insufficient stake");

        isOperator[operator] = true;
        operatorStake[operator] = operatorStake[operator].add(msg.value);

        emit OperatorStaked(operator, msg.value);
    }

    function deregisterOperator(address operator) external nonReentrant {
        require(msg.sender == owner() || msg.sender == operator, "Unauthorized");
        require(isOperator[operator], "Operator not registered");

        uint256 stake = operatorStake[operator];
        operatorStake[operator] = 0;
        isOperator[operator] = false;

        (bool success, ) = operator.call{value: stake}("");
        require(success, "Stake refund failed");

        emit OperatorUnstaked(operator, stake);
    }

    function getOperatorStake(address operator) external view returns (uint256) {
        return operatorStake[operator];
    }
}