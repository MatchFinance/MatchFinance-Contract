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
    function checkWithdrawal(address user, uint256 amount) external view returns (uint256 withdrawal);
}

interface IConfigurator {
    function getVaultWeight(address pool) external view returns (uint256);
}

error ExceedAmountAllowed(uint256 _desired, uint256 _actual);
// Insufficient collateral to maintain 200% ratio
error InsufficientCollateral();
error MinLybraDeposit();

contract MatchPool is Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    AggregatorV3Interface private lpPriceFeed; // https://etherscan.io/tx/0x8c638a0998f3b6da40bb1f91602062c46b699150ad70f3b8f07b482df8367102
    IConfigurator public lybraConfigurator;
    IMintPool public mintPool; // stETH vault for minting eUSD
    IStakePool public ethlbrStakePool;
    IERC20 public ethlbrLpToken;

    // Total amount of LP token staked into this contract
    // which is in turn staked into Lybra LP reward pool
    uint256 public totalStaked;
    // User address => staked LP token
    mapping(address => uint256) public staked;

    // Total amount of ETH/stETH deposited to this contract, which some might be deposited into Lybra vault for minting eUSD
    // P.S. Do note that NOT all ETH/stETH must be deposited to Lybra and this contract can hold idle ETH/stETH or
    //      withdraw stETH from Lybra to achieve the desired collateral ratio { collateralRatioIdeal }
    uint256 public totalSupplied;
    // Total amount of stETH deposited to Lybra vault pool as collateral for minting eUSD
    uint256 public totalDeposited;
    // Total amount of eUSD minted
    uint256 public totalMinted;

    // User address => supplied ETH/stETH
    mapping(address => uint256) public supplied;
    // User address => eUSD 'taken out/borrowed' by user
    // Users do not determine eUSD mint amount, Match Finanace does
    mapping(address => uint256) public borrowedEUSD;

    uint256 private dlpRatioUpper; // 650
    uint256 private dlpRatioLower; // 550
    uint256 private dlpRatioIdeal; // 600
    uint256 private collateralRatioUpper; // 210e18
    uint256 private collateralRatioLower; // 190e18
    uint256 private collateralRatioIdeal; // 200e18

    // Used for calculations in adjustEUSDAmount() only
    struct Calc {
        // Amount of eUSD to mint to achieve { dlpRatioIdeal }
        uint256 mintAmountGivenDlp;
        // Amount of eUSD to mint to achieve { collateralRatioIdeal }
        uint256 mintAmountGivenCollateral;
        // Amount of eUSD to burn to achieve { dlpRatioIdeal }
        uint256 burnAmountGivenDlp;
        // Amount of eUSD to burn to achieve { collateralRatioIdeal }
        uint256 burnAmountGivenCollateral;
        // Amount of stETH to deposit to achieve { collateralRatioIdeal }
        uint256 amountToDeposit;
        // Reference: Lybra EUSDMiningIncentives.sol { stakeOf(address user) }, line 173
        // Vault weight of stETH mint pool, scaled by 1e20
        uint256 vaultWeight;
        // Value of staked LP tokens, scaled by 1e18
        uint256 currentLpValue;
        uint256 dlpRatioCurrent;
        uint256 collateralRatioCurrent;
    }

    event LpOracleChanged(address newOracle, uint256 time);
    event DlpRatioChanged(uint256 newLower, uint256 newUpper, uint256 newIdeal);
    event CollateralRatioChanged(uint256 newLower, uint256 newUpper, uint256 newIdeal);
    event LpStaked(address indexed account, uint256 amount);
    event LpWithdrew(address indexed account, uint256 amount);
    event stETHSupplied(address indexed account, uint256 amount);
    event stETHWithdrew(address indexed account, uint256 amount, uint256 punishment);

    function initialize() public initializer {
        __Ownable_init();

        individualBorrowRatio = 85;
        globalBorrowRatio = 75;
        setDlpRatioRange(550, 650, 600);
        setCollateralRatioRange(190e18, 210e18, 200e18);
    }

    function setLP(address _ethlbrLpToken) external onlyOwner {
        ethlbrLpToken = IERC20(_ethlbrLpToken);
    }

    function setLybraContracts(
        address _ethlbrStakePool,
        address _stETHMintPool,
        address _configurator
    ) external onlyOwner {
        ethlbrStakePool = IStakePool(_ethlbrStakePool);
        mintPool = IMintPool(_stETHMintPool);
        lybraConfigurator = IConfigurator(_configurator);
    }

    function setLpOracle(address _lpOracle) external onlyOwner {
        lpPriceFeed = AggregatorV3Interface(_lpOracle);
        emit LpOracleChanged(_lpOracle, block.timestamp);
    }

    function setDlpRatioRange(uint256 _lower, uint256 _upper, uint256 _ideal) public onlyOwner {
        dlpRatioLower = _lower;
        dlpRatioUpper = _upper;
        dlpRatioIdeal = _ideal;
        emit DlpRatioChanged(_lower, _upper, _ideal);
    }

    function setCollateralRatioRange(uint256 _lower, uint256 _upper, uint256 _ideal) public onlyOwner {
        collateralRatioLower = _lower;
        collateralRatioUpper = _upper;
        collateralRatioIdeal = _ideal;
        emit CollateralRatioChanged(_lower, _upper, _ideal);
    }

    // Stake LBR-ETH LP token
    function stakeLP(uint256 _amount) external {
        ethlbrLpToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 allowance = ethlbrLpToken.allowance(address(this), address(ethlbrStakePool));
        if (allowance < _amount) ethlbrLpToken.approve(address(ethlbrStakePool), type(uint256).max);
        ethlbrStakePool.stake(_amount);
        totalStaked += _amount;
        staked[msg.sender] += _amount;

        emit LpStaked(msg.sender, _amount);

        // adjustEUSDAmount();
    }

    // Withdraw LBR-ETH LP token
    function withdrawLP(uint256 _amount) external {
        uint256 withdrawable = staked[msg.sender];
        if (_amount > withdrawable) revert ExceedAmountAllowed(_amount, withdrawable);

        totalStaked -= _amount;
        staked[msg.sender] -= _amount;

        ethlbrStakePool.withdraw(_amount);
        ethlbrLpToken.safeTransfer(msg.sender, _amount);

        emit LpWithdrew(msg.sender, _amount);

        // adjustEUSDAmount();
    }

    function supplyETH() external payable {
        uint256 sharesAmount = ILido(address(mintPool.collateralAsset())).submit{value: msg.value}(address(0));
        require(sharesAmount != 0, "ZERO_DEPOSIT");
        totalSupplied += msg.value;
        supplied[msg.sender] += msg.value;

        emit stETHSupplied(msg.sender, msg.value);
    }

    function supplyStETH(uint256 _amount) external {
        mintPool.collateralAsset().safeTransferFrom(msg.sender, address(this), _amount);
        totalSupplied += _amount;
        supplied[msg.sender] += _amount;

        emit stETHSupplied(msg.sender, _amount);
    }

    function withdrawStETH(uint256 _amount) external {
        uint256 withdrawable = supplied[msg.sender];
        if (_amount > withdrawable) revert ExceedAmountAllowed(_amount, withdrawable);

        uint256 idleStETH = totalSupplied - totalDeposited;

        totalSupplied -= _amount;
        supplied[msg.sender] -= _amount;

        // Withdraw additional stETH from Lybra vault if contract does not have enough idle stETH
        if (idleStETH < _amount) {
            uint256 withdrawFromLybra = _amount - idleStETH;
            // Get withdrawal amount after punishment (if any) from Lybra
            uint256 actualAmount = mintPool.checkWithdrawal(address(this), withdrawFromLybra);
            _withdrawFromLybra(withdrawFromLybra);

            mintPool.collateralAsset().safeTransfer(msg.sender, idleStETH + actualAmount);

            emit stETHWithdrew(msg.sender, _amount, withdrawFromLybra - actualAmount);

            return;
        }

        // If contract has enough idle stETH, just transfer out
        mintPool.collateralAsset().safeTransfer(msg.sender, _amount);

        emit stETHWithdrew(msg.sender, _amount, 0);
    }

    // Take out/borrow eUSD from Match Pool
    // function borrowEUSD(uint256 _amount) external {
    // }

    /**
     * @notice Implementation of dynamic eUSD minting mechanism and collateral ratio control
     */
    function adjustEUSDAmount() public {
        Calc memory calc;
        // Amount of ETH/stETH supplied by users to this contract
        uint256 _totalSupplied = totalSupplied;
        // Original amount of total deposits
        uint256 _totalDeposited = totalDeposited;
        // Original amount of total eUSD minted
        uint256 _totalMinted = totalMinted;
        // Value of staked LP tokens, scaled by 1e18
        calc.currentLpValue = _getLpValue(totalStaked);
        calc.vaultWeight = lybraConfigurator.getVaultWeight(address(mintPool));

        // First mint
        if (_totalDeposited == 0 && _totalMinted == 0) {
            if (_totalSupplied < 1 ether) return;

            _mintMin(calc, _totalMinted, _totalDeposited, _totalSupplied);
            return;
        }

        calc.dlpRatioCurrent = _getDlpRatio(calc.currentLpValue, _totalMinted, calc.vaultWeight);
        // Burn eUSD all at once instead of multiple separated txs
        uint256 amountToBurnTotal;

        // When dlp ratio falls short of ideal, eUSD will be burnt no matter what the collateral ratio is
        if (calc.dlpRatioCurrent <= dlpRatioLower) {
            calc.burnAmountGivenDlp = _getMintAmountDeltaD(calc.currentLpValue, _totalMinted, calc.vaultWeight);
            amountToBurnTotal += calc.burnAmountGivenDlp;
            _totalMinted -= calc.burnAmountGivenDlp;

            // Update dlp ratio, from less than { dlpRatioLower }, to { dlpRatioIdeal }
            calc.dlpRatioCurrent = dlpRatioIdeal;
        }

        // Amount stETH currently idle in Match Pool
        uint256 totalIdle = _totalSupplied - _totalDeposited;
        calc.collateralRatioCurrent = _getCollateralRatio(_totalDeposited, _totalMinted);

        // When collateral ratio falls short of ideal
        // Option 1: Deposit to increasae collateral ratio, doesn't affect dlp ratio
        // Option 2: Burn eUSD to increase collateral ratio
        if (calc.collateralRatioCurrent < collateralRatioIdeal) {
            // Must be Option 2 due to Lybra deposit min. requirement
            if (totalIdle < 1 ether) {
                calc.burnAmountGivenCollateral = _getMintAmountDeltaC(_totalDeposited, _totalMinted);
                amountToBurnTotal += calc.burnAmountGivenCollateral;
                _burnEUSD(amountToBurnTotal);
                // Result: dlp ratio > 5.5%, collateral ratio = 200%
                return;
            } 

            // Option 1
            calc.amountToDeposit = _getDepositAmountDelta(_totalDeposited, _totalMinted);

            // 1 ether <= totalIdle < amountToDeposit
            // Deposit all idle stETH and burn some eUSD to achieve { collateralRatioIdeal }
            if (calc.amountToDeposit > totalIdle) {
                _depositToLybra(totalIdle, 0);
                _totalDeposited += totalIdle;

                calc.burnAmountGivenCollateral = _getMintAmountDeltaC(_totalDeposited, _totalMinted);
                amountToBurnTotal += calc.burnAmountGivenCollateral;
                _burnEUSD(amountToBurnTotal);
                // Result: dlp ratio > 5.5%, collateral ratio = 200%
                return;
            }

            // If dlp ratio required burning (line 260)
            if (amountToBurnTotal > 0) _burnEUSD(amountToBurnTotal);

            // 1 ether <= totalIdle == amountToDeposit
            if (calc.amountToDeposit == totalIdle) {
                _depositToLybra(calc.amountToDeposit, 0);
                // Result: dlp ratio > 5.5%, collateral ratio = 200%
                return;
            }

            // amountToDeposit < 1 ether <= totalIdle, MUST over-collateralize
            // 1 ether < amountToDeposit < totalIdle, MIGHT over-collateralize

            // Cannot mint more even if there is over-collateralization, disallowed by dlp ratio
            if (calc.dlpRatioCurrent < dlpRatioUpper) {
                _depositToLybra(_max(calc.amountToDeposit, 1 ether), 0);
                // Result: 5.5% < dlp ratio < 6.5%, collateral ratio >= 200%
                return;
            }

            // If (dlpRatioCurrent >= dlpRatioUpper) -> mint more to maximize reward
            _mintMin(calc, _totalMinted, _totalDeposited, _totalDeposited + totalIdle);
            return;
        }

        // If dlp ratio required burning (line 260)
        // (dlp ratio == { dlpRatioIdeal } && collateral ratio >= { collateralRatioIdeal })
        if (amountToBurnTotal > 0) {
            _burnEUSD(amountToBurnTotal);
            if (calc.collateralRatioCurrent > collateralRatioIdeal) _withdrawNoPunish(_totalDeposited, _totalMinted);
            // Result: dlp ratio = 6%, collateral ratio = 200%
            return;
        }

        if (calc.collateralRatioCurrent == collateralRatioIdeal) {
            // Mint condition: (dlpRatioCurrent >= dlpRatioUpper && totalIdle >= 1 ether)
            // Result: dlp ratio > 5.5%, collateral ratio = 200%
            if (calc.dlpRatioCurrent < dlpRatioUpper || totalIdle < 1 ether) return;
            // Deposit more and mint more
            _mintMin(calc, _totalMinted, _totalDeposited, _totalDeposited + totalIdle);
            return;
        }

        /** if (calc.collateralRatioCurrent > { collateralRatioIdeal }) **/

        // Minting disallowed by dlp ratio
        if (calc.dlpRatioCurrent < dlpRatioUpper) {
            _withdrawNoPunish(_totalDeposited, _totalMinted);
            // Result: dlp ratio > 5.5%, collateral ratio = 200%
            return;
        }

        calc.mintAmountGivenDlp = _getMintAmountDeltaD(calc.currentLpValue, _totalMinted, calc.vaultWeight);
        uint256 maxMintAmountWithoutDeposit = _getMintAmountDeltaC(_totalDeposited, _totalMinted);

        // Can mint more by depositing more
        if (calc.mintAmountGivenDlp > maxMintAmountWithoutDeposit) {
            // Insufficient idle stETH, so mint only amount that doesn't require deposit
            // Result: dlp ratio > 6%, collateral ratio = 200%
            if (totalIdle < 1 ether) _mintEUSD(maxMintAmountWithoutDeposit);
            // Deposit more and mint more
            else _mintMin(calc, _totalMinted, _totalDeposited, _totalDeposited + totalIdle);
            return;
        }

        // Result: dlp ratio = 6%, collateral ratio >= 200%
        _mintEUSD(calc.mintAmountGivenDlp);
        if (maxMintAmountWithoutDeposit > calc.mintAmountGivenDlp) 
            _withdrawNoPunish(_totalDeposited, _totalMinted + calc.mintAmountGivenDlp);

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

    function _getDlpRatio(uint256 _lpValue, uint256 _mintedAmount, uint256 _vaultWeight) private pure returns (uint256) {
        return _lpValue * 10000 * 1e20 / (_mintedAmount * _vaultWeight);
    }

    /**
     * @param _depositedAmount Amount of stETH deposited to Lybra vault
     * @param _mintedAmount Amount of eUSD minted
     * @return Amount of stETH to deposit to/withdraw from Lybra vault in order to achieve { collateralRatioIdeal }
     *  1st condition -> deposit amount, 2nd condition -> withdraw amount
     */
    function _getDepositAmountDelta(uint256 _depositedAmount, uint256 _mintedAmount) private view returns (uint256) {
        uint256 newDepositedAmount = collateralRatioIdeal * _mintedAmount / (mintPool.getAssetPrice() * 100); 
        return newDepositedAmount > _depositedAmount ?
            newDepositedAmount - _depositedAmount : _depositedAmount - newDepositedAmount;
    }

    // Amount of eUSD to mint/burn with regards to collateral ratio
    // 1st condition -> mint amount, 2nd condition -> burn amount
    function _getMintAmountDeltaC(uint256 _depositedAmount, uint256 _mintedAmount) private view returns (uint256) {
        uint256 newMintedAmount = _depositedAmount * mintPool.getAssetPrice() * 100 / collateralRatioIdeal;
        return newMintedAmount > _mintedAmount ?
            newMintedAmount - _mintedAmount : _mintedAmount - newMintedAmount;
    }

    // Amount of eUSD to mint/burn with regards to dlp ratio
    // 1st condition -> mint amount, 2nd condition -> burn amount
    function _getMintAmountDeltaD(uint256 _lpValue, uint256 _mintedAmount, uint256 _vaultWeight) private view returns (uint256) {
        uint256 oldMintedValue = _mintedAmount * _vaultWeight / 1e20;
        uint256 newMintedValue = _lpValue * 10000 / dlpRatioIdeal;
        return newMintedValue > oldMintedValue ? 
            (newMintedValue - oldMintedValue) * 1e20 / _vaultWeight : (oldMintedValue - newMintedValue) * 1e20 / _vaultWeight;
    }
 
    /**
    * @notice Returns the value of staked LP tokens in the ETH-LBR liquidity pool.
    * @return The value of the staked LP tokens in ETH and LBR.
    */
    function _getLpValue(uint256 _lpTokenAmount) private view returns (uint256) {
        (, int lpPrice, , , ) = lpPriceFeed.latestRoundData();
        return _lpTokenAmount * uint256(lpPrice) / 1e8;
    }

    // Lybra restricts deposits with a min. amount of 1 stETH
    function _depositToLybra(uint256 _amount, uint256 _eUSDMintAmount) private {
        if (_amount < 1 ether) revert MinLybraDeposit();
        mintPool.depositAssetToMint(_amount, _eUSDMintAmount);
        totalDeposited += _amount;
        if (_eUSDMintAmount > 0) totalMinted += _eUSDMintAmount;
    }

    /** 
     * @notice Match Finance will only withdraw spare stETH from Lybra when there is no punishment.
     *  Punished withdrawals will only be initiated by users whole are willing to take the loss,
     *  as totalSupplied and totalDeposited are updated in the same tx for such situation,
     *  the problem of value mismatch (insufiicient balance for withdrawal) is avoided
     */
    function _withdrawFromLybra(uint256 _amount) private {
        uint256 collateralRatioAfter = _getCollateralRatio(totalDeposited - _amount, totalMinted);
        // Withdraw only if collateral ratio remains above { collateralRatioIdeal }
        if (collateralRatioAfter < collateralRatioIdeal) revert InsufficientCollateral();

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

    function _max(uint256 x, uint256 y) private pure returns (uint256) {
        return x > y ? x : y;
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x < y ? x : y;
    }

    // Decides how much eUSD to mint,
    // when dlp ratio >= { dlpRatioIdeal } && collateral ratio > 200%
    /**
     * @notice _depositedAmount == _fullDeposit when idle stETH less than min. deposit requirement
     * @param _fullDeposit Max amount that can be deposited
     */
    function _mintMin(
        Calc memory calc, 
        uint256 _mintedAmount, 
        uint256 _depositedAmount, 
        uint256 _fullDeposit
    ) private {
        // If (dlpRatioCurrent >= dlpRatioUpper) -> mint more to maximize reward
        calc.mintAmountGivenDlp = _getMintAmountDeltaD(calc.currentLpValue, _mintedAmount, calc.vaultWeight);
        // Amount to mint to achieve { collateralRatioIdeal } after depositing all idle stETH
        calc.mintAmountGivenCollateral = _getMintAmountDeltaC(_fullDeposit, _mintedAmount);
            
        // Mint: min(mintAmountGivenDlp, mintAmountGivenCollateral)
        if (calc.mintAmountGivenDlp > calc.mintAmountGivenCollateral) {
            _depositToLybra(_fullDeposit - _depositedAmount, calc.mintAmountGivenCollateral);
            // Result: dlp ratio > 6%, collateral ratio = 200%
            return;
        }

        // Amount to deposit for 200% colalteral ratio given that { mintAmountGivenDlp } eUSD will be minted
        calc.amountToDeposit = _getDepositAmountDelta(_depositedAmount, calc.mintAmountGivenDlp);
        // Accept over-collateralization, i.e. deposit at least 1 ether
        _depositToLybra(_max(calc.amountToDeposit, 1 ether), calc.mintAmountGivenDlp);
        // Result: dlp ratio = 6%, collateral ratio >= 200%
        return;
    }

    // Withdraw over-collateralized stETH from Lybra, so users can withdraw without punishment
    // Executed only when dlp ratio < { dlpRatioUpper } && collateral ratio > { collateralRatioIdeal }
    function _withdrawNoPunish(uint256 _depositedAmount, uint256 _mintedAmount) private {
        uint256 amountToWithdraw = _getDepositAmountDelta(_depositedAmount, _mintedAmount);
        if (mintPool.checkWithdrawal(address(this), amountToWithdraw) == amountToWithdraw) {
            mintPool.withdraw(address(this), amountToWithdraw);
            totalDeposited -= amountToWithdraw;
        }
    }
}
