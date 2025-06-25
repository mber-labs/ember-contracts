// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./EmberLiquidityToken.sol";
import "./EmberLiquidityPool.sol";

interface IPriceFeed {
    function latestAnswer() external view returns (int256);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract EmberLoanManager is CCIPReceiver, VRFConsumerBaseV2, KeeperCompatibleInterface, Ownable {
    address[] public operators;
    mapping(address => uint256) public operatorStake;
    mapping(address => string) public operatorIPs;
    address public lastSelectedOperator;
    mapping(uint256 => Transaction) public transactions;
    uint256 public txCounter;

    mapping(uint256 => mapping(address => bool)) public approvals;
    mapping(string => address) public tokenRegistry;
    IPriceFeed public btcUsdPriceFeed;
    EmberLiquidityPool public liquidityPool;

    // Liquidation state
    mapping(uint256 => bool) public liquidationRequested;

    enum TxStatus { Pending, FundsBorrowed, FundsReturned, Rejected }

    struct Transaction {
        uint256 txId;
        string tokenSymbol;
        uint256 btcCollateralAmount;
        uint256 ltv;
        address receiver;
        TxStatus status;
        uint256 approvalCount;
        uint256 releaseTimestamp;
        uint64 destinationChainSelector;
        uint256 tokenAmount;
        uint256 maxLTV;
        bool liquidatable;
    }

    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error InvalidReceiverAddress();
    error ReturnedAmountTooLow();

    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) revert InvalidReceiverAddress();
        _;
    }

    IRouterClient private s_router;

    // Chainlink VRF variables
    VRFCoordinatorV2Interface COORDINATOR;
    uint64 public vrfSubscriptionId;
    bytes32 public vrfKeyHash;
    uint32 public vrfCallbackGasLimit = 100000;
    uint16 public vrfConfirmations = 3;
    uint32 public vrfNumWords = 1;

    event NewOperatorRegistered(address operatorAddress, string ip);
    event OperatorDeregistered(address operatorAddress);
    event OperatorSelected(address selectedOperator);
    event TokensTransferred(bytes32 indexed messageId, uint64 indexed destinationChainSelector, address receiver, address token, uint256 tokenAmount, address feeToken, uint256 fees);
    event LoanReturnedCrossChain(uint256 txId, uint256 amountReturned, address payer);
    event MessageFailed(bytes32 indexed messageId, bytes reason);
    event MessageRecovered(bytes32 indexed messageId);
    event LiquidationCheckPerformed(uint256[] liquidatableTxIds);
    event LoanMarkedForLiquidation(uint256 indexed txId);
    event LoanLiquidated(uint256 indexed txId, address indexed operator, uint256 usdcReceived);

    constructor(
        address _router,
        address _btcUsdPriceFeed,
        address _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash,
        address _liquidityPool
    ) CCIPReceiver(_router) VRFConsumerBaseV2(_vrfCoordinator) {
        s_router = IRouterClient(_router);
        btcUsdPriceFeed = IPriceFeed(_btcUsdPriceFeed);
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        vrfSubscriptionId = _subscriptionId;
        vrfKeyHash = _keyHash;
        liquidityPool = EmberLiquidityPool(_liquidityPool);
        _transferOwnership(msg.sender);
    }

    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256[] memory liquidatableTxIds = new uint256[](txCounter);
        uint256 count = 0;

        (, int256 btcPriceUsd, , uint256 updatedAt, ) = btcUsdPriceFeed.latestRoundData();
        if (btcPriceUsd <= 0 || block.timestamp - updatedAt > 1 hours) {
            return (false, bytes(""));
        }

        for (uint256 i = 0; i < txCounter; i++) {
            Transaction storage txn = transactions[i];
            if (txn.status == TxStatus.FundsBorrowed && !liquidationRequested[i]) {
                uint256 currentCollateralValue = txn.btcCollateralAmount * (uint256(btcPriceUsd)) / (1e8);
                uint256 currentLTV = txn.tokenAmount * (100) / (currentCollateralValue);
                if (currentLTV > txn.maxLTV) {
                    liquidatableTxIds[count] = i;
                    count++;
                }
            }
        }

        if (count > 0) {
            uint256[] memory result = new uint256[](count);
            for (uint256 j = 0; j < count; j++) {
                result[j] = liquidatableTxIds[j];
            }
            upkeepNeeded = true;
            performData = abi.encode(result);
        } else {
            upkeepNeeded = false;
            performData = bytes("");
        }

        return (upkeepNeeded, performData);
    }

    function performUpkeep(bytes calldata performData) external override {
        uint256[] memory liquidatableTxIds = abi.decode(performData, (uint256[]));

        for (uint256 i = 0; i < liquidatableTxIds.length; i++) {
            uint256 txId = liquidatableTxIds[i];
            Transaction storage txn = transactions[txId];
            if (txn.status == TxStatus.FundsBorrowed && !liquidationRequested[txId]) {
                (, int256 btcPriceUsd, , uint256 updatedAt, ) = btcUsdPriceFeed.latestRoundData();
                require(btcPriceUsd > 0, "Invalid BTC price");
                require(block.timestamp - updatedAt < 1 hours, "Stale price feed");
                uint256 currentCollateralValue = txn.btcCollateralAmount * (uint256(btcPriceUsd)) / (1e8);
                uint256 currentLTV = txn.tokenAmount * (100) / (currentCollateralValue);
                if (currentLTV > txn.maxLTV) {
                    txn.liquidatable = true;
                    liquidationRequested[txId] = true;
                    emit LoanMarkedForLiquidation(txId);
                }
            }
        }

        emit LiquidationCheckPerformed(liquidatableTxIds);
    }

    function liquidateLoan(uint256 txId) external {
        require(msg.sender == lastSelectedOperator, "Not authorized");
        Transaction storage txn = transactions[txId];
        require(txn.status == TxStatus.FundsBorrowed, "Loan not active");
        require(txn.liquidatable, "Loan not liquidatable");
        require(keccak256(bytes(txn.tokenSymbol)) == keccak256(bytes("USDC")), "Only USDC loans supported");

        uint256 usdcReceived = txn.tokenAmount;
        require(IERC20(liquidityPool.usdcToken()).transferFrom(msg.sender, address(liquidityPool), usdcReceived), "USDC transfer failed");

        liquidityPool.addLiquidityFromLiquidation(usdcReceived);

        txn.status = TxStatus.FundsReturned;
        liquidationRequested[txId] = false;
        txn.liquidatable = false;

        emit LoanLiquidated(txId, msg.sender, usdcReceived);
    }

    function requestOperatorSelection() external returns (uint256 requestId) {
        require(operators.length > 0, "No operators registered");
        requestId = COORDINATOR.requestRandomWords(
            vrfKeyHash,
            vrfSubscriptionId,
            vrfConfirmations,
            vrfCallbackGasLimit,
            vrfNumWords
        );
    }

    function fulfillRandomWords(uint256, uint256[] memory randomWords) internal override {
        uint256 index = randomWords[0] % operators.length;
        lastSelectedOperator = operators[index];
        emit OperatorSelected(lastSelectedOperator);
    }

    function transferTokensPayNative(uint64 _destinationChainSelector, address _receiver, address _token, uint256 _amount) internal validateReceiver(_receiver) returns (bytes32 messageId) {
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(_receiver, _token, _amount, address(0));

        uint256 fees = s_router.getFee(_destinationChainSelector, evm2AnyMessage);

        if (fees > address(this).balance)
            revert NotEnoughBalance(address(this).balance, fees);

        IERC20(_token).approve(address(s_router), _amount);

        messageId = s_router.ccipSend{value: fees}(_destinationChainSelector, evm2AnyMessage);

        emit TokensTransferred(messageId, _destinationChainSelector, _receiver, _token, _amount, address(0), fees);
        return messageId;
    }

    function _buildCCIPMessage(address _receiver, address _token, uint256 _amount, address _feeTokenAddress) private pure returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: _token, amount: _amount});

        return Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: "",
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 0, allowOutOfOrderExecution: true})),
            feeToken: _feeTokenAddress
        });
    }

    receive() external payable {}

    function createTransaction(string calldata tokenSymbol, uint256 btcCollateralAmount, uint256 ltv, address receiver, uint64 destinationChainSelector, uint256 maxLTV) external {
        require(msg.sender == lastSelectedOperator, "Not authorized");
        require(maxLTV >= ltv && maxLTV <= 100, "Invalid maxLTV");

        transactions[txCounter] = Transaction({
            txId: txCounter,
            tokenSymbol: tokenSymbol,
            btcCollateralAmount: btcCollateralAmount,
            ltv: ltv,
            receiver: receiver,
            status: TxStatus.Pending,
            approvalCount: 0,
            releaseTimestamp: block.timestamp,
            destinationChainSelector: destinationChainSelector,
            tokenAmount: 0,
            maxLTV: maxLTV,
            liquidatable: false
        });

        txCounter++;
    }

    function approveTransaction(uint256 txId) external {
        require(txId < txCounter, "Invalid txId");
        require(!approvals[txId][msg.sender], "Already approved");

        approvals[txId][msg.sender] = true;
        transactions[txId].approvalCount++;

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
        require(tokenAddr == liquidityPool.usdcToken(), "Only USDC loans supported");

        (, int256 btcPriceUsd, , uint256 updatedAt, ) = btcUsdPriceFeed.latestRoundData();
        require(btcPriceUsd > 0, "Invalid BTC price");
        require(block.timestamp - updatedAt < 1 hours, "Stale price feed");

        uint256 usdValue = txn.btcCollateralAmount * (uint256(btcPriceUsd)) / (1e8);
        uint256 tokenAmount = usdValue * (txn.ltv) / (100);
        txn.tokenAmount = tokenAmount;

        liquidityPool.withdrawLiquidity(tokenAddr, tokenAmount, txn.receiver, txn.destinationChainSelector);
    }

    function ccipReceive(Client.Any2EVMMessage calldata message) external override onlyRouter {
        try this.processMessage(message) {
        } catch {
            revert("Failed to process message");
        }
    }

    function processMessage(Client.Any2EVMMessage calldata message) external {
        require(msg.sender == address(this), "Only self can call processMessage");
        _ccipReceive(message);
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        (uint256 txId, uint256 amountReturned, address payer) = abi.decode(message.data, (uint256, uint256, address));

        Transaction storage txn = transactions[txId];
        require(txn.status == TxStatus.FundsBorrowed, "Loan not active");

        address tokenAddr = tokenRegistry[txn.tokenSymbol];
        require(tokenAddr != address(0), "Token not registered");

        uint256 daysPassed = (block.timestamp - txn.releaseTimestamp) / 1 days;
        uint256 interest = (txn.tokenAmount * 5 * daysPassed) / (100 * 365);
        uint256 totalOwed = txn.tokenAmount + interest;

        if (amountReturned < totalOwed) revert ReturnedAmountTooLow();

        txn.status = TxStatus.FundsReturned;
        emit LoanReturnedCrossChain(txId, amountReturned, payer);
    }

    function returnFunds(uint256 txId, uint256 returnedAmount) external {
        Transaction storage txn = transactions[txId];
        require(txn.status == TxStatus.FundsBorrowed, "Funds not borrowed");

        address tokenAddr = tokenRegistry[txn.tokenSymbol];
        require(tokenAddr != address(0), "Token not registered");

        uint256 daysPassed = (block.timestamp - txn.releaseTimestamp) / 1 days;
        uint256 interest = (txn.tokenAmount * 5 * daysPassed) / (100 * 365);
        uint256 totalOwed = txn.tokenAmount + interest;

        require(IERC20(tokenAddr).transferFrom(msg.sender, address(liquidityPool), returnedAmount), "Transfer failed");
        require(returnedAmount >= totalOwed, "Insufficient amount with interest");

        liquidityPool.addLiquidityFromRepayment(tokenAddr, returnedAmount);

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

    function registerToken(string calldata symbol, address tokenAddress) external onlyOwner {
        tokenRegistry[symbol] = tokenAddress;
    }

    function deregisterOperator() external returns (bool) {
        for (uint i = 0; i < operators.length; i++) {
            if (operators[i] == msg.sender) {
                operators[i] = operators[operators.length - 1];
                operators.pop();

                uint256 amount = operatorStake[msg.sender];
                operatorStake[msg.sender] = 0;
                delete operatorIPs[msg.sender];

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