// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract EmberManager {
    address[] public operators;
    mapping(address => uint256) public operatorStake;
    mapping(address => string) public operatorIPs;
    address public lastSelectedOperator;
    mapping(uint256 => Transaction) public transactions;
    uint256 public txCounter;

    mapping(uint256 => mapping(address => bool)) public approvals;

    mapping(string => address) public tokenRegistry;

    enum TxStatus { Pending, FundsBorrowed, FundsReturned, Rejected }

    struct Transaction {
        uint256 txId;
        string tokenSymbol;
        uint256 tokenAmount;
        uint256 ltv;
        address receiver;
        TxStatus status;
        uint256 approvalCount;
        uint256 releaseTimestamp;
    }

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

    function createTransaction(
        string calldata tokenSymbol,
        uint256 tokenAmount,
        uint256 ltv,
        address receiver
    ) external {
        require(msg.sender == lastSelectedOperator, "Not authorized");

        transactions[txCounter] = Transaction({
            txId: txCounter,
            tokenSymbol: tokenSymbol,
            tokenAmount: tokenAmount,
            ltv: ltv,
            receiver: receiver,
            status: TxStatus.Pending,
            approvalCount: uint256(0),
            releaseTimestamp: block.timestamp
        });

        txCounter++;
    }

   function approveTransaction(uint256 txId) external {
        require(txId < txCounter, "Invalid txId");
        require(!approvals[txId][msg.sender], "Already approved");

        approvals[txId][msg.sender] = true;
        transactions[txId].approvalCount += 1;

        // ✅ If approvals > 2/3 of total operators, mark as Approved
        uint256 required = (operators.length * 2) / 3;

        if (transactions[txId].approvalCount > required) {
            transactions[txId].status = TxStatus.FundsBorrowed;
            releaseFunds(txId);
        }
    }

    function releaseFunds(uint256 txId) internal {
        Transaction storage txn = transactions[txId];

        require(txn.status == TxStatus.FundsBorrowed, "Tx not approved");

        address tokenAddr = tokenRegistry[txn.tokenSymbol];
        require(tokenAddr != address(0), "Token not registered");

        IERC20(tokenAddr).transfer(txn.receiver, txn.tokenAmount);
    }

    function returnFunds(uint256 txId, uint256 returnedAmount) external {
        Transaction storage txn = transactions[txId];
        require(txn.status == TxStatus.FundsBorrowed, "Funds not borrowed");

        address tokenAddr = tokenRegistry[txn.tokenSymbol];
        require(tokenAddr != address(0), "Token not registered");

        // ✅ Calculate number of days passed
        uint256 daysPassed = (block.timestamp - txn.releaseTimestamp) / 1 days;

        // ✅ Interest = principal * rate * time
        // 5% per year ≈ 0.0137% per day → 0.000137 ether per ether/day
        // interest = (principal * 5 * days) / (100 * 365)
        uint256 interest = (txn.tokenAmount * 5 * daysPassed) / (100 * 365);

        uint256 totalOwed = txn.tokenAmount + interest;

        // ✅ Take tokens from caller
        require(
            IERC20(tokenAddr).transferFrom(msg.sender, address(this), returnedAmount),
            "Transfer failed"
        );

        require(returnedAmount >= totalOwed, "Insufficient amount with interest");

        txn.status = TxStatus.FundsReturned;
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

    function registerToken(string calldata symbol, address tokenAddress) external {
        tokenRegistry[symbol] = tokenAddress;
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
