// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
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

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant LBR = 0xed1167b6Dc64E8a366DB86F2E952A482D0981ebd;
    IUniswapV2Router constant ROUTER = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    // Price of ETH-LBR LP token, scaled in 1e8
    AggregatorV3Interface private lpPriceFeed;
    IConfigurator public lybraConfigurator;
    IStakePool public ethlbrStakePool;
    IERC20 public ethlbrLpToken;
    IRewardManager public rewardManager;
    IMintPool[] mintPools; // Lybra vault for minting eUSD/peUSD

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
        uint256 interestAmount; // Amount of eUSD/peUSD borrowed being charged interest, UNUSED
        uint256 accInterest; // Accumulated interest
        uint256 interestIndex; // Last updated { borrowIndex }
    }
    // Mint vault => user address => eUSD/peUSD 'taken out/borrowed' by user
    mapping(address => mapping(address => BorrowInfo)) public borrowed;
    uint256 public borrowRatePerSec; // 10% / 365 days, scaled by 1e18

    uint256 public maxBorrowRatio; // 80e18, scaled by 1e20
    uint256 public globalBorrowRatioThreshold; // 75e18, scaled by 1e20
    uint256 public globalBorrowRatioLiquidation; // 50e18, scaled by 1e20

    // When global borrow ratio < 50%
    uint128 public liquidationDiscount; // 105e18, scaled by 1e20
    uint128 public closeFactor; // 20e18, scaled by 1e20
    // When global borrow ratio >= 50%
    uint128 public liquidationDiscountNormal; // 110e18, scaled by 1e20
    uint128 public closeFactorNormal; // 50e18, scaled by 1e20

    uint256 public dlpRatioUpper; // 325
    uint256 public dlpRatioLower; // 275
    uint256 public dlpRatioIdeal; // 300
    uint256 public collateralRatioLower; // 190e18
    uint256 public collateralRatioLiquidate; // 150e18
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

    // Mint pool => deposit helper
    mapping(address => IDepositHelper) depositHelpers;
    mapping(address => bool) public isRebase;

    IesLBRBoost public esLBRBoost;

    struct PoolInfo {
        IMintPool mintPool;
        address mintPoolAddress;
        bool isRebasePool;
        uint256 tokenPrice;
    }

    // !! @modify Code added by Eric 20231030
    address public lybraProtocolRevenue;
    address public stakingPool;

    // Record supply amounts in terms of stETH for reward calculation
    mapping(address => uint256) public totalSuppliedReward;
    mapping(address => mapping(address => uint256)) public suppliedReward;

    struct InterestTracker {
        uint128 interestIndexGlobal;
        uint128 lastAccrualtime;
    }
    mapping(address => InterestTracker) interestTracker;

    // ---------------------------------------------------------------------------------------- //
    // *************************************** Events ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    event LPChanged(address newLp);
    event LybraContractsChanged(
        address newStakePool, 
        address newConfigurator, 
        address newBoost, 
        address newProtocolRevenue
    );
    event mesLBRStakingPoolChanged(address newPool);
    event LPOracleChanged(address newOracle);
    event RewardManagerChanged(address newManager);
    event DlpRatioChanged(uint256 newLower, uint256 newUpper, uint256 newIdeal);
    event CollateralRatioChanged(uint256 newLiquidate, uint256 newLower, uint256 newIdeal);
    event BorrowRateChanged(uint256 newRate);
    event BorrowRatioChanged(
        uint256 newMax,
        uint256 newGlobalThreshold,
        uint256 newGlobalLiquidation
    );
    event LiquidationParamsChanged(uint128 newDiscount, uint128 newCloseFactor);
    event LiquidationParamsNormalChanged(uint128 newDiscount, uint128 newCloseFactor);
    event LPStakePaused(bool newState);
    event LPWithdrawPaused(bool newState);
    event eUSDBorrowPaused(bool newState);
    event StakeLimitChanged(uint256 newLimit);
    event SupplyLimitChanged(uint256 newLimit);
    event MonitorChanged(address newMonitor);
    event MintPoolAdded(address newMintPool);
    event DepositHelperChanged(address mintPool, address helper);
    event PoolTypeChanged(address mintPool, bool isRebase);

    event LpStaked(address indexed account, uint256 amount);
    event LpWithdrew(address indexed account, uint256 amount);
    event ETHSupplied(address mintPool, address indexed account, uint256 amount);
    event LSDSupplied(address mintPool, address indexed account, uint256 amount);
    event LSDWithdrew(
        address mintPool,
        address indexed account,
        uint256 amount,
        uint256 punishment
    );
    event USDBorrowed(address asset, address indexed account, uint256 amount);
    event USDRepaid(address asset, address indexed account, uint256 amount);
    event Liquidated(
        address mintPool,
        address indexed account,
        address indexed liquidator,
        uint256 seizeAmount
    );

    // ---------------------------------------------------------------------------------------- //
    // ************************************** Modifiers *************************************** //
    // ---------------------------------------------------------------------------------------- //

    modifier onlyMonitor() {
        if (msg.sender != monitor) revert Unauthorized();
        _;
    }

    function initialize() public initializer {
        __Ownable_init();

        setDlpRatioRange(275, 325, 300);
        setCollateralRatioRange(190e18, 210e18, 200e18);
        setBorrowRate(1e17);
        setBorrowRatio(80e18, 75e18, 50e18);
        setLiquidationParams(105e18, 20e18);
        setLiquidationParamsNormal(110e18, 50e18);
        setStakeLimit(60000e18);
        setSupplyLimit(4000000e18);
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ View Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    function getMintPools() public view returns (IMintPool[] memory) {
        return mintPools;
    }

    /**
     * @param _lpTokenAmount Amount of LP tokens
     * @return The value of staked LP tokens in the ETH-LBR liquidity pool
     */
    function getLpValue(uint256 _lpTokenAmount) public view returns (uint256) {
        (, int lpPrice, , , ) = lpPriceFeed.latestRoundData();
        return (_lpTokenAmount * uint256(lpPrice)) / 1e8;
    }

    /**
     * @notice Get amount of eUSD/peUSD borrowed plus interest accrued till now
     */
    function getBorrowWithInterest(
        address _mintPoolAddress,
        address _account
    ) public view returns (uint256) {
        BorrowInfo memory borrowInfo = borrowed[_mintPoolAddress][_account];

        if (borrowInfo.principal == 0) return borrowInfo.accInterest;
        (uint128 interestIndexCur,) = _getInterestIndexCur(_mintPoolAddress);
        return borrowInfo.principal * interestIndexCur /
            borrowInfo.interestIndex + borrowInfo.accInterest;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Set Functions ************************************* //
    // ---------------------------------------------------------------------------------------- //

    function setLP(address _ethlbrLpToken) external onlyOwner {
        ethlbrLpToken = IERC20(_ethlbrLpToken);
        emit LPChanged(_ethlbrLpToken);
    }

    function setLybraContracts(
        address _ethlbrStakePool,
        address _configurator,
        address _boost,
        address _protocolRevenue
    ) external onlyOwner {
        ethlbrStakePool = IStakePool(_ethlbrStakePool);
        lybraConfigurator = IConfigurator(_configurator);
        esLBRBoost = IesLBRBoost(_boost);
        lybraProtocolRevenue = _protocolRevenue;
        emit LybraContractsChanged(_ethlbrStakePool, _configurator, _boost, _protocolRevenue);
    }

    function setMeslbrStakingPool(address _stakingPool) external onlyOwner {
        stakingPool = _stakingPool;
        emit mesLBRStakingPoolChanged(_stakingPool);
    }

    function setLpOracle(address _lpOracle) external onlyOwner {
        lpPriceFeed = AggregatorV3Interface(_lpOracle);
        emit LPOracleChanged(_lpOracle);
    }

    function setRewardManager(address _rewardManager) external onlyOwner {
        rewardManager = IRewardManager(_rewardManager);
        emit RewardManagerChanged(_rewardManager);
    }

    function setDlpRatioRange(
        uint256 _lower,
        uint256 _upper,
        uint256 _ideal
    ) public onlyOwner {
        dlpRatioLower = _lower;
        dlpRatioUpper = _upper;
        dlpRatioIdeal = _ideal;
        emit DlpRatioChanged(_lower, _upper, _ideal);
    }

    function setCollateralRatioRange(
        uint256 _liquidate,
        uint256 _lower,
        uint256 _ideal
    ) public onlyOwner {
        collateralRatioLiquidate = _liquidate;
        collateralRatioLower = _lower;
        collateralRatioIdeal = _ideal;
        emit CollateralRatioChanged(_liquidate, _lower, _ideal);
    }

    function setBorrowRate(uint256 _borrowRatePerYear) public onlyOwner {
        borrowRatePerSec = _borrowRatePerYear / 365 days;
        emit BorrowRateChanged(_borrowRatePerYear);
    }

    function setBorrowRatio(
        uint256 _individual,
        uint256 _global,
        uint256 _liquidation
    ) public onlyOwner {
        maxBorrowRatio = _individual;
        globalBorrowRatioThreshold = _global;
        globalBorrowRatioLiquidation = _liquidation;
        emit BorrowRatioChanged(_individual, _global, _liquidation);
    }

    function setLiquidationParams(
        uint128 _discount,
        uint128 _closeFactor
    ) public onlyOwner {
        liquidationDiscount = _discount;
        closeFactor = _closeFactor;
        emit LiquidationParamsChanged(_discount, _closeFactor);
    }

    function setLiquidationParamsNormal(
        uint128 _discount,
        uint128 _closeFactor
    ) public onlyOwner {
        liquidationDiscountNormal = _discount;
        closeFactorNormal = _closeFactor;
        emit LiquidationParamsNormalChanged(_discount, _closeFactor);
    }

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

    function addMintPool(
        address _mintPool,
        address _helper,
        bool _isRebase
    ) external onlyOwner {
        mintPools.push(IMintPool(_mintPool));
        depositHelpers[_mintPool] = IDepositHelper(_helper);
        if (_isRebase) setRebase(_mintPool, _isRebase);
        emit MintPoolAdded(_mintPool);
        emit DepositHelperChanged(_mintPool, _helper);
    }

    function changeHelper(address _mintPool, address _helper) external onlyOwner {
        depositHelpers[_mintPool] = IDepositHelper(_helper);
        emit DepositHelperChanged(_mintPool, _helper);
    }

    function setRebase(address _mintPool, bool _isRebase) public onlyOwner {
        if (_isRebase) {
            isRebase[_mintPool] = _isRebase;
            emit PoolTypeChanged(_mintPool, _isRebase);
        }
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Main Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    // Only deposit ETH
    // Transform to ETH/LBR LP token
    function zap(uint256 _swapMinOut, uint256 _lpMinETH, uint256 _lpMinLBR) external payable {
        if (stakePaused) revert StakePaused();

        uint256 ethToSwap = msg.value / 2;
        address[] memory swapPath = new address[](2);
        swapPath[0] = WETH;
        swapPath[1] = LBR;
        // Swap half of the ETH to LBR
        uint256[] memory amounts = ROUTER.swapExactETHForTokens{ value: ethToSwap }(
            _swapMinOut,
            swapPath,
            address(this),
            block.timestamp + 1
        );
        uint256 lbrAmount = amounts[1];

        // Add liquidity to get LP token
        uint256 ethToAdd = msg.value - ethToSwap;
        (uint256 lbrAdded, uint256 ethAdded, uint256 lpAmount) = ROUTER.addLiquidityETH{
            value: ethToAdd
        }(LBR, lbrAmount, _lpMinLBR, _lpMinETH, address(this), block.timestamp + 1);

        // Refund excess amounts if values of ETH and LBR swapped from ETH are not the same
        if (ethToAdd > ethAdded) {
            (bool sent, ) = (msg.sender).call{ value: ethToAdd - ethAdded }("");
            require(sent, "ETH refund failed");
        }

        if (lbrAmount > lbrAdded)
            IERC20(LBR).safeTransfer(msg.sender, lbrAmount - lbrAdded);

        if (getLpValue(totalStaked + lpAmount) > stakeLimit && stakeLimit != 0)
            revert ExceedLimit();

        rewardManager.dlpUpdateReward(msg.sender);

        // Stake LP
        uint256 allowance = ethlbrLpToken.allowance(
            address(this),
            address(ethlbrStakePool)
        );
        if (allowance < lpAmount)
            ethlbrLpToken.approve(address(ethlbrStakePool), type(uint256).max);

        ethlbrStakePool.stake(lpAmount);
        totalStaked += lpAmount;
        staked[msg.sender] += lpAmount;

        emit LpStaked(msg.sender, lpAmount);
    }

    // Stake LBR-ETH LP token
    function stakeLP(uint256 _amount) external {
        if (stakePaused) revert StakePaused();
        if (getLpValue(totalStaked + _amount) > stakeLimit && stakeLimit != 0)
            revert ExceedLimit();

        rewardManager.dlpUpdateReward(msg.sender);

        ethlbrLpToken.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 allowance = ethlbrLpToken.allowance(
            address(this),
            address(ethlbrStakePool)
        );
        if (allowance < _amount)
            ethlbrLpToken.approve(address(ethlbrStakePool), type(uint256).max);

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

    function supplyETH(uint256 _poolIndex) external payable {
        IMintPool mintPool = mintPools[_poolIndex];
        address mintPoolAddress = address(mintPool);

        rewardManager.lsdUpdateReward(msg.sender, isRebase[mintPoolAddress]);

        uint256 amount = depositHelpers[mintPoolAddress].toLSD{ value: msg.value }();
        if (
            ((totalSupplied[mintPoolAddress] + amount) * mintPool.getAssetPrice()) /
                1e18 > supplyLimit && supplyLimit != 0
        ) revert ExceedLimit();
        supplied[mintPoolAddress][msg.sender] += amount;
        totalSupplied[mintPoolAddress] += amount;

        if (_poolIndex > 0) {
            // Store supply amount in terms of stETH
            uint256 newSuppliedReward = supplied[mintPoolAddress][msg.sender] * 
                mintPool.getAsset2EtherExchangeRate() / 1e18;
            totalSuppliedReward[mintPoolAddress] += (
                newSuppliedReward - suppliedReward[mintPoolAddress][msg.sender]
            );
            suppliedReward[mintPoolAddress][msg.sender] = newSuppliedReward;
        }

        emit ETHSupplied(mintPoolAddress, msg.sender, msg.value);

        mintUSD(mintPoolAddress);
    }

    function supplyLSD(uint256 _poolIndex, uint256 _amount) external {
        IMintPool mintPool = mintPools[_poolIndex];
        address mintPoolAddress = address(mintPool);

        if (
            ((totalSupplied[mintPoolAddress] + _amount) * mintPool.getAssetPrice()) /
                1e18 > supplyLimit && supplyLimit != 0
        ) revert ExceedLimit();

        rewardManager.lsdUpdateReward(msg.sender, isRebase[mintPoolAddress]);

        IERC20(mintPool.getAsset()).safeTransferFrom(msg.sender, address(this), _amount);
        supplied[mintPoolAddress][msg.sender] += _amount;
        totalSupplied[mintPoolAddress] += _amount;

        // Store supply amount in terms of stETH
        if (_poolIndex > 0) {
            uint256 newSuppliedReward = supplied[mintPoolAddress][msg.sender] * 
                mintPool.getAsset2EtherExchangeRate() / 1e18;
            totalSuppliedReward[mintPoolAddress] += (
                newSuppliedReward - suppliedReward[mintPoolAddress][msg.sender]
            );
            suppliedReward[mintPoolAddress][msg.sender] = newSuppliedReward;
        }

        emit LSDSupplied(mintPoolAddress, msg.sender, _amount);

        mintUSD(mintPoolAddress);
    }

    function withdrawLSD(uint256 _poolIndex, uint256 _amount) external {
        PoolInfo memory poolInfo;
        poolInfo.mintPool = mintPools[_poolIndex];
        poolInfo.mintPoolAddress = address(poolInfo.mintPool);
        poolInfo.isRebasePool = isRebase[poolInfo.mintPoolAddress];
        poolInfo.tokenPrice = poolInfo.mintPool.getAssetPrice();

        uint256 borrowedWithInterest = getBorrowWithInterest(poolInfo.mintPoolAddress, msg.sender);
        uint256 withdrawable;
        if (borrowedWithInterest > 0) {
            // Amount of LSD required to back borrow
            uint256 requiredLSD = (borrowedWithInterest * collateralRatioIdeal / maxBorrowRatio) 
                * 1e18 / poolInfo.tokenPrice;
            withdrawable = requiredLSD > supplied[poolInfo.mintPoolAddress][msg.sender]
                ? 0 
                : supplied[poolInfo.mintPoolAddress][msg.sender] - requiredLSD;
        } 
        else withdrawable = supplied[poolInfo.mintPoolAddress][msg.sender];

        if (_amount > withdrawable) revert ExceedAmountAllowed(_amount, withdrawable);
        uint256 _totalDeposited = totalDeposited[poolInfo.mintPoolAddress];
        uint256 _totalMinted = totalMinted[poolInfo.mintPoolAddress];

        rewardManager.lsdUpdateReward(msg.sender, poolInfo.isRebasePool);

        uint256 idleAmount = totalSupplied[poolInfo.mintPoolAddress] - _totalDeposited;
        if (poolInfo.isRebasePool) {
            if (idleAmount > 0.01 ether) idleAmount -= 0.01 ether;
            else idleAmount = 0;
        }

        supplied[poolInfo.mintPoolAddress][msg.sender] -= _amount;
        totalSupplied[poolInfo.mintPoolAddress] -= _amount;

        // Store supply amount in terms of stETH
        if (_poolIndex > 0) {
            uint256 newSuppliedReward = supplied[poolInfo.mintPoolAddress][msg.sender] * 
                poolInfo.mintPool.getAsset2EtherExchangeRate() / 1e18;
            totalSuppliedReward[poolInfo.mintPoolAddress] -= (
                suppliedReward[poolInfo.mintPoolAddress][msg.sender] - newSuppliedReward
            );
            suppliedReward[poolInfo.mintPoolAddress][msg.sender] = newSuppliedReward;
        }

        // Withdraw additional LSD from Lybra vault if contract does not have enough idle LSD
        if (idleAmount < _amount) {
            uint256 withdrawFromLybra = _amount - idleAmount;
            // Amount of LSD that can be withdrawn without burning eUSD
            uint256 withdrawableFromLybra = _getDepositAmountDelta(
                _totalDeposited,
                _totalMinted,
                poolInfo.tokenPrice
            );

            // Burn eUSD to withdraw LSD required
            if (withdrawFromLybra > withdrawableFromLybra) {
                uint256 amountToBurn = _getBurnAmountDelta(
                    _totalDeposited - withdrawFromLybra,
                    _totalMinted,
                    poolInfo.tokenPrice
                );
                _burnUSD(poolInfo.mintPoolAddress, amountToBurn);
            }

            // Get withdrawal amount after punishment (if any) from Lybra, accepted by user, only for stETH
            uint256 actualAmount = poolInfo.isRebasePool
                ? poolInfo.mintPool.checkWithdrawal(address(this), withdrawFromLybra)
                : withdrawFromLybra;
            _withdrawFromLybra(poolInfo.mintPoolAddress, withdrawFromLybra);

            IERC20(poolInfo.mintPool.getAsset()).safeTransfer(
                msg.sender,
                idleAmount + actualAmount
            );

            emit LSDWithdrew(
                poolInfo.mintPoolAddress,
                msg.sender,
                _amount,
                withdrawFromLybra - actualAmount
            );
        } else {
            // If contract has enough idle LSD, just transfer out
            IERC20(poolInfo.mintPool.getAsset()).safeTransfer(msg.sender, _amount);

            emit LSDWithdrew(poolInfo.mintPoolAddress, msg.sender, _amount, 0);
        }

        mintUSD(poolInfo.mintPoolAddress);
    }

    // Take out/borrow eUSD/peUSD from Match Pool
    function borrowUSD(uint256 _poolIndex, uint256 _amount) external {
        if (borrowPaused) revert BorrowPaused();

        PoolInfo memory poolInfo;
        poolInfo.mintPool = mintPools[_poolIndex];
        poolInfo.mintPoolAddress = address(poolInfo.mintPool);
        poolInfo.isRebasePool = isRebase[poolInfo.mintPoolAddress];
        poolInfo.tokenPrice = poolInfo.mintPool.getAssetPrice();
        BorrowInfo storage borrowInfo = borrowed[poolInfo.mintPoolAddress][msg.sender];

        uint256 maxBorrow = _getMaxBorrow(
            supplied[poolInfo.mintPoolAddress][msg.sender],
            poolInfo.tokenPrice
        );
        uint256 available = totalMinted[poolInfo.mintPoolAddress] - totalBorrowed[poolInfo.mintPoolAddress];
        uint256 newBorrowAmount = borrowInfo.principal + _amount;
        accrueInterest(poolInfo.mintPoolAddress, msg.sender);
        uint256 borrowPlusInterest = newBorrowAmount + borrowInfo.accInterest;
        if (borrowPlusInterest > maxBorrow)
            revert ExceedAmountAllowed(borrowPlusInterest, maxBorrow);
        if (_amount > available) revert ExceedAmountAllowed(_amount, available);

        // No need to update user reward info as there are no changes in supply amount
        rewardManager.lsdUpdateReward(address(0), poolInfo.isRebasePool);

        borrowInfo.principal = newBorrowAmount;
        totalBorrowed[poolInfo.mintPoolAddress] += _amount;

        address asset = poolInfo.isRebasePool
            ? lybraConfigurator.getEUSDAddress() : lybraConfigurator.peUSD();
        IERC20(asset).safeTransfer(msg.sender, _amount);

        emit USDBorrowed(asset, msg.sender, _amount);

        mintUSD(poolInfo.mintPoolAddress);
    }

    function repayUSD(uint256 _poolIndex, address _account, uint256 _amount) public {
        IMintPool mintPool = mintPools[_poolIndex];
        address mintPoolAddress = address(mintPool);
        bool isRebasePool = isRebase[mintPoolAddress];

        uint256 oldBorrowAmount = borrowed[mintPoolAddress][_account].principal;
        accrueInterest(mintPoolAddress, _account);
        uint256 newAccInterest = borrowed[mintPoolAddress][_account].accInterest;
        IERC20 asset = isRebasePool
            ? IERC20(lybraConfigurator.getEUSDAddress())
            : IERC20(lybraConfigurator.peUSD());

        // Just repaying interest
        if (oldBorrowAmount == 0) {
            asset.safeTransferFrom(msg.sender, rewardManager.treasury(), _amount);

            if (_amount < newAccInterest) {
                // Not yet repaid all
                borrowed[mintPoolAddress][_account].accInterest -= _amount;
            } else {
                // Delete info if repaid all
                delete borrowed[mintPoolAddress][_account];
            }

            emit USDRepaid(address(asset), _account, _amount);

            return;
        }

        // No need to update user reward info as there are no changes in supply amount
        rewardManager.lsdUpdateReward(address(0), isRebasePool);

        uint256 newBorrowAmount;
        // Amount for repaying interest after repaying all borrowed eUSD/peUSD
        uint256 spareAmount;
        if (_amount > oldBorrowAmount) spareAmount = _amount - oldBorrowAmount;
        else newBorrowAmount = oldBorrowAmount - _amount;

        asset.safeTransferFrom(msg.sender, address(this), _amount);
        // accrueInterest() already called at line 678
        borrowed[mintPoolAddress][_account].principal = newBorrowAmount;
        totalBorrowed[mintPoolAddress] -= (oldBorrowAmount - newBorrowAmount);

        if (spareAmount > 0) {
            asset.safeTransfer(rewardManager.treasury(), spareAmount);

            if (spareAmount >= newAccInterest) {
                delete borrowed[mintPoolAddress][_account];
            } else {
                borrowed[mintPoolAddress][_account].accInterest -= spareAmount;
            }
        }

        emit USDRepaid(address(asset), _account, _amount);

        mintUSD(mintPoolAddress);
    }

    // function liquidate(
    //     uint256 _poolIndex,
    //     address _account,
    //     uint256 _repayAmount
    // ) external {
    //     IMintPool mintPool = mintPools[_poolIndex];
    //     address mintPoolAddress = address(mintPool);
    //     bool isRebasePool = isRebase[mintPoolAddress];
    //     uint256 tokenPrice = mintPool.getAssetPrice();

    //     // Amount user has to borrow more than in order to be liquidated
    //     uint256 liquidationThreshold = (supplied[mintPoolAddress][_account] *
    //         tokenPrice * 100) / collateralRatioIdeal;
    //     uint256 userBorrowed = borrowed[mintPoolAddress][msg.sender].principal;
    //     if (userBorrowed <= liquidationThreshold) revert HealthyAccount();

    //     uint256 globalBorrowRatio = (totalBorrowed[mintPoolAddress] * 1e20) /
    //         _getMaxBorrow(totalSupplied[mintPoolAddress], tokenPrice);
    //     uint256 _closeFactor = globalBorrowRatio < globalBorrowRatioLiquidation
    //         ? closeFactor : closeFactorNormal;
    //     uint256 _liquidationDiscount = globalBorrowRatio < globalBorrowRatioLiquidation
    //         ? liquidationDiscount : liquidationDiscountNormal;

    //     uint256 maxRepay = (userBorrowed * _closeFactor) / 1e20;
    //     if (_repayAmount > maxRepay) revert ExceedAmountAllowed(_repayAmount, maxRepay);

    //     // Both liquidator's & liquidatee's supplied amount will be changed
    //     rewardManager.lsdUpdateReward(_account, isRebasePool);
    //     rewardManager.lsdUpdateReward(msg.sender, isRebasePool);

    //     repayUSD(_poolIndex, _account, _repayAmount);
    //     uint256 seizeAmount = (_repayAmount * _liquidationDiscount * 1e18) / 1e20 / tokenPrice;
    //     supplied[mintPoolAddress][_account] -= seizeAmount;
    //     supplied[mintPoolAddress][msg.sender] += seizeAmount;

    //     emit Liquidated(mintPoolAddress, _account, msg.sender, seizeAmount);

    //     mintUSD(mintPoolAddress);
    // }

    /**
     * @notice Update interest index based on borrow ratio before new changes
     * @dev Update timestamp only if no interest charged. 
     *   Must be called before updating totalMinted/totalBorrowed, whichever comes first.
     */
    function accrueInterest(address _mintPoolAddress, address _account) public {
        InterestTracker storage interestInfo = interestTracker[_mintPoolAddress];
        (uint128 currentInterestIndex, uint128 timeDelta) = _getInterestIndexCur(_mintPoolAddress);

        if (timeDelta == 0) return;

        if (currentInterestIndex > interestInfo.interestIndexGlobal)
            interestInfo.interestIndexGlobal = currentInterestIndex;

        interestInfo.lastAccrualtime = uint128(block.timestamp);

        if (_account != address(0)) {
            BorrowInfo storage borrowInfo = borrowed[_mintPoolAddress][_account];

            borrowInfo.accInterest += borrowInfo.principal * currentInterestIndex / 
                borrowInfo.interestIndex - borrowInfo.principal;
            borrowInfo.interestIndex = currentInterestIndex;
        }
    }

    /**
     * @dev Assumes that dlp ratio is always > 3%
     */
    function mintUSD(address _mintPoolAddress) public {
        uint256 tokenPrice = IMintPool(_mintPoolAddress).getAssetPrice();
        uint256 _totalDeposited = totalDeposited[_mintPoolAddress];
        uint256 _totalMinted = totalMinted[_mintPoolAddress];
        uint256 _collateralRatioIdeal = collateralRatioIdeal;
        uint256 totalIdle = totalSupplied[_mintPoolAddress] - _totalDeposited;
        if (isRebase[_mintPoolAddress]) {
            // Minus 0.01 ether to compensate for ETH to stETH inconsistent conversion from Lido
            if (totalIdle > 0.01 ether) totalIdle -= 0.01 ether;
            else totalIdle = 0;
        }

        if (
            _getCollateralRatio(_totalDeposited, _totalMinted, tokenPrice) >
            _collateralRatioIdeal
        ) {
            if (totalIdle < 1 ether)
                _mintUSD(
                    _mintPoolAddress,
                    _getMintAmountDelta(_totalDeposited, _totalMinted, tokenPrice)
                );
            else
                _depositToLybra(
                    _mintPoolAddress,
                    totalIdle,
                    _getMintAmountDelta(
                        _totalDeposited + totalIdle,
                        _totalMinted,
                        tokenPrice
                    )
                );
            return;
        }

        if (totalIdle < 1 ether) return;
        // Can mint more after depositing more, even if current c.r. <= { collateralRatioIdeal }
        if (
            _getCollateralRatio(_totalDeposited + totalIdle, _totalMinted, tokenPrice) >=
            _collateralRatioIdeal
        ) {
            _depositToLybra(
                _mintPoolAddress,
                totalIdle,
                _getMintAmountDelta(
                    _totalDeposited + totalIdle,
                    _totalMinted,
                    tokenPrice
                )
            );
        }
    }

    /**
     * @notice Send eUSD rebase reward to Reward Manager
     */
    function claimRebase() external returns (uint256) {
        if (msg.sender != address(rewardManager)) revert Unauthorized();

        IERC20 eUSD = IERC20(lybraConfigurator.getEUSDAddress());
        uint256 amountActual = eUSD.balanceOf(address(this));
        uint256 amountRecord;
        for (uint256 i; i < mintPools.length; ) {
            address mintPoolAddress = address(mintPools[i]);
            if (isRebase[mintPoolAddress])
                amountRecord += (totalMinted[mintPoolAddress] - totalBorrowed[mintPoolAddress]);

            unchecked {
                ++i;
            }
        }

        uint256 amount;
        if (amountActual > amountRecord) {
            amount = amountActual - amountRecord;
            // Transfer only when there is at least 10 eUSD of reebase reward to save gas
            if (amount > 10e18) eUSD.safeTransfer(msg.sender, amount);
        }

        return amount;
    }

    function claimRewards(uint256 _rewardPoolId) external {
        if (_rewardPoolId == 1) ethlbrStakePool.getReward();
        else if (_rewardPoolId == 2) 
            IMining(lybraConfigurator.eUSDMiningIncentives()).getReward();
        else {
            ethlbrStakePool.getReward();
            IMining(lybraConfigurator.eUSDMiningIncentives()).getReward();
        }
    }

    // !! @modify Code added by Eric 20231030
    function claimProtocolRevenue() external {
        require(msg.sender == address(rewardManager));

        IRewardPool(lybraProtocolRevenue).getReward();

        // TODO: use balanceOf.address(this) or lybraProtocolRevenue.earned() ???
        // Still not decided
        // if use "earned()" to get precise amount, need to calcualte how many peUSD received
        // and then get if & how any USDC received
        // and then send them all to distributor
        IERC20 peUSD = IERC20(lybraConfigurator.peUSD());
        peUSD.transfer(msg.sender, peUSD.balanceOf(address(this)));

        IERC20 stableToken = IERC20(lybraConfigurator.stableToken());
        stableToken.transfer(msg.sender, stableToken.balanceOf(address(this)));
    }

    function boostReward(uint256 _settingId, uint256 _amount) external onlyOwner {
        esLBRBoost.setLockStatus(_settingId, _amount, false);
    }

    // ---------------------------------------------------------------------------------------- //
    // *********************************** Internal Functions ********************************* //
    // ---------------------------------------------------------------------------------------- //

    function _getInterestIndexCur(address _mintPoolAddress) private view returns (uint128, uint128) {
        InterestTracker memory info = interestTracker[_mintPoolAddress];

        uint128 timeDelta = uint128(block.timestamp) - info.lastAccrualtime;
        if (timeDelta == 0) return (info.interestIndexGlobal, 0);

        if (_getBorrowRatio(_mintPoolAddress) >= globalBorrowRatioThreshold) {
            return (uint128(info.interestIndexGlobal + 
                info.interestIndexGlobal * timeDelta * borrowRatePerSec / 1e18), timeDelta);
        }

        return (info.interestIndexGlobal, timeDelta);
    }

    /**
     * @notice Get max. amount of eUSD/peUSD that can be borrowed given amount of LSD supplied
     */
    function _getMaxBorrow(
        uint256 _suppliedAmount,
        uint256 _price
    ) private view returns (uint256) {
        return (_suppliedAmount * _price * maxBorrowRatio) / collateralRatioIdeal / 1e18;
    }

    /**
     * @notice Get current global borrow ratio
     */
    function _getBorrowRatio(address _mintPoolAddress) private view returns (uint256) {
        uint256 _totalMinted = totalMinted[_mintPoolAddress];
        return _totalMinted == 0 ?
            0 :
            totalBorrowed[_mintPoolAddress] * 1e20 / _totalMinted;
    }

    /**
     * @notice Get collateral ratio accordin to given amount
     * @param _depositedAmount Amount of LSD deposited to Lybra vault
     * @param _mintedAmount Amount of eUSD/peUSD minted
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
        uint256 newDepositedAmount = (collateralRatioLower * _mintedAmount) / _price / 100;
        return newDepositedAmount > _depositedAmount 
            ? 0 
            : _depositedAmount - newDepositedAmount;
    }

    /**
     * @param _depositedAmount Amount of LSD deposited to Lybra vault
     * @param _mintedAmount Amount of eUSD/peUSD minted
     * @return Amount of eUSD/peUSD to mint from Lybra vault in order to achieve { collateralRatioIdeal }
     */
    function _getMintAmountDelta(
        uint256 _depositedAmount,
        uint256 _mintedAmount,
        uint256 _price
    ) private view returns (uint256) {
        uint256 newMintedAmount = (_depositedAmount * _price * 100) / collateralRatioIdeal;
        return
            newMintedAmount > _mintedAmount
                ? newMintedAmount - _mintedAmount
                : 0;
    }

    /**
     * @param _depositedAmount Amount of LSD deposited to Lybra vault
     * @param _mintedAmount Amount of eUSD/peUSD minted
     * @return Amount of eUSD/peUSD to repay to Lybra vault in order to achieve { collateralRatioIdeal }
     */
    function _getBurnAmountDelta(
        uint256 _depositedAmount,
        uint256 _mintedAmount,
        uint256 _price
    ) private view returns (uint256) {
        uint256 newMintedAmount = (_depositedAmount * _price * 100) / collateralRatioIdeal;
        return
            newMintedAmount > _mintedAmount
                ? 0
                : _mintedAmount - newMintedAmount;
    }

    function _depositNoCheck(
        address _mintPoolAddress,
        uint256 _amount,
        uint256 _usdMintAmount
    ) private {
        IMintPool mintPool = IMintPool(_mintPoolAddress);

        IERC20 asset = IERC20(mintPool.getAsset());
        uint256 allowance = asset.allowance(address(this), _mintPoolAddress);
        if (allowance < _amount) asset.approve(_mintPoolAddress, type(uint256).max);

        mintPool.depositAssetToMint(_amount, _usdMintAmount);
        totalDeposited[_mintPoolAddress] += _amount;
        if (_usdMintAmount > 0) {
            accrueInterest(_mintPoolAddress, address(0));
            totalMinted[_mintPoolAddress] += _usdMintAmount;
        }
    }

    /**
     * @notice Lybra restricts deposits with a min. amount of 1 LSD
     */
    function _depositToLybra(
        address _mintPoolAddress,
        uint256 _amount,
        uint256 _usdMintAmount
    ) private {
        if (_amount < 1 ether) revert MinLybraDeposit();

        _depositNoCheck(_mintPoolAddress, _amount, _usdMintAmount);
    }

    /**
     * @notice Match Finance will only withdraw spare LSD from Lybra when there is no punishment.
     *  Punished withdrawals will only be initiated by users whole are willing to take the loss,
     *  as totalSupplied and totalDeposited are updated in the same tx for such situation,
     *  the problem of value mismatch (insufiicient balance for withdrawal) is avoided
     */
    function _withdrawFromLybra(address _mintPoolAddress, uint256 _amount) private {
        IMintPool mintPool = IMintPool(_mintPoolAddress);

        uint256 collateralRatioAfter = _getCollateralRatio(
            totalDeposited[_mintPoolAddress] - _amount,
            totalMinted[_mintPoolAddress],
            mintPool.getAssetPrice()
        );
        // Withdraw only until collateral ratio reaches { collateralRatioLower }
        if (collateralRatioAfter < collateralRatioLower) revert InsufficientCollateral();

        mintPool.withdraw(address(this), _amount);
        totalDeposited[_mintPoolAddress] -= _amount;
    }

    function _mintUSD(address _mintPoolAddress, uint256 _amount) private {
        if (_amount == 0) return;

        IMintPool mintPool = IMintPool(_mintPoolAddress);

        mintPool.mint(address(this), _amount);
        accrueInterest(_mintPoolAddress, address(0));
        totalMinted[_mintPoolAddress] += _amount;
    }

    function _burnUSD(address _mintPoolAddress, uint256 _amount) private {
        IMintPool mintPool = IMintPool(_mintPoolAddress);

        mintPool.burn(address(this), _amount);
        accrueInterest(_mintPoolAddress, address(0));
        totalMinted[_mintPoolAddress] -= _amount;
    }

    function _max(uint256 x, uint256 y) private pure returns (uint256) {
        return x > y ? x : y;
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x < y ? x : y;
    }

    // ---------------------------------------------------------------------------------------- //
    // *********************************** Monitor Functions ********************************** //
    // ---------------------------------------------------------------------------------------- //

    // @notice Monitor functions are only called by Match Finance's auto adjustment system

    function monitorDeposit(
        address _mintPoolAddress,
        uint256 _amount,
        uint256 _usdMintAmount
    ) external onlyMonitor {
        _depositNoCheck(_mintPoolAddress, _amount, _usdMintAmount);
    }

    function monitorWithdraw(
        address _mintPoolAddress,
        uint256 _amount
    ) external onlyMonitor {
        IMintPool mintPool = IMintPool(_mintPoolAddress);

        mintPool.withdraw(address(this), _amount);
        totalDeposited[_mintPoolAddress] -= _amount;
    }

    function monitorMint(address _mintPoolAddress, uint256 _amount) external onlyMonitor {
        _mintUSD(_mintPoolAddress, _amount);
    }

    function monitorBurn(address _mintPoolAddress, uint256 _amount) external onlyMonitor {
        _burnUSD(_mintPoolAddress, _amount);
    }

    function softLiquidation(
        uint256 _poolIndex, 
        address _account, 
        uint256 _repayAmount
    ) external onlyMonitor {
        IMintPool mintPool = mintPools[_poolIndex];
        address mintPoolAddress = address(mintPool);
        bool isRebasePool = isRebase[mintPoolAddress];
        uint256 tokenPrice = mintPool.getAssetPrice();

        // Amount user has to borrow more than in order to be liquidated
        uint256 liquidationThreshold = (supplied[mintPoolAddress][_account] *
            tokenPrice * 100) / collateralRatioLiquidate;
        uint256 borrowedWithInterest = getBorrowWithInterest(mintPoolAddress, _account);
        if (borrowedWithInterest <= liquidationThreshold) revert HealthyAccount();

        // Both liquidator's & liquidatee's supplied amount will be changed
        rewardManager.lsdUpdateReward(_account, isRebasePool);
        rewardManager.lsdUpdateReward(msg.sender, isRebasePool);

        uint256 maxRepay = (borrowedWithInterest * closeFactorNormal) / 1e20;
        if (_repayAmount > maxRepay) revert ExceedAmountAllowed(_repayAmount, maxRepay);
        repayUSD(_poolIndex, _account, _repayAmount);
        uint256 seizeAmount = (_repayAmount * liquidationDiscountNormal * 1e18) / 1e20 / tokenPrice;
        supplied[mintPoolAddress][_account] -= seizeAmount;
        supplied[mintPoolAddress][msg.sender] += seizeAmount;

        emit Liquidated(mintPoolAddress, _account, msg.sender, seizeAmount);

        mintUSD(mintPoolAddress);
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
