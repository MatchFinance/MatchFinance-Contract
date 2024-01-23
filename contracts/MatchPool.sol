// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./interfaces/LybraInterfaces.sol";
import "./interfaces/DappInterfaces.sol";
import "./interfaces/IRewardManager.sol";

error ExceedAmountAllowed(uint256 _desired, uint256 _actual);
// Insufficient collateral to maintain 200% ratio
error InsufficientCollateral();
error MinLybraDeposit();
error Unauthorized();
error HealthyAccount();
error StakePaused();
error WithdrawPaused();
error BorrowPaused();
error ExceedLimit();

contract MatchPool is Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    // address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // address constant LBR = 0xed1167b6Dc64E8a366DB86F2E952A482D0981ebd;
    // IUniswapV2Router constant ROUTER = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    // Price of ETH-LBR LP token, scaled in 1e8
    AggregatorV3Interface private lpPriceFeed;
    IConfigurator public lybraConfigurator;
    IStakePool public ethlbrStakePool;
    IERC20 public ethlbrLpToken;
    IRewardManager public rewardManager;
    IMintPool[] public mintPools; // Lybra vault for minting eUSD/peUSD

    // Total amount of LP token staked into this contract
    // which is in turn staked into Lybra LP reward pool
    uint256 public totalStaked;
    // User address => staked LP token
    mapping(address => uint256) public staked;

    // Total amount of LSD deposited to this contract, which some might be deposited into Lybra vault for minting eUSD
    // P.S. Do note that NOT all LSD must be deposited to Lybra and this contract can hold idle LSD or
    //      withdraw LSD from Lybra to achieve the desired collateral ratio { collateralRatioIdeal }
    mapping(address => uint256) public totalSupplied;
    // Mint vault => user address => supplied ETH/stETH
    mapping(address => mapping(address => uint256)) public supplied;

    // Total amount of LSD deposited to Lybra vault pool as collateral for minting eUSD/peUSD
    mapping(address => uint256) public totalDeposited;
    // Total amount of eUSD/peUSD minted
    // Users do not determine eUSD/peUSD mint amount, Match Finanace does
    mapping(address => uint256) public totalMinted;
    // Total amount of eUSD/peUSD borrowed out
    mapping(address => uint256) public totalBorrowed;

    // Timestamp where insterest starts counting
    // Accumulated interest will only affect stETH withdrawal and liquidation
    // { totalBorrowed } is still just sum of principal
    struct BorrowInfo {
        uint256 principal; // Amount of eUSD/peUSD borrowed
        uint256 interestAmount; // Amount of eUSD/peUSD borrowed being charged interest
        uint256 accInterest; // Accumulated interest
        uint256 interestTimestamp; // Timestamp since { accInterest } was last updated
    }
    // Mint vault => user address => eUSD/peUSD 'taken out/borrowed' by user
    mapping(address => mapping(address => BorrowInfo)) public borrowed;
    uint256 public borrowRatePerSec; // 10% / 365 days, scaled by 1e18

    uint256 public maxBorrowRatio; // 80e18, scaled by 1e20
    uint256 public globalBorrowRatioThreshold; // 75e18, scaled by 1e20
    uint256 globalBorrowRatioLiuquidation; // 50e18, scaled by 1e20

    // When global borrow ratio < 50%
    uint128 liquidationDiscount; // 105e18, scaled by 1e20
    uint128 closeFactor; // 20e18, scaled by 1e20
    // When global borrow ratio >= 50%
    uint128 liquidationDiscountNormal; // 110e18, scaled by 1e20
    uint128 closeFactorNormal; // 50e18, scaled by 1e20

    uint256 dlpRatioUpper; // 325
    uint256 dlpRatioLower; // 275
    uint256 dlpRatioIdeal; // 300
    uint256 public collateralRatioUpper; // 210e18
    uint256 public collateralRatioLower; // 190e18
    uint256 public collateralRatioIdeal; // 200e18

    bool public stakePaused;
    bool public withdrawPaused;

    // 0 means no limit
    // Cannot stake more dlp beyond this limit (USD value scaled by 1e18)
    uint256 stakeLimit;
    // Cannot supply more LSD beyond this limit (USD value scaled by 1e18)
    uint256 supplyLimit;

    bool public borrowPaused;

    address monitor;

    IesLBRBoost public esLBRBoost;

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

    event LybraLPChanged(address _newToken, address _newOracle, address _newPool);
    event LybraBoostChanged(address _newBoost);
    event LybraConfiguratorChanged(address _newConfig);
    event RewardManagerChanged(address newManager);
    event CollateralRatioChanged(uint256 newLower, uint256 newUpper, uint256 newIdeal);
    event LPStakePaused(bool newState);
    event LPWithdrawPaused(bool newState);
    event eUSDBorrowPaused(bool newState);
    event StakeLimitChanged(uint256 newLimit);
    event SupplyLimitChanged(uint256 newLimit);
    event MonitorChanged(address newMonitor);
    event MintPoolAdded(address newPool);

    event LpStaked(address indexed account, uint256 amount);
    event LpWithdrew(address indexed account, uint256 amount);
    event stETHSupplied(address indexed account, uint256 amount);
    event stETHWithdrew(address indexed account, uint256 amount, uint256 punishment);
    event eUSDBorrowed(address indexed account, uint256 amount);
    event eUSDRepaid(address indexed account, uint256 amount);

    modifier onlyMonitor() {
        _checkMonitor();
        _;
    }

    // function initialize() public initializer {
    //     __Ownable_init();

    //     setDlpRatioRange(275, 325, 300);
    //     setCollateralRatioRange(190e18, 210e18, 200e18);
    //     setBorrowRate(1e17);
    //     setBorrowRatio(85e18, 75e18, 50e18);
    //     setLiquidationParams(105e18, 20e18);
    //     setLiquidationParamsNormal(110e18, 50e18);
    //     setStakeLimit(60000e18);
    //     setSupplyLimit(4000000e18);
    // }

    function initializeTest() public initializer {
        __Ownable_init();
        setCollateralRatioRange(190e18, 210e18, 200e18);
    }

    function getMintPool() public view returns(IMintPool) {
        return mintPools.length > 0 ? mintPools[0] : IMintPool(address(0));
    }

    function setLybraLP(
        address _ethlbrLpToken,
        address _lpOracle,
        address _ethlbrStakePool
    ) external onlyOwner {
        ethlbrLpToken = IERC20(_ethlbrLpToken);
        lpPriceFeed = AggregatorV3Interface(_lpOracle);
        ethlbrStakePool = IStakePool(_ethlbrStakePool);
        emit LybraLPChanged(_ethlbrLpToken, _lpOracle, _ethlbrStakePool);
    }

    function setLybraBoost(address _boost) external onlyOwner {
        esLBRBoost = IesLBRBoost(_boost);
        emit LybraBoostChanged(_boost);
    }

    function setLybraConfigurator(address _config) external onlyOwner {
        lybraConfigurator = IConfigurator(_config);
        emit LybraConfiguratorChanged(_config);
    }

    function setRewardManager(address _rewardManager) external onlyOwner {
        rewardManager = IRewardManager(_rewardManager);
        emit RewardManagerChanged(_rewardManager);
    }

    function setCollateralRatioRange(uint256 _lower, uint256 _upper, uint256 _ideal) public onlyOwner {
        collateralRatioLower = _lower;
        collateralRatioUpper = _upper;
        collateralRatioIdeal = _ideal;
        emit CollateralRatioChanged(_lower, _upper, _ideal);
    }

    // function setBorrowRate(uint256 _borrowRatePerYear) public onlyOwner {
    //     borrowRatePerSec = _borrowRatePerYear / 365 days;
    //     emit BorrowRateChanged(_borrowRatePerYear);
    // }

    // function setBorrowRatio(uint256 _individual, uint256 _global, uint256 _liquidation) public onlyOwner {
    //     maxBorrowRatio = _individual;
    //     globalBorrowRatioThreshold = _global;
    //     globalBorrowRatioLiuquidation = _liquidation;
    //     emit BorrowRatioChanged(_individual, _global, _liquidation);
    // }

    // function setLiquidationParams(uint128 _discount, uint128 _closeFactor) public onlyOwner {
    //     liquidationDiscount = _discount;
    //     closeFactor = _closeFactor;
    //     emit LiquidationParamsChanged(_discount, _closeFactor);
    // }

    // function setLiquidationParamsNormal(uint128 _discount, uint128 _closeFactor) public onlyOwner {
    //     liquidationDiscountNormal = _discount;
    //     closeFactorNormal = _closeFactor;
    //     emit LiquidationParamsNormalChanged(_discount, _closeFactor);
    // }

    function setStakePaused(bool _state) public onlyOwner {
        stakePaused = _state;
        emit LPStakePaused(_state);
    }

    function setWithdrawPaused(bool _state) public onlyOwner {
        withdrawPaused = _state;
        emit LPWithdrawPaused(_state);
    }

    function setBorrowPaused(bool _state) external onlyOwner {
        borrowPaused = _state;
        emit eUSDBorrowPaused(_state);
    }

    function setStakeLimit(uint256 _valueLimit) public onlyOwner {
        stakeLimit = _valueLimit;
        emit StakeLimitChanged(_valueLimit);
    }

    function setSupplyLimit(uint256 _valueLimit) public onlyOwner {
        supplyLimit = _valueLimit;
        emit SupplyLimitChanged(_valueLimit);
    }

    function setMonitor(address _monitor) public onlyOwner {
        monitor = _monitor;
        emit MonitorChanged(_monitor);
    }

    function addMintPool(address _mintPool) external onlyOwner {
        mintPools.push(IMintPool(_mintPool));
        emit MintPoolAdded(_mintPool);
    }

    function boostReward(uint256 _settingId, uint256 _amount) external onlyOwner {
        esLBRBoost.setLockStatus(_settingId, _amount, false);
    }

    function delegateVote(address _delegatee) external onlyOwner {
        IVotes(ethlbrStakePool.rewardsToken()).delegate(_delegatee);
    }
    
    // function zap() external payable {
    //     if (stakePaused) revert StakePaused();

    //     uint256 ethToSwap = msg.value / 2;
    //     address[] memory swapPath = new address[](2);
    //     swapPath[0] = WETH;
    //     swapPath[1] = LBR;
    //     // Swap half of the ETH to LBR
    //     uint256[] memory amounts = ROUTER.swapExactETHForTokens{ value: ethToSwap }(
    //         0, 
    //         swapPath, 
    //         address(this), 
    //         block.timestamp + 1
    //     );
    //     uint256 lbrAmount = amounts[1];

    //     // Add liquidity to get LP token
    //     uint256 ethToAdd = msg.value - ethToSwap;
    //     (uint256 lbrAdded, uint256 ethAdded, uint256 lpAmount) = ROUTER.addLiquidityETH{ value: ethToAdd }(
    //         LBR, 
    //         lbrAmount, 
    //         0, 
    //         0, 
    //         address(this), 
    //         block.timestamp + 1
    //     );

    //     // Refund excess amounts if values of ETH and LBR swapped from ETH are not the same
    //     if (ethToAdd > ethAdded) {
    //         (bool sent,) = (msg.sender).call{ value: ethToAdd - ethAdded }("");
    //         require(sent, "ETH refund failed");
    //     }

    //     if (lbrAmount > lbrAdded) IERC20(LBR).safeTransfer(msg.sender, lbrAmount - lbrAdded);

    //     if (getLpValue(totalStaked + lpAmount) > stakeLimit && stakeLimit != 0) revert ExceedLimit();

    //     rewardManager.dlpUpdateReward(msg.sender);

    //     // Stake LP
    //     uint256 allowance = ethlbrLpToken.allowance(address(this), address(ethlbrStakePool));
    //     if (allowance < lpAmount) ethlbrLpToken.approve(address(ethlbrStakePool), type(uint256).max);

    //     ethlbrStakePool.stake(lpAmount);
    //     totalStaked += lpAmount;
    //     staked[msg.sender] += lpAmount;

    //     emit LpStaked(msg.sender, lpAmount);

    //     mintEUSD();
    // }

    // Stake LBR-ETH LP token
    function stakeLP(uint256 _amount) external {
        if (stakePaused) revert StakePaused();
        if (stakeLimit != 0 && getLpValue(totalStaked + _amount) > stakeLimit) revert ExceedLimit();

        rewardManager.dlpUpdateReward(msg.sender);

        ethlbrLpToken.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 allowance = ethlbrLpToken.allowance(address(this), address(ethlbrStakePool));
        if (allowance < _amount) ethlbrLpToken.approve(address(ethlbrStakePool), type(uint256).max);

        ethlbrStakePool.stake(_amount);
        totalStaked += _amount;
        staked[msg.sender] += _amount;

        emit LpStaked(msg.sender, _amount);
    }

    // Withdraw LBR-ETH LP token
    function withdrawLP(uint256 _amount) external {
        if (withdrawPaused) revert WithdrawPaused();

        rewardManager.dlpUpdateReward(msg.sender);

        uint256 withdrawable = staked[msg.sender];
        if (_amount > withdrawable) revert ExceedAmountAllowed(_amount, withdrawable);

        totalStaked -= _amount;
        staked[msg.sender] -= _amount;

        ethlbrStakePool.withdraw(_amount);
        ethlbrLpToken.safeTransfer(msg.sender, _amount);

        emit LpWithdrew(msg.sender, _amount);
    }

    function supplyETH() external payable {
        IMintPool mintPool = getMintPool();
        address mintPoolAddress = address(mintPool);

        if (
            supplyLimit != 0 && 
            (totalSupplied[mintPoolAddress] + msg.value) * mintPool.getAssetPrice() / 1e18 > supplyLimit
        ) revert ExceedLimit();

        rewardManager.lsdUpdateReward(msg.sender);

        uint256 sharesAmount = ILido(mintPool.getAsset()).submit{value: msg.value}(address(0));
        require(sharesAmount != 0, "ZERO_DEPOSIT");
        supplied[mintPoolAddress][msg.sender] += msg.value;
        totalSupplied[mintPoolAddress] += msg.value;

        emit stETHSupplied(msg.sender, msg.value);

        mintEUSD();
    }

    function supplyStETH(uint256 _amount) external {
        IMintPool mintPool = getMintPool();
        address mintPoolAddress = address(mintPool);

        if (
            supplyLimit != 0 &&
            ((totalSupplied[mintPoolAddress] + _amount) * mintPool.getAssetPrice()) / 1e18 > supplyLimit
        ) revert ExceedLimit();

        rewardManager.lsdUpdateReward(msg.sender);

        IERC20(mintPool.getAsset()).safeTransferFrom(msg.sender, address(this), _amount);
        supplied[mintPoolAddress][msg.sender] += _amount;
        totalSupplied[mintPoolAddress] += _amount;

        emit stETHSupplied(msg.sender, _amount);

        mintEUSD();
    }

    function withdrawStETH(uint256 _amount) external {
        IMintPool mintPool = getMintPool();
        address mintPoolAddress = address(mintPool);
        uint256 tokenPrice = mintPool.getAssetPrice();

        uint256 borrowedEUSD = borrowed[mintPoolAddress][msg.sender].principal;
        uint256 withdrawable = borrowedEUSD > 0 ?
            supplied[mintPoolAddress][msg.sender] - borrowedEUSD * collateralRatioIdeal / maxBorrowRatio
                * 1e18 / tokenPrice : supplied[mintPoolAddress][msg.sender];

        if (_amount > withdrawable) revert ExceedAmountAllowed(_amount, withdrawable);
        uint256 _totalDeposited = totalDeposited[mintPoolAddress];
        uint256 _totalMinted = totalMinted[mintPoolAddress];

        rewardManager.lsdUpdateReward(msg.sender);

        uint256 idleStETH = totalSupplied[mintPoolAddress] - _totalDeposited;
        if (idleStETH > 0.01 ether) idleStETH -= 0.01 ether;
        else idleStETH = 0;

        supplied[mintPoolAddress][msg.sender] -= _amount;
        totalSupplied[mintPoolAddress] -= _amount;

        // Withdraw additional stETH from Lybra vault if contract does not have enough idle stETH
        if (idleStETH < _amount) {
            uint256 withdrawFromLybra = _amount - idleStETH;
            // Amount of stETH that can be withdrawn without burning eUSD
            uint256 withdrawableFromLybra = _getDepositAmountDelta(
                _totalDeposited,
                _totalMinted,
                tokenPrice
            );

            // Burn eUSD to withdraw stETH required
            if (withdrawFromLybra > withdrawableFromLybra) {
                uint256 amountToBurn = _getMintAmountDeltaC(
                    _totalDeposited - withdrawFromLybra,
                    _totalMinted,
                    tokenPrice
                );
                _burnEUSD(amountToBurn);
            }

            // Get withdrawal amount after punishment (if any) from Lybra, accepted by user
            uint256 actualAmount = mintPool.checkWithdrawal(address(this), withdrawFromLybra);
            _withdrawFromLybra(withdrawFromLybra);

            IERC20(mintPool.getAsset()).safeTransfer(msg.sender, idleStETH + actualAmount);

            emit stETHWithdrew(msg.sender, _amount, _amount - actualAmount);
        } else {
            // If contract has enough idle stETH, just transfer out
            IERC20(mintPool.getAsset()).safeTransfer(msg.sender, _amount);

            emit stETHWithdrew(msg.sender, _amount, 0);
        }

        mintEUSD();
    }

    // Take out/borrow eUSD from Match Pool
    function borrowEUSD(uint256 _amount) external {
        if (borrowPaused) revert BorrowPaused();

        IMintPool mintPool = getMintPool();
        address mintPoolAddress = address(mintPool);
        uint256 tokenPrice = mintPool.getAssetPrice();

        uint256 maxBorrow = _getMaxBorrow(supplied[mintPoolAddress][msg.sender], tokenPrice);
        uint256 available = totalMinted[mintPoolAddress] - totalBorrowed[mintPoolAddress];
        uint256 newBorrowAmount = borrowed[mintPoolAddress][msg.sender].principal + _amount;
        if (newBorrowAmount > maxBorrow) revert ExceedAmountAllowed(newBorrowAmount, maxBorrow);
        if (_amount > available) revert ExceedAmountAllowed(_amount, available);

        // No need to update user reward info as there are no changes in supply amount
        rewardManager.lsdUpdateReward(address(0));

        borrowed[mintPoolAddress][msg.sender].principal = newBorrowAmount;
        totalBorrowed[mintPoolAddress] += _amount;

        // Greater than global borrow ratio threshold
        uint256 globalBorrowRatio = totalBorrowed[mintPoolAddress] * 1e20 / 
            _getMaxBorrow(totalSupplied[mintPoolAddress], tokenPrice);
        // Borrow amount has to be charged interest if global borrow ratio threshold is reached
        if (globalBorrowRatio >= globalBorrowRatioThreshold) {
            BorrowInfo storage info = borrowed[mintPoolAddress][msg.sender];

            // Already borrowed before with interest
            if (info.interestAmount != 0) info.accInterest += getAccInterest(msg.sender);
            info.interestAmount += _amount;
            info.interestTimestamp = block.timestamp;
        }

        IERC20(lybraConfigurator.getEUSDAddress()).safeTransfer(msg.sender, _amount);

        emit eUSDBorrowed(msg.sender, _amount);

        mintEUSD();
    }

    function repayEUSD(address _account, uint256 _amount) public {
        address mintPoolAddress = address(getMintPool());

        uint256 oldBorrowAmount = borrowed[mintPoolAddress][_account].principal;
        uint256 newAccInterest = borrowed[mintPoolAddress][_account].accInterest + getAccInterest(_account);
        IERC20 eUSD = IERC20(lybraConfigurator.getEUSDAddress());

        // Just repaying interest
        if (oldBorrowAmount == 0) {
            eUSD.safeTransferFrom(msg.sender, rewardManager.treasury(), _amount);

            if (_amount < newAccInterest) {
                // Not yet repaid all
                borrowed[mintPoolAddress][_account].accInterest = newAccInterest - _amount;
                borrowed[mintPoolAddress][_account].interestTimestamp = block.timestamp;
            } else {
                // Delete info if repaid all
                delete borrowed[mintPoolAddress][_account];  
            }

            emit eUSDRepaid(_account, _amount);

            return;
        }

        // No need to update user reward info as there are no changes in supply amount
        rewardManager.lsdUpdateReward(address(0));

        uint256 newBorrowAmount;
        // Amount for repaying interest after repaying all borrowed eUSD
        uint256 spareAmount;
        if (_amount > oldBorrowAmount) spareAmount = _amount - oldBorrowAmount;
        else newBorrowAmount = oldBorrowAmount - _amount;

        eUSD.safeTransferFrom(msg.sender, address(this), _amount);
        borrowed[mintPoolAddress][_account].principal = newBorrowAmount;
        totalBorrowed[mintPoolAddress] -= (oldBorrowAmount - newBorrowAmount);

        // Prioritize repaying eUSD portion that is charged interest first
        borrowed[mintPoolAddress][_account].interestAmount = _amount > borrowed[mintPoolAddress][_account].interestAmount ? 
            0 : borrowed[mintPoolAddress][_account].interestAmount - _amount;

        if (spareAmount > 0) {
            eUSD.safeTransfer(rewardManager.treasury(), spareAmount);

            if (spareAmount >= newAccInterest) {
                delete borrowed[mintPoolAddress][_account];
            } else {
                borrowed[mintPoolAddress][_account].accInterest = newAccInterest - spareAmount;
                borrowed[mintPoolAddress][_account].interestTimestamp = block.timestamp;
            }
        } else {
            borrowed[mintPoolAddress][_account].accInterest = newAccInterest;
            borrowed[mintPoolAddress][_account].interestTimestamp = block.timestamp;
        }

        emit eUSDRepaid(_account, _amount);

        mintEUSD();
    }

    /**
     * @dev Assumes that dlp ratio is always > 3%.
     *  Restrict to private so that when _mintEUSD()/_depositToLybra is invoked,
     *  reward manager reward calculation must have been updated already.
     */
    function mintEUSD() private {
        address mintPoolAddress = address(getMintPool());
        uint256 tokenPrice = IMintPool(mintPoolAddress).getAssetPrice();
        uint256 _totalDeposited = totalDeposited[mintPoolAddress];
        uint256 _totalMinted = totalMinted[mintPoolAddress];
        uint256 _collateralRatioIdeal = collateralRatioIdeal;
        uint256 totalIdle = totalSupplied[mintPoolAddress] - _totalDeposited;

        // Minus 0.01 ether to compensate for ETH to stETH inconsistent conversion from Lido
        if (totalIdle > 0.01 ether) totalIdle -= 0.01 ether;
        else totalIdle = 0;

        if (_getCollateralRatio(_totalDeposited, _totalMinted, tokenPrice) > _collateralRatioIdeal) {
            if (totalIdle < 1 ether) 
                _mintEUSD(_getMintAmountDeltaC(_totalDeposited, _totalMinted, tokenPrice));
            else 
                _depositToLybra(
                    totalIdle,
                    _getMintAmountDeltaC(_totalDeposited + totalIdle, _totalMinted, tokenPrice)
                );
            return;
        }

        if (totalIdle < 1 ether) return;
        // Can mint more after depositing more, even if current c.r. <= { collateralRatioIdeal }
        if (_getCollateralRatio(_totalDeposited + totalIdle, _totalMinted, tokenPrice) >= _collateralRatioIdeal) 
            _depositToLybra(
                totalIdle,
                _getMintAmountDeltaC(_totalDeposited + totalIdle, _totalMinted, tokenPrice)
            );
    }

    /**
     * @notice Send eUSD rebase reward to Reward Manager
     */
    function claimRebase() external returns (uint256) {
        if (msg.sender != address(rewardManager)) revert Unauthorized();

        address mintPoolAddress = address(getMintPool());

        IERC20 eUSD = IERC20(lybraConfigurator.getEUSDAddress());
        uint256 amountActual = eUSD.balanceOf(address(this));
        uint256 amountRecord = totalMinted[mintPoolAddress] - totalBorrowed[mintPoolAddress];
        uint256 amount;

        if (amountActual > amountRecord) {
            amount = amountActual - amountRecord;
            // Transfer only when there is at least 10 eUSD of reebase reward to save gas
            eUSD.safeTransfer(msg.sender, amount);
        }

        return amount;
    }

    function claimRewards() external {
        if (msg.sender != address(rewardManager)) revert Unauthorized();
        
        ethlbrStakePool.getReward();
        IMining(lybraConfigurator.eUSDMiningIncentives()).getReward();
    }

    /**
     * @notice Get max. amount of eUSD that can be borrowed given amount of stETH supplied
     */
    function _getMaxBorrow(uint256 _suppliedAmount, uint256 _price) private view returns (uint256) {
        return (_suppliedAmount * _price * maxBorrowRatio) / collateralRatioIdeal / 1e18;
    }

    /**
     * @notice Get amount of eUSD borrow interest accrued since last update
     */
    function getAccInterest(address _account) public view returns (uint256) {
        address mintPoolAddress = address(getMintPool());

        BorrowInfo memory info = borrowed[mintPoolAddress][_account];
        uint256 timeDelta = block.timestamp - info.interestTimestamp;
        return info.interestAmount * borrowRatePerSec * timeDelta / 1e18;
    }

    /**
     * @notice Get collateral ratio accordin to given amount
     * @param _depositedAmount Amount of stETH deposited to Lybra vault
     * @param _mintedAmount Amount of eUSD minted
     * @return Collateral ratio based on given params
     */
    function _getCollateralRatio(
        uint256 _depositedAmount,
        uint256 _mintedAmount,
        uint256 _price
    ) private view returns (uint256) {
        if (_mintedAmount == 0) return collateralRatioIdeal;
        else return (_depositedAmount * _price * 100) / _mintedAmount;
    }

    // function _getDlpRatio(uint256 _lpValue, uint256 _mintedAmount, uint256 _vaultWeight) private view returns (uint256) {
    //     if (_mintedAmount == 0) return dlpRatioIdeal;
    //     return _lpValue * 10000 * 1e20 / (_mintedAmount * _vaultWeight);
    // }

    /**
     * @param _depositedAmount Amount of LSD deposited to Lybra vault
     * @param _mintedAmount Amount of eUSD/peUSD minted
     * @return Amount of LSD that can be withdrawn from Lybra vault and collateral ratio remains
     *  above { collateralRatioLower }
     */
    function _getDepositAmountDelta(
        uint256 _depositedAmount,
        uint256 _mintedAmount,
        uint256 _price
    ) private view returns (uint256) {
        uint256 newDepositedAmount = collateralRatioIdeal * _mintedAmount / _price / 100; 
        return newDepositedAmount > _depositedAmount ?
            newDepositedAmount - _depositedAmount + 1 : _depositedAmount - newDepositedAmount;
    }

    /**
     * @param _depositedAmount Amount of stETH deposited to Lybra vault
     * @param _mintedAmount Amount of eUSD minted
     * @return Amount of eUSD to mint from/repay to Lybra vault in order to achieve { collateralRatioIdeal }
     *  1st condition -> mint amount, 2nd condition -> burn amount
     */
    function _getMintAmountDeltaC(
        uint256 _depositedAmount,
        uint256 _mintedAmount,
        uint256 _price
    ) private view returns (uint256) {
        uint256 newMintedAmount = _depositedAmount * _price * 100 / collateralRatioIdeal;
        return newMintedAmount > _mintedAmount ?
            newMintedAmount - _mintedAmount : _mintedAmount - newMintedAmount;
    }

    /**
     * @param _lpValue Value of total LP tokens staked
     * @param _mintedAmount Amount of eUSD minted
     * @param _vaultWeight Vault weight from Lybra configurator
     * @return Amount of eUSD to mint from/repay to Lybra vault in order to achieve { dlpRatioIdeal }
     *  1st condition -> mint amount, 2nd condition -> burn amount
     */
    // function _getMintAmountDeltaD(uint256 _lpValue, uint256 _mintedAmount, uint256 _vaultWeight) private view returns (uint256) {
    //     uint256 oldMintedValue = _mintedAmount * _vaultWeight / 1e20;
    //     uint256 newMintedValue = _lpValue * 10000 / dlpRatioIdeal;
    //     return newMintedValue > oldMintedValue ? 
    //         (newMintedValue - oldMintedValue) * 1e20 / _vaultWeight : (oldMintedValue - newMintedValue) * 1e20 / _vaultWeight;
    // }
 
    /**
     * @param _lpTokenAmount Amount of LP tokens
     * @return The value of staked LP tokens in the ETH-LBR liquidity pool
     */
    function getLpValue(uint256 _lpTokenAmount) public view returns (uint256) {
        (, int lpPrice, , , ) = lpPriceFeed.latestRoundData();
        return _lpTokenAmount * uint256(lpPrice) / 1e8;
    }

    // !! Reward manager must be updated before any function that will change eUSD/peUSD mint amount !!

    function _depositNoCheck(uint256 _amount, uint256 _eUSDMintAmount) private {
        IMintPool mintPool = getMintPool();
        address mintPoolAddress = address(mintPool);

        IERC20 stETH = IERC20(mintPool.getAsset());
        uint256 allowance = stETH.allowance(address(this), mintPoolAddress);
        if (allowance < _amount) stETH.approve(mintPoolAddress, type(uint256).max);

        mintPool.depositAssetToMint(_amount, _eUSDMintAmount);
        totalDeposited[mintPoolAddress] += _amount;
        if (_eUSDMintAmount > 0) totalMinted[mintPoolAddress] += _eUSDMintAmount;
    }

    /**
     * @notice Lybra restricts deposits with a min. amount of 1 stETH
     */
    function _depositToLybra(uint256 _amount, uint256 _eUSDMintAmount) private {
        if (_amount < 1 ether) revert MinLybraDeposit();
        _depositNoCheck(_amount, _eUSDMintAmount);
    }

    /** 
     * @notice Match Finance will only withdraw spare stETH from Lybra when there is no punishment.
     *  Punished withdrawals will only be initiated by users whole are willing to take the loss,
     *  as totalSupplied and totalDeposited are updated in the same tx for such situation,
     *  the problem of value mismatch (insufiicient balance for withdrawal) is avoided
     */
    function _withdrawFromLybra(uint256 _amount) private {
        IMintPool mintPool = getMintPool();
        address mintPoolAddress = address(mintPool);

        uint256 collateralRatioAfter = _getCollateralRatio(
            totalDeposited[mintPoolAddress] - _amount,
            totalMinted[mintPoolAddress],
            mintPool.getAssetPrice()
        );
        // Withdraw only until collateral ratio reaches { collateralRatioLower }
        if (collateralRatioAfter < collateralRatioLower) revert InsufficientCollateral();

        mintPool.withdraw(address(this), _amount);
        totalDeposited[mintPoolAddress] -= _amount;
    }

    function _mintEUSD(uint256 _amount) private {
        if (_amount == 0) return;

        IMintPool mintPool = getMintPool();
        address mintPoolAddress = address(mintPool);

        mintPool.mint(address(this), _amount);
        totalMinted[mintPoolAddress] += _amount;
    }

    function _burnEUSD(uint256 _amount) private {
        IMintPool mintPool = getMintPool();
        address mintPoolAddress = address(mintPool);

        mintPool.burn(address(this), _amount);
        totalMinted[mintPoolAddress] -= _amount;
    }

    function _max(uint256 x, uint256 y) private pure returns (uint256) {
        return x > y ? x : y;
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x < y ? x : y;
    }

    function _checkMonitor() private view {
        if (msg.sender != monitor) revert Unauthorized();
    }

    function monitorDeposit(uint256 _amount, uint256 _eUSDMintAmount) external onlyMonitor {
        if (_eUSDMintAmount > 0) rewardManager.lsdUpdateReward(address(0));
        _depositNoCheck(_amount, _eUSDMintAmount);
    }

    function monitorWithdraw(uint256 _amount) external onlyMonitor {
        IMintPool mintPool = getMintPool();
        address mintPoolAddress = address(mintPool);
        
        mintPool.withdraw(address(this), _amount);
        totalDeposited[mintPoolAddress] -= _amount;
    }

    function monitorMint(uint256 _amount) external onlyMonitor {
        rewardManager.lsdUpdateReward(address(0));
        _mintEUSD(_amount);
    }

    function monitorBurn(uint256 _amount) external onlyMonitor {
        rewardManager.lsdUpdateReward(address(0));
        _burnEUSD(_amount);
    }

    /**
     * @notice Verifies that the signer is the owner of the signing contract.
     */
    function isValidSignature(
        bytes32 _hash,
        bytes calldata _signature
    ) external view returns (bytes4) {
        // Validate signatures
        require(ECDSA.recover(_hash, _signature) == owner(), "invalid signer");
        return 0x1626ba7e;
    }
}
