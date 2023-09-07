// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IStakePool {
    function stake(uint256 _amount) external;
    function withdraw(uint256 _amount) external;
}

interface IMintPool {
    function collateralAsset() external view returns(IERC20);
    function depositEtherToMint(uint256 mintAmount) external payable;
    function depositAssetToMint(uint256 assetAmount, uint256 mintAmount) external;
    function getBorrowedOf(address user) external view returns (uint256);
    function depositedAsset(address _user) external view returns (uint256);
    function getAssetPrice() external view returns (uint256);
}

interface IConfigurator {
    function getVaultWeight(address pool) external view returns (uint256);
}

error ExceedStaked(uint256 _desired, uint256 _actual);

contract MatchPool is Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    AggregatorV3Interface private lpPriceFeed; // https://etherscan.io/tx/0x8c638a0998f3b6da40bb1f91602062c46b699150ad70f3b8f07b482df8367102
    AggregatorV3Interface private lbrPriceFeed; // https://etherscan.io/address/0x1932d36f5Dd86327CEacd470271709a931803338#readContract
    IConfigurator public lybraConfigurator;
    IMintPool public mintPool; // stETH vault for minting eUSD

    address public LBR;
    address public wETH;
    address public ethlbrLpToken;
    address public ethlbrStakePool;

    // Total amount of LP token staked into this contract
    // which is in turn staked into Lybra LP reward pool
    uint256 private totalStaked;

    // User address => staked LP token
    mapping(address => uint256) staked;
    mapping(address => uint256) points;

    // Total amount of ETH/stETH deposited to this contract, which some might be deposited into Lybra vault for minting eUSD
    // P.S. Do note that NOT all ETH/stETH must be deposited to Lybra and this contract can hold idle ETH/stETH or
    //      withdraw stETH from Lybra to achieve the desired collateral ratio { collateralRatioIdeal }
    uint256 private totalDeposited;
    // Total amount of eUSD minted
    uint256 private totalMinted;

    // User address => deposited ETH/stETH
    mapping(address => uint256) deposited;
    // User address => eUSD 'taken out/borrowed' by user
    // Users do not determine eUSD mint amount, Match Finanace does
    mapping(address => uint256) borrowedEUSD;

    uint256 private dlpRatioMint; // 650
    uint256 private dlpRatioBurn; // 550
    uint256 private dlpRatioIdeal; // 600
    uint256 private collateralRatioWithdraw; // 210e18
    uint256 private collateralRatioDeposit; // 190e18
    uint256 private collateralRatioIdeal; // 200e18

    event LpOracleChanged(address newOracle, uint256 time);
    event LBROracleChanged(address newOracle, uint256 time);
    event LBRChanged(address newLBR, uint256 time);

    function initialize(
        address _lpOracle, 
        address _lbrOracle, 
        address _ethlbrLpToken, 
        address _ethlbrStakePool, 
        address _weth,
        address _configurator,
        address _stETHMintPool
    ) public initializer {
        lpPriceFeed = AggregatorV3Interface(_lpOracle);
        lbrPriceFeed = AggregatorV3Interface(_lbrOracle);
        ethlbrLpToken = _ethlbrLpToken;
        ethlbrStakePool = _ethlbrStakePool;
        wETH = _weth;
        lybraConfigurator = IConfigurator(_configurator);
        mintPool = IMintPool(_stETHMintPool);
    }

    function setToken(address _lbr) external onlyOwner {
        LBR = _lbr;
        emit LBRChanged(_lbr, block.timestamp);
    }

    function setLBROracle(address _lbrOracle) external onlyOwner {
        lbrPriceFeed = AggregatorV3Interface(_lbrOracle);
        emit LBROracleChanged(_lbrOracle, block.timestamp);
    }

    function setLpOracle(address _lpOracle) external onlyOwner {
        lpPriceFeed = AggregatorV3Interface(_lpOracle);
        emit LpOracleChanged(_lpOracle, block.timestamp);
    }

    // Stake LBR-ETH LP token
    function stakeLP(uint256 _amount) external {
        IERC20(ethlbrLpToken).safeTransferFrom(msg.sender, address(this), _amount);
        IStakePool(ethlbrStakePool).stake(_amount);
        totalStaked += _amount;
        staked[msg.sender] += _amount;

        uint256 currentLpValue = _lpValue(totalStaked);
        if (currentLpValue > 10) points[msg.sender] = 10;
        else if (currentLpValue > 5) points[msg.sender] = 12;
        else points[msg.sender] = 15;
    }

    // Withdraw LBR-ETH LP token
    // function withdrawLP(uint256 _amount) external {
    //     uint256 withdrawable = staked[msg.sender];
    //     if (_amount > withdrawable) revert ExceedStaked(_amount, withdrawable);

    //     totalStaked -= _amount;
    //     staked[msg.sender] -= _amount;
    //     if (staked[msg.sender] == 0) points[msg.sender] = 0;

    //     IStakePool(ethlbrStakePool).withdraw(_amount);
    //     IERC20(ethlbrLpToken).safeTransfer(msg.sender, _amount);
    // }

    function depositETH() external payable {
    }

    function depositStETH(uint256 _amount) external {
        mintPool.collateralAsset().safeTransferFrom(msg.sender, address(this), _amount);
    }

    // function withdrawStETH(uint256 _amount) external {

    // }

    function borrowEUSD() external {

    }

    function adjustEUSDAmount() public returns (int256) {
        // Amount of eUSD to mint/burn as far as esLBR mining is concerned
        uint256 maintainMiningAmount;

        // Value of staked LP tokens
        uint256 currentLpValue = _lpValue(totalStaked);
        // Value of minted eUSD
        uint256 vaultWeight = lybraConfigurator.getVaultWeight(address(mintPool)); // Vault weight of stETH mint pool
        uint256 mintedAmount = totalMinted;
        uint256 mintValue = mintedAmount * vaultWeight / 1e20;
        uint256 dlp = currentLpValue * 10000 / mintValue;

        if (dlp >= dlpRatioMint) {
            // Proposed amount to mint
            maintainMiningAmount = (currentLpValue * 10000 / dlpRatioIdeal - mintValue) * 1e20 / vaultWeight;
        } else if (dlp <= dlpRatioBurn) {
            // Proposed amount to burn
            maintainMiningAmount = (mintValue - currentLpValue * 10000 / dlpRatioIdeal) * 1e20 / vaultWeight;
        } else {
            uint256 collateralRatio = _getCollateralRatio(mintPool.depositedAsset(address(this)), mintedAmount);
            if (collateralRatio >= collateralRatioWithdraw) {

            }
        }
    }

    // Returns collateral ratio based on given parameters,
    // used for determining whether to mint eUSD (amount calculated regarding dlp ratio)
    function _getCollateralRatio(uint256 _depositedAmount, uint256 _mintedAmount) private view returns (uint256) {
        return _depositedAmount * mintPool.getAssetPrice() * 100 / _mintedAmount;
    }

    // Returns amount of stETH to withdraw from/deposit to Lybra vault/ in order to achieve { collateralRatioIdeal }
    function _getAmountGivenCollateralRatio(uint256 _depositedAmount, uint256 _mintedAmount) private view returns (int256) {
        return int256(collateralRatioIdeal) * int256(_mintedAmount) / int256(mintPool.getAssetPrice() * 100) - int256(_depositedAmount);
    }
 
    /**
    * @notice Returns the value of staked LP tokens in the ETH-LBR liquidity pool.
    * @return The value of the staked LP tokens in ETH and LBR.
    */
    function _lpValue(uint256 _lpTokenAmount) private view returns (uint256) {
        (, int lpPrice, , , ) = lpPriceFeed.latestRoundData();
        return _lpTokenAmount * uint256(lpPrice) / 1e8;
    }
}