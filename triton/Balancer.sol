pragma solidity ^0.6.0;

contract Balancer {
    using SafeMath for uint256;
    IUniswapV2Router02 public immutable _uniswapV2Router;
    TRITON private _tokenContract;
    
    constructor(TRITON tokenContract, IUniswapV2Router02 uniswapV2Router) public {
        _tokenContract =tokenContract;
        _uniswapV2Router = uniswapV2Router;
    }
    
    receive() external payable {}
    
    function rebalance() external returns (uint256) { 
        swapEthForTokens(address(this).balance);
    }

    function swapEthForTokens(uint256 EthAmount) private {
        address[] memory uniswapPairPath = new address[](2);
        uniswapPairPath[0] = _uniswapV2Router.WETH();
        uniswapPairPath[1] = address(_tokenContract);

        _uniswapV2Router
            .swapExactETHForTokensSupportingFeeOnTransferTokens{value: EthAmount}(
                0,
                uniswapPairPath,
                address(this),
                block.timestamp
            );
    }
}