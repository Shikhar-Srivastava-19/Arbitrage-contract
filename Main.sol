// contracts/FlashLoan.sol
// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.9.0;
// 1000000000000000000
// import {FlashLoanSimpleReceiverBase} from "https://github.com/aave/aave-v3-core/blob/master/contracts/flashloan/base/FlashLoanSimpleReceiverBase.sol";
// import {IPoolAddressesProvider} from "https://github.com/aave/aave-v3-core/blob/master/contracts/interfaces/IPoolAddressesProvider.sol";
// import {ISwapRouter} from "https://github.com/Uniswap/v3-periphery/blob/main/contracts/interfaces/ISwapRouter.sol";
import {FlashLoanSimpleReceiverBase} from "../core-v3/contracts/flashloan/base/FlashLoanSimpleReceiverBase.sol";
import {IPoolAddressesProvider} from "../core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./interfaces/IAsset.sol";
import "./interfaces/IVault.sol";
import "./interfaces/ICurve.sol";
import "./interfaces/IBalancerQueries.sol";

contract Main is FlashLoanSimpleReceiverBase {
    using SafeERC20 for IERC20;
    address payable owner;
    address operator;
    // address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // for protection from re-entrancy attack ;
    bool private locked;

    address private constant BALANCER_VAULT =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    IVault private constant BALANCER_VAULT_CONNECTION = IVault(BALANCER_VAULT);
    IBalancerQueries private constant BALANCER_QOUTES =
        IBalancerQueries(0xE39B5e3B6D74016b2F6A9673D7d7493B6DF549d5);
    bytes32 private balancerCurrentPool;
    // 0xa6f548df93de924d73be7d25dc02554c6bd66db500020000000000000000000e; WETH/WBTC
    // 0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019 - WETH/USDC
    // No direct pool for WBTC/USDT
    // address private constant curveCurrentPool = 0xD51a44d3FaE010294C616388b506AcdA1bfAAE46;
    ICurve private curvePoolConnection =
        ICurve(0xD51a44d3FaE010294C616388b506AcdA1bfAAE46); // only single pool of curve Right now, so setting it
    // address[] tokenArr = [USDT, WBTC, WETH];
    // uint8 exchangeState;
    event ReturnedAmountFromAExchange(uint256 _value);
    event AaveInitiatorData(address _initiator);

    ISwapRouter public immutable uniswapRouter =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    uint24 public uniswapPoolFee;
    // uniswapPoolFee tiers 500, 3000, 10000
    // address currentTokenIN;
    // address currentTokenOut;

    constructor(address _owner)
        FlashLoanSimpleReceiverBase(
            IPoolAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e) //address AAVE_FLASHLOAN_POOL_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
        )
    {
        operator = msg.sender;
        owner = payable(_owner);
    }

    function executeOperation(
        address _asset,
        uint256 _amount,
        uint256 _premium,
        address _initiator,
        bytes calldata _params
    ) external override returns (bool) {
        emit AaveInitiatorData(_initiator);
        (
            uint8 exchangeState,
            address currentTokenOut,
            uint256 minProfit,
            uint256 balanceBeforeFlashloan
        ) = abi.decode(_params, (uint8, address, uint256, uint256));
        uint256 returnedFromSecondExchange = 0;
        if (exchangeState == 1)
            returnedFromSecondExchange = balancerToCurve(
                _asset,
                currentTokenOut,
                _amount
            );
        else if (exchangeState == 2)
            returnedFromSecondExchange = curveToBalancer(
                _asset,
                currentTokenOut,
                _amount
            );
        else if (exchangeState == 3)
            returnedFromSecondExchange = balancerToUniswap(
                _asset,
                currentTokenOut,
                _amount
            );
        else if (exchangeState == 4)
            returnedFromSecondExchange = uniswapToBalancer(
                _asset,
                currentTokenOut,
                _amount
            );
        else if (exchangeState == 5)
            returnedFromSecondExchange = curveToUniswap(
                _asset,
                currentTokenOut,
                _amount
            );
        else if (exchangeState == 6)
            returnedFromSecondExchange = uniswapToCurve(
                _asset,
                currentTokenOut,
                _amount
            );
        else return false;
        uint256 amountOwed = _amount + _premium;
        require(
            returnedFromSecondExchange > amountOwed + minProfit,
            "No profit in Arbitrage"
        );
        require(
            tokenBalance(_asset) >=
                balanceBeforeFlashloan + _premium + minProfit,
            "Token Balance before arbitrage is greater than balance after arbitrage."
        );
        approveToken(_asset, address(POOL), amountOwed);
        return true;
    }

    function requestFlashLoan(
        address _token,       
        address _tokenOut,
        uint256 _amount,
        uint256 _minProfit,
        uint8 _exchangeState,
        bytes32 _balancerPoolId,
        uint24 _uniswapPoolFee,
        uint24 _flashloanFeeNumerator,    // for now flashloan fee is 0.05%, so here it will be _flashloanFeeNumerator = 5
        uint32 _flashloanFeeDenominator   // _flashloanFeeDenominator = 100;
    ) external onlyOperator {
        require(_flashloanFeeDenominator > 0 && tokenBalance(_token) >= ((_amount * _flashloanFeeNumerator)/(100 * _flashloanFeeDenominator)), "Not enough token balance for flashloan fee");
        require(
            _exchangeState > 0 && _exchangeState <= 6,
            "_exchangeState can only be from 0 to 6"
        );
        bytes memory params = abi.encode(
            _exchangeState,
            _tokenOut,
            _minProfit,
            tokenBalance(_token)
        );
        if (_exchangeState != 5 && _exchangeState != 6)
            balancerCurrentPool = _balancerPoolId;
        if (_exchangeState != 1 && _exchangeState != 2)
            uniswapPoolFee = _uniswapPoolFee;
        POOL.flashLoanSimple(
            address(this), // receiver's address
            _token,
            _amount,
            params, // params
            0 // referralCode
        );
    }

    function balancerToCurve(
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) private returns (uint256) {
        uint256 returnedFromFirstExchange = 0;
        uint256 returnedFromSecondExchange = 0;
        returnedFromFirstExchange = balancerSingleSwapToken(
            balancerCurrentPool,
            _tokenIn,
            _tokenOut,
            _amount,
            0
        );
        returnedFromSecondExchange = curveSingleSwapToken(
            _tokenOut,
            _tokenIn,
            returnedFromFirstExchange
        );
        return returnedFromSecondExchange;
    }

    function curveToBalancer(
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) private returns (uint256) {
        uint256 returnedFromFirstExchange = 0;
        uint256 returnedFromSecondExchange = 0;
        returnedFromFirstExchange = curveSingleSwapToken(
            _tokenIn,
            _tokenOut,
            _amount
        );
        returnedFromSecondExchange = balancerSingleSwapToken(
            balancerCurrentPool,
            _tokenOut,
            _tokenIn,
            returnedFromFirstExchange,
            0
        );
        return returnedFromSecondExchange;
    }

    function balancerToUniswap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) private returns (uint256) {
        uint256 returnedFromFirstExchange = 0;
        uint256 returnedFromSecondExchange = 0;
        returnedFromFirstExchange = balancerSingleSwapToken(
            balancerCurrentPool,
            _tokenIn,
            _tokenOut,
            _amount,
            0
        );
        returnedFromSecondExchange = uniswapSingleSwap(
            _tokenOut,
            _tokenIn,
            returnedFromFirstExchange
        );
        return returnedFromSecondExchange;
    }

    function uniswapToBalancer(
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) private returns (uint256) {
        uint256 returnedFromFirstExchange = 0;
        uint256 returnedFromSecondExchange = 0;
        returnedFromFirstExchange = uniswapSingleSwap(
            _tokenIn,
            _tokenOut,
            _amount
        );
        returnedFromSecondExchange = balancerSingleSwapToken(
            balancerCurrentPool,
            _tokenOut,
            _tokenIn,
            returnedFromFirstExchange,
            0
        );
        return returnedFromSecondExchange;
    }

    function curveToUniswap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) private returns (uint256) {
        uint256 returnedFromFirstExchange = 0;
        uint256 returnedFromSecondExchange = 0;
        returnedFromFirstExchange = curveSingleSwapToken(
            _tokenIn,
            _tokenOut,
            _amount
        );
        returnedFromSecondExchange = uniswapSingleSwap(
            _tokenOut,
            _tokenIn,
            returnedFromFirstExchange
        );
        return returnedFromSecondExchange;
    }

    function uniswapToCurve(
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) private returns (uint256) {
        uint256 returnedFromFirstExchange = 0;
        uint256 returnedFromSecondExchange = 0;
        returnedFromFirstExchange = uniswapSingleSwap(
            _tokenIn,
            _tokenOut,
            _amount
        );
        returnedFromSecondExchange = curveSingleSwapToken(
            _tokenOut,
            _tokenIn,
            returnedFromFirstExchange
        );
        return returnedFromSecondExchange;
    }

    function balancerSingleSwapToken(
        bytes32 _poolId,
        address _tokenIn,
        address _tokenOut,
        uint256 _amount,
        uint256 _limit
    ) private returns (uint256) {
        approveToken(_tokenIn, address(BALANCER_VAULT), _amount);
        IVault.FundManagement memory fund_m = IVault.FundManagement(
            address(this),
            false,
            payable(address(this)),
            false
        );
        IVault.SingleSwap memory singleSwap = IVault.SingleSwap(
            _poolId,
            IVault.SwapKind.GIVEN_IN,
            IAsset(_tokenIn),
            IAsset(_tokenOut),
            _amount,
            ""
        );
        uint256 returnAmount = BALANCER_VAULT_CONNECTION.swap(
            singleSwap,
            fund_m,
            _limit,
            block.timestamp
        );
        emit ReturnedAmountFromAExchange(returnAmount);
        return returnAmount;
    }

    function getExpectedPriceFromBalancer(
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) public returns (uint256) {
        IVault.FundManagement memory fund_m = IVault.FundManagement(
            address(this),
            false,
            payable(address(this)),
            false
        );
        IVault.SingleSwap memory singleSwap = IVault.SingleSwap(
            balancerCurrentPool,
            IVault.SwapKind.GIVEN_IN,
            IAsset(_tokenIn),
            IAsset(_tokenOut),
            _amount,
            ""
        );
        return BALANCER_QOUTES.querySwap(singleSwap, fund_m);
    }

    function curveSingleSwapToken(
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) private returns (uint256) {
        uint256 tokenBalanceBeforeExchange = tokenBalance(_tokenOut);
        // uint256 tokenAcquired = 0;
        approveToken(_tokenIn, address(curvePoolConnection), _amount);
        curvePoolConnection.exchange(
            curveUsdtWbtcWethMapping(_tokenIn),
            curveUsdtWbtcWethMapping(_tokenOut),
            _amount,
            0,
            false
        );
        // uint256 tokenBalanceAfterExchange = tokenBalance(_tokenOut);
        require(
            tokenBalance(_tokenOut) > tokenBalanceBeforeExchange,
            "Token Swap Unsuccessful!"
        );
        emit ReturnedAmountFromAExchange(
            tokenBalance(_tokenOut) - tokenBalanceBeforeExchange
        );
        return (tokenBalance(_tokenOut) - tokenBalanceBeforeExchange);
    }

    // function getExpectedPriceFromCurve(
    //     address _tokenIn,
    //     address _tokenOut,
    //     uint256 _amount
    // ) public view returns (uint256) {
    //     return
    //         curvePoolConnection.get_dy(
    //             curveUsdtWbtcWethMapping(_tokenIn),
    //             curveUsdtWbtcWethMapping(_tokenOut),
    //             _amount
    //         );
    // }

    // curve takes indexes of arr to define token to swap
    // Not making a mapping because in case of non-existing address the value returned will be 0 which will make usdt swap
    function curveUsdtWbtcWethMapping(address _token)
        public
        pure
        returns (uint8)
    {
        if (_token == USDT) return 0;
        else if (_token == WBTC) return 1;
        else if (_token == WETH) return 2;
        else return 4;
    }

    function uniswapSingleSwap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) private returns (uint256) {
        approveToken(_tokenIn, address(uniswapRouter), _amountIn);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                fee: uniswapPoolFee,
                recipient: payable(address(this)),
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
        return uniswapRouter.exactInputSingle(params);
    }

    function tokenBalance(address _tokenAddress) public view returns (uint256) {
        IERC20 token = IERC20(_tokenAddress);
        return token.balanceOf(address(this));
    }

    function withdrawToken(address _tokenAddress, uint256 _amount)
        external
        onlyOwner
    {
        IERC20 token = IERC20(_tokenAddress);
        token.safeTransfer(msg.sender, _amount);
    }

    // Because of receive() function, there should be a way to withdraw ether
    function withdrawEther(uint256 amount) external onlyOwner {
        require(
            amount <= address(this).balance,
            "Insufficient balance in the contract"
        );
        payable(owner).transfer(amount);
    }

    function approveToken(
        address _tokenAddress,
        address _to,
        uint256 _amount
    ) private {
        IERC20 token = IERC20(_tokenAddress);
        token.safeIncreaseAllowance(_to, _amount);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        owner = payable(_newOwner);
    }

    function transferOperatability(address _newOperator) external onlyOwner {
        operator = _newOperator;
    }

    modifier onlyOwner() {
        require(
            msg.sender == owner,
            "Only the contract owner can call this function"
        );
        _;
    }

    modifier onlyOperator() {
        require(
            msg.sender == operator,
            "Only the contract operator can call this function"
        );
        _;
    }

    // modifier noReentrancy() {
    //     require(!locked, "ReentrancyGuard: reentrant call");
    //     locked = true;
    //     _;
    //     locked = false;
    // }

    receive() external payable {}
}
