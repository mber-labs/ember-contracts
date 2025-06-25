// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import "./EmberLiquidityToken.sol";

contract EmberLiquidityPool is Ownable {
    // Liquidity pool state
    EmberLiquidityToken public eltToken;
    address public usdcToken;
    uint256 public totalLiquidity;
    mapping(address => uint256) public liquidityBalance;

    IRouterClient private s_router;

    event LiquidityProvided(address indexed provider, uint256 usdcAmount, uint256 eltMinted);
    event LiquidityRemoved(address indexed provider, uint256 usdcAmount, uint256 eltBurned);
    event LiquidityWithdrawn(address indexed receiver, uint256 amount, uint64 destinationChainSelector);

    constructor(address _usdcToken, address _router) {
        usdcToken = _usdcToken;
        eltToken = new EmberLiquidityToken("Ember Liquidity Token", "ELT");
        s_router = IRouterClient(_router);
        _transferOwnership(msg.sender);
    }

    function provideLiquidity(uint256 usdcAmount) external {
        require(usdcAmount > 0, "Amount must be greater than zero");
        require(IERC20(usdcToken).transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");

        uint256 eltToMint;
        if (totalLiquidity == 0) {
            eltToMint = usdcAmount * (10**18) / (10**6);
        } else {
            eltToMint = usdcAmount * (eltToken.totalSupply()) / (totalLiquidity);
        }

        totalLiquidity = totalLiquidity + (usdcAmount);
        liquidityBalance[msg.sender] = liquidityBalance[msg.sender] + (usdcAmount);

        eltToken.mint(msg.sender, eltToMint);

        emit LiquidityProvided(msg.sender, usdcAmount, eltToMint);
    }

    function removeLiquidity(uint256 eltAmount) external {
        require(eltAmount > 0, "Amount must be greater than zero");
        require(eltToken.balanceOf(msg.sender) >= eltAmount, "Insufficient ELT balance");

        uint256 usdcAmount = eltAmount * (totalLiquidity) / (eltToken.totalSupply());
        require(usdcAmount <= totalLiquidity, "Insufficient liquidity");
        require(IERC20(usdcToken).balanceOf(address(this)) >= usdcAmount, "Contract has insufficient USDC");

        totalLiquidity = totalLiquidity - (usdcAmount);
        liquidityBalance[msg.sender] = liquidityBalance[msg.sender] - (usdcAmount);

        eltToken.burn(msg.sender, eltAmount);

        require(IERC20(usdcToken).transfer(msg.sender, usdcAmount), "USDC transfer failed");

        emit LiquidityRemoved(msg.sender, usdcAmount, eltAmount);
    }

    function withdrawLiquidity(address token, uint256 amount, address receiver, uint64 destinationChainSelector) external onlyOwner {
        require(token == usdcToken, "Only USDC supported");
        require(amount <= totalLiquidity, "Insufficient liquidity");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Contract has insufficient tokens");

        totalLiquidity = totalLiquidity - (amount);

        if (destinationChainSelector == 5009297550715157269) {
            // Local chain transfer
            require(IERC20(token).transfer(receiver, amount), "Transfer failed");
        } else {
            // Cross-chain transfer
            Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(receiver, token, amount, address(0));
            uint256 fees = s_router.getFee(destinationChainSelector, evm2AnyMessage);
            IERC20(token).approve(address(s_router), amount);
            s_router.ccipSend{value: fees}(destinationChainSelector, evm2AnyMessage);
        }

        emit LiquidityWithdrawn(receiver, amount, destinationChainSelector);
    }

    function addLiquidityFromRepayment(address token, uint256 amount) external onlyOwner {
        require(token == usdcToken, "Only USDC supported");
        totalLiquidity = totalLiquidity + (amount);
    }

    function addLiquidityFromLiquidation(uint256 amount) external onlyOwner {
        totalLiquidity = totalLiquidity + (amount);
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
}