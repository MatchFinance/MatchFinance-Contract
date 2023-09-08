// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface ILido {
    function submit(address _referral) external payable returns (uint256 StETH);
}

interface IStakePool {
    function stake(uint256 _amount) external;
    function withdraw(uint256 _amount) external;
}

interface IMintPool {
    function collateralAsset() external view returns(IERC20);
    function depositAssetToMint(uint256 assetAmount, uint256 mintAmount) external;
    function getBorrowedOf(address user) external view returns (uint256);
    function depositedAsset(address _user) external view returns (uint256);
    function getAssetPrice() external view returns (uint256);
    function withdraw(address onBehalfOf, uint256 amount) external;
    function mint(address onBehalfOf, uint256 amount) external;
    function burn(address onBehalfOf, uint256 amount) external;
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
    uint256 public totalStaked;

    // User address => staked LP token
    mapping(address => uint256) staked;
    mapping(address => uint256) points;

    // Total amount of ETH/stETH deposited to this contract, which some might be deposited into Lybra vault for minting eUSD
    // P.S. Do note that NOT all ETH/stETH must be deposited to Lybra and this contract can hold idle ETH/stETH or
    //      withdraw stETH from Lybra to achieve the desired collateral ratio { collateralRatioIdeal }
    uint256 public totalSupplied;
    // Total amount of stETH deposited to Lybra vault pool as collateral for minting eUSD
    uint256 public totalDeposited;
    // Total amount of eUSD minted
    uint256 public totalMinted;

    // User address => supplied ETH/stETH
    mapping(address => uint256) supplied;
    // User address => eUSD 'taken out/borrowed' by user
    // Users do not determine eUSD mint amount, Match Finanace does
    mapping(address => uint256) borrowedEUSD;

    uint256 private dlpRatioUpper; // 650
    uint256 private dlpRatioLower; // 550
    uint256 private dlpRatioIdeal; // 600
    uint256 private collateralRatioUpper; // 210e18
    uint256 private collateralRatioLower; // 190e18
    uint256 private collateralRatioIdeal; // 200e18

    event LpOracleChanged(address newOracle, uint256 time);
    event LBROracleChanged(address newOracle, uint256 time);
    event LBRChanged(address newLBR, uint256 time);
    event dlpRatioRangeChanged(uint256 newLower, uint256 newUpper, uint256 newIdeal);
    event collateralRatioRangeChanged(uint256 newLower, uint256 newUpper, uint256 newIdeal);

    // Update user's claimable reward data and record the timestamp.
    modifier updateReward(address _account) {
        rewardPerTokenStored = rewardPerToken();
        updatedAt = lastTimeRewardApplicable();

        if (_account != address(0)) {
            rewards[_account] = earned(_account);
            userRewardPerTokenPaid[_account] = rewardPerTokenStored;
            userUpdatedAt[_account] = block.timestamp;
        }
        _;
    }

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

        setDlpRatioRange(550, 650, 600);
        setCollateralRatioRange(190e18, 210e18, 200e18);
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

    function setDlpRatioRange(uint256 _lower, uint256 _upper, uint256 _ideal) public onlyOwner {
        dlpRatioLower = _lower;
        dlpRatioUpper = _upper;
        dlpRatioIdeal = _ideal;
        emit dlpRatioRangeChanged(_lower, _upper, _ideal);
    }

    function setCollateralRatioRange(uint256 _lower, uint256 _upper, uint256 _ideal) public onlyOwner {
        collateralRatioLower = _lower;
        collateralRatioUpper = _upper;
        collateralRatioIdeal = _ideal;
        emit collateralRatioRangeChanged(_lower, _upper, _ideal);
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
    function withdrawLP(uint256 _amount) external {
        uint256 withdrawable = staked[msg.sender];
        if (_amount > withdrawable) revert ExceedStaked(_amount, withdrawable);

        totalStaked -= _amount;
        staked[msg.sender] -= _amount;
        if (staked[msg.sender] == 0) points[msg.sender] = 0;

        IStakePool(ethlbrStakePool).withdraw(_amount);
        IERC20(ethlbrLpToken).safeTransfer(msg.sender, _amount);
    }

    function supplyETH() external payable {
        uint256 sharesAmount = ILido(address(mintPool.collateralAsset())).submit{value: msg.value}(address(0));
        require(sharesAmount != 0, "ZERO_DEPOSIT");
        totalSupplied += msg.value;
        supplied[msg.sender] += msg.value;
    }

    function supplyStETH(uint256 _amount) external {
        mintPool.collateralAsset().safeTransferFrom(msg.sender, address(this), _amount);
        totalSupplied += _amount;
        supplied[msg.sender] += _amount;
    }

    // function withdrawStETH(uint256 _amount) external {

    // }

    function borrowEUSD() external {

    }

    /**
     * @notice Implementation of dynamic eUSD minting mechanism and collateral ratio control
     */
    function adjustEUSDAmount() public {
        // Amount of eUSD to mint/burn to adjust dlp ratio to desired range
        uint256 maintainMiningAmount;
        // Value of staked LP tokens
        uint256 currentLpValue = _lpValue(totalStaked);
        // Amount of ETH/stETH supplied by users to this contract
        uint256 _totalSupplied = totalSupplied;
        // Original amount of total deposits
        uint256 _totalDeposited = totalDeposited;
        // Original amount of total eUSD minted
        uint256 _totalMinted = totalMinted;
        // Value of minted eUSD
        uint256 vaultWeight = lybraConfigurator.getVaultWeight(address(mintPool)); // Vault weight of stETH mint pool
        uint256 mintValue = _totalMinted * vaultWeight / 1e20;

        if (mintValue == 0) {
            uint256 initialMint = currentLpValue * 10000 * 1e20 / (dlpRatioIdeal * vaultWeight);
            uint256 initialDeposit = _getDepositAmountDelta(0, initialMint);

            if (initialDeposit > _totalSupplied - _totalDeposited) return;

            _depositStETH(initialDeposit, initialMint);

            return;
        }

        uint256 dlp = currentLpValue * 10000 / mintValue;

        if (dlp >= dlpRatioUpper) {
            // Proposed amount to mint
            maintainMiningAmount = (currentLpValue * 10000 / dlpRatioIdeal - mintValue) * 1e20 / vaultWeight;
            // New collateral ratio after minting
            uint256 newCollateralRatio = _getCollateralRatio(_totalDeposited, _totalMinted + maintainMiningAmount);

            // Do nth after minting eUSD because collateral ratio will be in desired range
            if (newCollateralRatio > collateralRatioLower)  {
                _mintEUSD(maintainMiningAmount);
                return;
            }

            // Additional stETH required to deposit to achieve { collateralRatioIdeal } after minting 
            uint256 requiredDepositAmount = _getDepositAmountDelta(_totalDeposited, _totalMinted + maintainMiningAmount);
            // Do nth if not enough idle stETH? What if mint half amount? (i.e. dlp 6.5 -> 6.3 instead of 6, collateral ratio 202 -> 198)
            if (requiredDepositAmount > _totalSupplied - _totalDeposited) return;
            // Deposit stETH and mint eUSD if { collateralRatioIdeal } can be maintained
            _depositStETH(requiredDepositAmount, maintainMiningAmount);

            return;
        } 

        if (dlp <= dlpRatioLower) {
            // Proposed amount to burn
            maintainMiningAmount = (mintValue - currentLpValue * 10000 / dlpRatioIdeal) * 1e20 / vaultWeight;
            // New collateral ratio after burning
            uint256 newCollateralRatio = _getCollateralRatio(_totalDeposited, _totalMinted - maintainMiningAmount);

            _burnEUSD(maintainMiningAmount);

            // Do nth after burning eUSD because collateral ratio will be in desired range
            if (newCollateralRatio < collateralRatioUpper) return;
            // Withdraw stETH from Lybra vault if collateral ratio > { collateralRatioUpper }
            uint256 withdrawableAmount = _getDepositAmountDelta(_totalDeposited, _totalMinted - maintainMiningAmount);
            _withdrawStETH(withdrawableAmount);

            return;
        } 

        /** when dlp ratio lies in desired range (dlpRatioLower < dlpRatioLower < dlpRatioUpper) **/

        // Current collateral ratio
        uint256 collateralRatio = _getCollateralRatio(_totalDeposited, _totalMinted);
        // Amount to deposit to/withdraw from Lybra vault pool
        uint256 depositAmountDelta = _getDepositAmountDelta(_totalDeposited, _totalMinted);
        
        if (collateralRatio >= collateralRatioUpper) {
            _withdrawStETH(depositAmountDelta);
            return;
        } 

        if (collateralRatio <= collateralRatioLower) {
            // If there are insufficient idle stETH in this contract for deposit, 
            // burn eUSD to achieve the ideal collateral ratio
            if (depositAmountDelta > _totalSupplied - _totalDeposited) {
                uint256 amountToBurn = _totalMinted - _totalDeposited * mintPool.getAssetPrice() * 100 / collateralRatioIdeal;
                _burnEUSD(amountToBurn);
            } else {
                // Deposit stETH to increase collateral ratio back to desired range
                _depositStETH(depositAmountDelta, 0);
            }

            return;
        }
    }

    /**
     * @notice Used for determining whether to mint eUSD (hypothetical mint amount calculated regarding dlp ratio)
     * @param _depositedAmount Amount of stETH deposited to Lybra vault
     * @param _mintedAmount Amount of eUSD minted
     * @return Collateral ratio based on given params
     */
    function _getCollateralRatio(uint256 _depositedAmount, uint256 _mintedAmount) private view returns (uint256) {
        return _depositedAmount * mintPool.getAssetPrice() * 100 / _mintedAmount;
    }

    /**
     * @param _depositedAmount Amount of stETH deposited to Lybra vault
     * @param _mintedAmount Amount of eUSD minted
     * @return Amount of stETH to deposit to/withdraw from Lybra vault in order to achieve { collateralRatioIdeal }
     */
    function _getDepositAmountDelta(uint256 _depositedAmount, uint256 _mintedAmount) private view returns (uint256) {
        uint256 newDepositedAmount = collateralRatioIdeal * _mintedAmount / (mintPool.getAssetPrice() * 100); 
        return  newDepositedAmount > _depositedAmount ? 
            newDepositedAmount - _depositedAmount : _depositedAmount - newDepositedAmount;
    }
 
    /**
    * @notice Returns the value of staked LP tokens in the ETH-LBR liquidity pool.
    * @return The value of the staked LP tokens in ETH and LBR.
    */
    function _lpValue(uint256 _lpTokenAmount) private view returns (uint256) {
        (, int lpPrice, , , ) = lpPriceFeed.latestRoundData();
        return _lpTokenAmount * uint256(lpPrice) / 1e8;
    }

    // Lybra restricts deposits with a min. amount of 1 stETH
    function _depositStETH(uint256 _amount, uint256 _eUSDMintAmount) private {
        mintPool.depositAssetToMint(_amount, _eUSDMintAmount);
        totalDeposited += _amount;
        if (_eUSDMintAmount > 0) totalMinted += _eUSDMintAmount;
    }

    function _withdrawStETH(uint256 _amount) private {
        mintPool.withdraw(address(this), _amount);
        totalDeposited -= _amount;
    }

    function _mintEUSD(uint256 _amount) private {
        mintPool.mint(address(this), _amount);
        totalMinted += _amount;
    }

    function _burnEUSD(uint256 _amount) private {
        mintPool.burn(address(this), _amount);
        totalMinted -= _amount;
    }
}