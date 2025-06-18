// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract EmberManager {
    address[] public operators;
    mapping(address => uint256) public operatorStake;
    mapping(address => string) public operatorIPs;
    address public lastSelectedOperator;

    event NewOperatorRegistered(address operatorAddress, string ip);
    event OperatorDeregistered(address operatorAddress);
    event OperatorSelected(address selectedOperator);

    function selectOperator(uint256 randomNumber) external returns (address) {
        require(operators.length > 0, "No operators registered");
        uint256 index = randomNumber % operators.length;
        lastSelectedOperator = operators[index];
        emit OperatorSelected(lastSelectedOperator);
        return lastSelectedOperator;
    }   

    function registerOperator(string memory ip) public payable {
        require(msg.value >= 1 ether, "Operator required to stake exactly 1 ETH");
        require(bytes(ip).length > 0, "IP address required");
        require(operatorStake[msg.sender] == 0, "Already registered");

        operators.push(msg.sender);
        operatorStake[msg.sender] = msg.value;
        operatorIPs[msg.sender] = ip;

        emit NewOperatorRegistered(msg.sender, ip);
    }

    function deregisterOperator() external returns (bool) {
        for (uint i = 0; i < operators.length; i++) {
            if (operators[i] == msg.sender) {
                // Remove from operators array
                operators[i] = operators[operators.length - 1];
                operators.pop();

                // Clear mappings
                uint256 amount = operatorStake[msg.sender];
                operatorStake[msg.sender] = 0;
                delete operatorIPs[msg.sender];

                // Transfer back the stake
                (bool success, ) = msg.sender.call{value: amount}("");
                require(success, "ETH transfer failed");

                emit OperatorDeregistered(msg.sender);
                return true;
            }
        }
        return false;
    }

    function getAllOperators() external view returns (address[] memory) {
        return operators;
    }

    function getOperatorIP(address operator) external view returns (string memory) {
        return operatorIPs[operator];
    }

    function getLastSelectedOperator() external view returns (address) {
        return lastSelectedOperator;
    }
}
