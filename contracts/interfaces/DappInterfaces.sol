// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface ILido {
    function submit(address _referral) external payable returns (uint256 StETH);
    
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWstETH {
    function stEthPerToken() external view returns (uint256);
    
    function wrap(uint256 _stETHAmount) external returns (uint256);
}

interface IWBETH {
    function deposit(address referral) external payable;
}

interface IRocketDepositPool {
    function deposit() external payable;
}

interface IRocketStorageInterface {
    function getAddress(bytes32 _key) external view returns (address);
}

interface IDepositHelper {
    function toLSD() external payable returns (uint256);
}

interface IUniswapV2Router {
    function swapExactETHForTokens(
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}