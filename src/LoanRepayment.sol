// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LoanRepayment {
    IRouterClient public router;
    address public emberManagerAddress;

    event LoanRepaymentSent(
        bytes32 messageId,
        uint64 destinationChainSelector,
        uint256 txId,
        uint256 amount,
        address payer,
        address token
    );

    constructor(address _router, address _emberManager) {
        router = IRouterClient(_router);
        emberManagerAddress = _emberManager;
    }

    /// @notice Repay a loan from this chain and notify the EmberManager on the source chain.
    /// @param destinationChainSelector CCIP chain selector for the source chain (e.g., Ethereum).
    /// @param token Address of the token used for repayment (must match original borrowed token).
    /// @param amount Total amount to repay (principal + interest).
    /// @param txId Transaction ID of the loan on the source chain.
    function repayLoanCrossChain(
        uint64 destinationChainSelector,
        address token,
        uint256 amount,
        uint256 txId
    ) external payable {
        require(amount > 0, "Amount must be > 0");

        // Transfer repayment tokens from the user to this contract
        require(
            IERC20(token).transferFrom(msg.sender, address(this), amount),
            "Token transfer failed"
        );

        // Approve router to spend tokens
        IERC20(token).approve(address(router), amount);

        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);

        tokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});

        // Encode the repayment data to be sent to EmberManager on source chain
        bytes memory payload = abi.encode(txId, amount, msg.sender);

        // Construct the CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(emberManagerAddress),
            data: payload,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: 200_000, // Estimate based on source chain processing
                    allowOutOfOrderExecution: false
                })
            ),
            feeToken: address(0) // Paying fees in native token (e.g., ETH, MATIC)
        });

        // Get required fee
        uint256 fee = router.getFee(destinationChainSelector, message);
        require(msg.value >= fee, "Insufficient native token for fees");

        // Send the message cross-chain
        bytes32 messageId = router.ccipSend{value: fee}(
            destinationChainSelector,
            message
        );

        emit LoanRepaymentSent(
            messageId,
            destinationChainSelector,
            txId,
            amount,
            msg.sender,
            token
        );
    }

    /// @notice Allows the contract to receive native tokens to cover CCIP fees.
    receive() external payable {}
}