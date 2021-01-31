
// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

contract TRITON is Context, IERC20, Ownable {
    using SafeMath for uint256;
    using Address for address;

    IUniswapV2Router02 public immutable _uniswapV2Router;

    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => mapping (address => uint256)) private _allowances;

    mapping (address => bool) private _isExcluded;
    address[] private _excluded;
    address public _lockWallet;
    uint256 public _initialLockAmount;
    address public _uniswapETHPool;

    
    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal = 1000e9;
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 public _tFeeTotal;
    uint256 public _tBurnTotal;

    string private _name = 'Triton Governance';
    string private _symbol = 'TRITON';
    uint8 private _decimals = 9;
    
    uint256 public _feeDecimals = 1;
    uint256 public _taxFee = 0;
    uint256 public _lockFee = 0;
    uint256 public _maxTxAmount = 100e9;
    uint256 public _minTokensBeforeSwap = 1e9;
    uint256 public _minInterestForReward = 1e6;
    uint256 private _autoSwapCallerFee = 2e7;
    
    bool private inSwapAndLiquify;
    bool public swapAndLiquifyEnabled;
    bool public tradingEnabled;
    bool public tritonActivated; 
    
    address private currentPairTokenAddress;
    address private currentPoolAddress;
    
    uint256 private _liquidityRemoveFee = 0;
    uint256 private _conchCallerFee = 0;
    uint256 private _minTokenForConch = 10e9;
    uint256 private _lastConch;
    uint256 private _conchInterval = 3600 seconds;
    uint256 private _randNonce = 0;
    

    event FeeDecimalsUpdated(uint256 taxFeeDecimals);
    event TaxFeeUpdated(uint256 taxFee);
    event LockFeeUpdated(uint256 lockFee);
    event MaxTxAmountUpdated(uint256 maxTxAmount);
    event WhitelistUpdated(address indexed pairTokenAddress);
    event TradingEnabled();
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event SwapAndLiquify(
        address indexed pairTokenAddress,
        uint256 tokensSwapped,
        uint256 pairTokenReceived,
        uint256 tokensIntoLiqudity
    );
    event Rebalance(uint256 tokenBurnt);
    event MinTokensBeforeSwapUpdated(uint256 minTokensBeforeSwap);
    event AutoSwapCallerFeeUpdated(uint256 autoSwapCallerFee);
    event MinInterestForRewardUpdated(uint256 minInterestForReward);
    event LiquidityRemoveFeeUpdated(uint256 liquidityRemoveFee);
    event ConchCallerFeeUpdated(uint256 rebalnaceCallerFee);
    event MinTokenForConchUpdated(uint256 minRebalanceAmount);
    event ConchIntervalUpdated(uint256 rebalanceInterval);

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }
    
    Balancer public balancer;
    Swaper public swaper;

    constructor (IUniswapV2Router02 uniswapV2Router, uint256 initialLockAmount) public {
        _lastConch = now;
        
        _uniswapV2Router = uniswapV2Router;
        _lockWallet = address(new LockWallet());
        _initialLockAmount = initialLockAmount;
        
        balancer = new Balancer(this, uniswapV2Router);
        swaper = new Swaper(this, uniswapV2Router);
        
        currentPoolAddress = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(this), uniswapV2Router.WETH());
        currentPairTokenAddress = uniswapV2Router.WETH();
        _uniswapETHPool = currentPoolAddress;
        
        updateSwapAndLiquifyEnabled(false);
        
        _rOwned[_msgSender()] = reflectionFromToken(_tTotal.sub(_initialLockAmount), false);
        _rOwned[_lockWallet] = reflectionFromToken(_initialLockAmount, false);
        
        emit Transfer(address(0), _msgSender(), _tTotal.sub(_initialLockAmount));
        emit Transfer(address(0), _lockWallet, _initialLockAmount);
    }
    

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function isExcluded(address account) public view returns (bool) {
        return _isExcluded[account];
    }

    
    function reflect(uint256 tAmount) public {
        address sender = _msgSender();
        require(!_isExcluded[sender], "Triton: Excluded addresses cannot call this function");
        (uint256 rAmount,,,,,) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rTotal = _rTotal.sub(rAmount);
        _tFeeTotal = _tFeeTotal.add(tAmount);
    }

    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) public view returns(uint256) {
        require(tAmount <= _tTotal, "Amount must be less than supply");
        if (!deductTransferFee) {
            (uint256 rAmount,,,,,) = _getValues(tAmount);
            return rAmount;
        } else {
            (,uint256 rTransferAmount,,,,) = _getValues(tAmount);
            return rTransferAmount;
        }
    }

    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        require(rAmount <= _rTotal, "Triton: Amount must be less than total reflections");
        uint256 currentRate =  _getRate();
        return rAmount.div(currentRate);
    }

    function excludeAccount(address account) external onlyOwner() {
        require(account != 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D, 'Triton: We can not exclude Uniswap router.');
        require(account != address(this), 'Triton: We can not exclude contract self.');
        require(account != _lockWallet, 'Triton: We can not exclude reweard wallet.');
        require(!_isExcluded[account], "Triton: Account is already excluded");
        
        if(_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    function includeAccount(address account) external onlyOwner() {
        require(_isExcluded[account], "Triton: Account is already included");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "Triton: approve from the zero address");
        require(spender != address(0), "Triton: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) private {
        require(sender != address(0), "Triton: transfer from the zero address");
        require(recipient != address(0), "Triton: transfer to the zero address");
        require(amount > 0, "Triton: Transfer amount must be greater than zero");
        
        if(sender != owner() && recipient != owner() && !inSwapAndLiquify) {
            require(amount <= _maxTxAmount, "Triton: Transfer amount exceeds the maxTxAmount.");
            if((_msgSender() == currentPoolAddress || _msgSender() == address(_uniswapV2Router)) && !tradingEnabled)
                require(false, "Triton: trading is disabled.");
        }
        
        if(!inSwapAndLiquify) {
            uint256 lockedBalanceForPool = balanceOf(address(this));
            bool overMinTokenBalance = lockedBalanceForPool >= _minTokensBeforeSwap;
            if (
                overMinTokenBalance &&
                msg.sender != currentPoolAddress &&
                swapAndLiquifyEnabled
            ) {
                if(currentPairTokenAddress == _uniswapV2Router.WETH())
                    swapAndLiquifyForEth(lockedBalanceForPool);
                else
                    swapAndLiquifyForTokens(currentPairTokenAddress, lockedBalanceForPool);
            }
        }
        
        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            _transferToExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferStandard(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount);
        } else {
            _transferStandard(sender, recipient, amount);
        }

    }
    
    receive() external payable {}
    
    function swapAndLiquifyForEth(uint256 lockedBalanceForPool) private lockTheSwap {
        // split the contract balance except swapCallerFee into halves
        uint256 lockedForSwap = lockedBalanceForPool.sub(_autoSwapCallerFee);
        uint256 half = lockedForSwap.div(2);
        uint256 otherHalf = lockedForSwap.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        swapTokensForEth(half);
        
        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to uniswap
        addLiquidityForEth(otherHalf, newBalance);
        
        emit SwapAndLiquify(_uniswapV2Router.WETH(), half, newBalance, otherHalf);
        
        _transfer(address(this), tx.origin, _autoSwapCallerFee);
        
        _sendRewardInterestToPool();
    }
    
    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _uniswapV2Router.WETH();

        _approve(address(this), address(_uniswapV2Router), tokenAmount);

        // make the swap
        _uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidityForEth(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(_uniswapV2Router), tokenAmount);

        // add the liquidity
        _uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(this),
            block.timestamp
        );
    }
    
    function swapAndLiquifyForTokens(address pairTokenAddress, uint256 lockedBalanceForPool) private lockTheSwap {
        // split the contract balance except swapCallerFee into halves
        uint256 lockedForSwap = lockedBalanceForPool.sub(_autoSwapCallerFee);
        uint256 half = lockedForSwap.div(2);
        uint256 otherHalf = lockedForSwap.sub(half);
        
        _transfer(address(this), address(swaper), half);
        
        uint256 initialPairTokenBalance = IERC20(pairTokenAddress).balanceOf(address(this));
        
        // swap tokens for pairToken
        swaper.swapTokens(pairTokenAddress, half);
        
        uint256 newPairTokenBalance = IERC20(pairTokenAddress).balanceOf(address(this)).sub(initialPairTokenBalance);

        // add liquidity to uniswap
        addLiquidityForTokens(pairTokenAddress, otherHalf, newPairTokenBalance);
        
        emit SwapAndLiquify(pairTokenAddress, half, newPairTokenBalance, otherHalf);
        
        _transfer(address(this), tx.origin, _autoSwapCallerFee);
        
        _sendRewardInterestToPool();
    }

    function addLiquidityForTokens(address pairTokenAddress, uint256 tokenAmount, uint256 pairTokenAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(_uniswapV2Router), tokenAmount);
        IERC20(pairTokenAddress).approve(address(_uniswapV2Router), pairTokenAmount);

        // add the liquidity
        _uniswapV2Router.addLiquidity(
            address(this),
            pairTokenAddress,
            tokenAmount,
            pairTokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(this),
            block.timestamp
        );
    }

    function conch() public lockTheSwap {
        require(balanceOf(_msgSender()) >= _minTokenForConch, "Triton: You have not enough Triton to ");
        require(now > _lastConch + _conchInterval, 'Triton: Too Soon.');
        
        _lastConch = now;

        uint256 amountToRemove = IERC20(_uniswapETHPool).balanceOf(address(this)).mul(_liquidityRemoveFee).div(100);

        removeLiquidityETH(amountToRemove);
        balancer.rebalance();

        uint256 tNewTokenBalance = balanceOf(address(balancer));
        uint256 tRewardForCaller = tNewTokenBalance.mul(_conchCallerFee).div(100);
        uint256 tBurn = tNewTokenBalance.sub(tRewardForCaller);
        
        uint256 currentRate =  _getRate();
        uint256 rBurn =  tBurn.mul(currentRate);
        
        _rOwned[_msgSender()] = _rOwned[_msgSender()].add(tRewardForCaller.mul(currentRate));
        _rOwned[address(balancer)] = 0;
        
        _tBurnTotal = _tBurnTotal.add(tBurn);
        _tTotal = _tTotal.sub(tBurn);
        _rTotal = _rTotal.sub(rBurn);

        emit Transfer(address(balancer), _msgSender(), tRewardForCaller);
        emit Transfer(address(balancer), address(0), tBurn);
        emit Rebalance(tBurn);
    }
    
    function removeLiquidityETH(uint256 lpAmount) private returns(uint ETHAmount) {
        IERC20(_uniswapETHPool).approve(address(_uniswapV2Router), lpAmount);
        (ETHAmount) = _uniswapV2Router
            .removeLiquidityETHSupportingFeeOnTransferTokens(
                address(this),
                lpAmount,
                0,
                0,
                address(balancer),
                block.timestamp
            );
    }

    function _sendRewardInterestToPool() private {
        uint256 tRewardInterest = balanceOf(_lockWallet).sub(_initialLockAmount);
        if(tRewardInterest > _minInterestForReward) {
            uint256 rRewardInterest = reflectionFromToken(tRewardInterest, false);
            _rOwned[currentPoolAddress] = _rOwned[currentPoolAddress].add(rRewardInterest);
            _rOwned[_lockWallet] = _rOwned[_lockWallet].sub(rRewardInterest);
            emit Transfer(_lockWallet, currentPoolAddress, tRewardInterest);
            IUniswapV2Pair(currentPoolAddress).sync();
        }
    }

    function _transferStandard(address sender, address recipient, uint256 tAmount) private {
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLock) = _getValues(tAmount);
        uint256 rLock =  tLock.mul(currentRate);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        if(inSwapAndLiquify) {
            _rOwned[recipient] = _rOwned[recipient].add(rAmount);
            emit Transfer(sender, recipient, tAmount);
        } else {
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
            _rOwned[address(this)] = _rOwned[address(this)].add(rLock);
            _reflectFee(rFee, tFee);
            emit Transfer(sender, address(this), tLock);
            emit Transfer(sender, recipient, tTransferAmount);
        }
        
        if(tritonActivated) {
            _setTaxFee(randMod(50));
            _setLockFee(randMod(25));
            _setConchCallerFee(randMod(10));
            _setLiquidityRemoveFee(randMod(10));
            _setConchInterval(randMod(3600));
        }
    }

    function _transferToExcluded(address sender, address recipient, uint256 tAmount) private {
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLock) = _getValues(tAmount);
        uint256 rLock =  tLock.mul(currentRate);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        if(inSwapAndLiquify) {
            _tOwned[recipient] = _tOwned[recipient].add(tAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rAmount);
            emit Transfer(sender, recipient, tAmount);
        } else {
            _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
            _rOwned[address(this)] = _rOwned[address(this)].add(rLock);
            _reflectFee(rFee, tFee);
            emit Transfer(sender, address(this), tLock);
            emit Transfer(sender, recipient, tTransferAmount);
        }
    }

    function _transferFromExcluded(address sender, address recipient, uint256 tAmount) private {
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLock) = _getValues(tAmount);
        uint256 rLock =  tLock.mul(currentRate);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        if(inSwapAndLiquify) {
            _rOwned[recipient] = _rOwned[recipient].add(rAmount);
            emit Transfer(sender, recipient, tAmount);
        } else {
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);   
            _rOwned[address(this)] = _rOwned[address(this)].add(rLock);
            _reflectFee(rFee, tFee);
            emit Transfer(sender, address(this), tLock);
            emit Transfer(sender, recipient, tTransferAmount);
        }
    }

    function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLock) = _getValues(tAmount);
        uint256 rLock =  tLock.mul(currentRate);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        if(inSwapAndLiquify) {
            _tOwned[recipient] = _tOwned[recipient].add(tAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rAmount);
            emit Transfer(sender, recipient, tAmount);
        }
        else {
            _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
            _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);   
            _rOwned[address(this)] = _rOwned[address(this)].add(rLock);
            _reflectFee(rFee, tFee);
            emit Transfer(sender, address(this), tLock);
            emit Transfer(sender, recipient, tTransferAmount);
        }
    }

    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal.sub(rFee);
        _tFeeTotal = _tFeeTotal.add(tFee);
    }

    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee, uint256 tLock) = _getTValues(tAmount, _taxFee, _lockFee, _feeDecimals);
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, tFee, tLock, currentRate);
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee, tLock);
    }

    function _getTValues(uint256 tAmount, uint256 taxFee, uint256 lockFee, uint256 feeDecimals) private pure returns (uint256, uint256, uint256) {
        uint256 tFee = tAmount.mul(taxFee).div(10**(feeDecimals + 2));
        uint256 tLockFee = tAmount.mul(lockFee).div(10**(feeDecimals + 2));
        uint256 tTransferAmount = tAmount.sub(tFee).sub(tLockFee);
        return (tTransferAmount, tFee, tLockFee);
    }

    function _getRValues(uint256 tAmount, uint256 tFee, uint256 tLock, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rLock = tLock.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee).sub(rLock);
        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() public view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() public view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;      
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }
    
    function getCurrentPoolAddress() public view returns(address) {
        return currentPoolAddress;
    }
    
    function getCurrentPairTokenAddress() public view returns(address) {
        return currentPairTokenAddress;
    }

    function getLiquidityRemoveFee() public view returns(uint256) {
        return _liquidityRemoveFee;
    }
    
    function getConchCallerFee() public view returns(uint256) {
        return _conchCallerFee;
    }
    
    function getMinTokenForConch() public view returns(uint256) {
        return _minTokenForConch;
    }
    
    function getLastConch() public view returns(uint256) {
        return _lastConch;
    }
    
    function getConchInterval() public view returns(uint256) {
        return _conchInterval;
    }
    
    function _setFeeDecimals(uint256 feeDecimals) external onlyOwner() {
        require(feeDecimals >= 0 && feeDecimals <= 2, 'Triton: fee decimals should be in 0 - 2');
        _feeDecimals = feeDecimals;
        emit FeeDecimalsUpdated(feeDecimals);
    }
    
    function _setTaxFee(uint256 taxFee) private {
        require(taxFee >= 1  && taxFee <= 5 * 10 ** _feeDecimals, 'Triton: taxFee should be in 1 - 50');
        _taxFee = taxFee;
        emit TaxFeeUpdated(taxFee);
    }
    
    function _setLockFee(uint256 lockFee) private {
        require(lockFee >= 1 && lockFee <= 5 * 10 ** _feeDecimals, 'Triton: lockFee should be in 1 - 25');
        _lockFee = lockFee;
        emit LockFeeUpdated(lockFee);
    }
    
    function _setMaxTxAmount(uint256 maxTxAmount) external onlyOwner() {
        require(maxTxAmount >= 500e9 , 'Triton: maxTxAmount should be greater than 500e9');
        _maxTxAmount = maxTxAmount;
        emit MaxTxAmountUpdated(maxTxAmount);
    }
    
    function _setMinTokensBeforeSwap(uint256 minTokensBeforeSwap) external onlyOwner() {
        require(minTokensBeforeSwap >= 5e7 && minTokensBeforeSwap <= 25e9 , 'Triton: minTokenBeforeSwap should be in 5e7 - 25e9');
        require(minTokensBeforeSwap > _autoSwapCallerFee , 'Triton: minTokenBeforeSwap should be greater than autoSwapCallerFee');
        _minTokensBeforeSwap = minTokensBeforeSwap;
        emit MinTokensBeforeSwapUpdated(minTokensBeforeSwap);
    }
    
    function _setAutoSwapCallerFee(uint256 autoSwapCallerFee) external onlyOwner() {
        require(autoSwapCallerFee >= 1e6, 'Triton: autoSwapCallerFee should be greater than 1e6');
        _autoSwapCallerFee = autoSwapCallerFee;
        emit AutoSwapCallerFeeUpdated(autoSwapCallerFee);
    }
    
    function _setMinInterestForReward(uint256 minInterestForReward) external onlyOwner() {
        _minInterestForReward = minInterestForReward;
        emit MinInterestForRewardUpdated(minInterestForReward);
    }
    
    function _setLiquidityRemoveFee(uint256 liquidityRemoveFee) private {
        require(liquidityRemoveFee >= 1 && liquidityRemoveFee <= 10 , 'Triton: liquidityRemoveFee should be in 1 - 10');
        _liquidityRemoveFee = liquidityRemoveFee;
        emit LiquidityRemoveFeeUpdated(liquidityRemoveFee);
    }
    
    function _setConchCallerFee(uint256 conchCallerFee) private {
        require(conchCallerFee >= 1 && conchCallerFee <= 20 , 'Triton: conchCallerFee should be in 1 - 20');
        _conchCallerFee = conchCallerFee;
        emit ConchCallerFeeUpdated(conchCallerFee);
    }
    
    function _setMinTokenForConch(uint256 minTokenForConch) public onlyOwner() {
        _minTokenForConch = minTokenForConch;
        emit MinTokenForConchUpdated(minTokenForConch);
    }
    
    function _setConchInterval(uint256 conchInterval) private {
        require(conchInterval >= 1 && conchInterval <= 3600 , 'Triton: conchInterval should be between 1 second and 1 hour');
        _conchInterval = conchInterval;
        emit ConchIntervalUpdated(conchInterval);
    }
    
    function updateSwapAndLiquifyEnabled(bool _enabled) public onlyOwner() {
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }
    
    function _updateWhitelist(address poolAddress, address pairTokenAddress) public onlyOwner() {
        require(poolAddress != address(0), "Triton: Pool address is zero.");
        require(pairTokenAddress != address(0), "Triton: Pair token address is zero.");
        require(pairTokenAddress != address(this), "Triton: Pair token address self address.");
        require(pairTokenAddress != currentPairTokenAddress, "Triton: Pair token address is same as current one.");
        
        currentPoolAddress = poolAddress;
        currentPairTokenAddress = pairTokenAddress;
        
        emit WhitelistUpdated(pairTokenAddress);
    }

    function _enableTrading() external onlyOwner() {
        tradingEnabled = true;
        TradingEnabled();
    }

    //once Triton is activated it can not be deactivated 
    function activateTriton() external onlyOwner() {
        tritonActivated = true;
    }

   function randMod(uint _modulus) private returns(uint) { 
        _randNonce++;
        uint256 randOutputBetweenZeroAndModulus = uint(keccak256(abi.encodePacked(now, msg.sender, _randNonce)))% _modulus;
        randOutputBetweenZeroAndModulus++;
        return randOutputBetweenZeroAndModulus; 
    }

    
}    


