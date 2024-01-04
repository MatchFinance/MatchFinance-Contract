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
error InvalidRange(uint256 paramPos);
error ReentrancyGuardReentrantCall();

contract MatchPool is Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant LBR = 0xed1167b6Dc64E8a366DB86F2E952A482D0981ebd;
    IUniswapV2Router constant ROUTER = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    uint256 constant MIN_LIQUIDATION_DISCOUNT = 100e18;
    uint256 constant MAX_LIQUIDATION_DISCOUNT = 120e18;
    uint256 constant MAX_CLOSE_FACTOR = 50e18;
    uint256 constant ENTERED = 1;
    uint256 constant NOT_ENTERED = 2;

    struct Calc {
        uint256 withdrawable;
        uint256 requiredLSD;
        uint256 interestLSD;
        uint256 amountWithInterest;
        uint256 totalDeposited;
        uint256 totalMinted;
        uint256 idleAmount;
    }

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
        uint256 userFeePerTokenPaid; // peUSD mint fee
        uint256 accInterest; // Accumulated interest
        uint256 interestIndex; // Last updated { borrowIndex }
    }
    // Mint vault => user address => eUSD/peUSD 'taken out/borrowed' by user
    mapping(address => mapping(address => BorrowInfo)) public borrowed;
    uint256 public borrowRatePerSec; // 10% / 365 days, scaled by 1e18

    uint256 public maxBorrowRatio; // 80e18, scaled by 1e20
    uint256 public globalBorrowRatioThreshold; // 75e18, scaled by 1e20
    uint256 globalBorrowRatioLiquidation; // 50e18, scaled by 1e20

    // When global borrow ratio < 50%
    uint128 liquidationDiscount; // 105e18, scaled by 1e20
    uint128 closeFactor; // 20e18, scaled by 1e20
    // When global borrow ratio >= 50%
    uint128 public liquidationDiscountNormal; // 110e18, scaled by 1e20
    uint128 public closeFactorNormal; // 50e18, scaled by 1e20

    uint256 dlpRatioUpper; // 325
    uint256 dlpRatioLower; // 275
    uint256 dlpRatioIdeal; // 300
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

    /******************************************************************/

    uint256 reentracncy;

    // Mint pool => deposit helper
    mapping(address => IDepositHelper) depositHelpers;
    mapping(address => bool) isRebase;

    IesLBRBoost public esLBRBoost;

    // Record supply amounts in terms of stETH for reward calculation
    mapping(address => uint256) totalSuppliedReward;
    mapping(address => mapping(address => uint256)) suppliedReward;

    // Global borrow ratio interest tracker
    struct InterestTracker {
        uint128 interestIndexGlobal;
        uint128 lastAccrualtime;
    }
    mapping(address => InterestTracker) public interestTracker;

    // peUSD mint fee tracker
    mapping(address => uint256) public feePerTokenStored;

    // ---------------------------------------------------------------------------------------- //
    // *************************************** Events ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    event LybraLPChanged(address _newToken, address _newOracle, address _newPool);
    event LybraBoostChanged(address _newBoost);
    event LybraConfiguratorChanged(address _newConfig);
    event RewardManagerChanged(address newManager);
    event CollateralRatioChanged(uint256 newLiquidate, uint256 newLower, uint256 newIdeal);
    event BorrowRateChanged(uint256 newRate);
    event BorrowRatioChanged(uint256 newMax, uint256 newGlobalThreshold);
    event LiquidationParamsNormalChanged(uint128 newDiscount, uint128 newCloseFactor);
    event LPStakePaused(bool newState);
    event LPWithdrawPaused(bool newState);
    event eUSDBorrowPaused(bool newState);
    event StakeLimitChanged(uint256 newLimit);
    event SupplyLimitChanged(uint256 newLimit);
    event MonitorChanged(address newMonitor);
    event MintPoolAdded(address newMintPool);

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
        _checkMonitor();
        _;
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    // function initialize() public initializer {
    //     __Ownable_init();

    //     setCollateralRatioRange(190e18, 210e18, 200e18);
    //     setBorrowRate(1e17);
    //     setBorrowRatio(80e18, 75e18, 50e18);
    //     setLiquidationParamsNormal(110e18, 50e18);
    //     setStakeLimit(60000e18);
    //     setSupplyLimit(4000000e18);
    // }

    function initializeV2() public reinitializer(2) {
        reentracncy = NOT_ENTERED;
        // Initialize stETH pool global interest index
        isRebase[address(mintPools[0])] = true;
        interestTracker[address(mintPools[0])].interestIndexGlobal = 1e18;
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
    function getBorrowAndInterest(
        address _mintPoolAddress,
        address _account
    ) public view returns (uint256 borrow, uint256 interest) {
        BorrowInfo memory borrowInfo = borrowed[_mintPoolAddress][_account];

        borrow = borrowInfo.principal;
        interest = borrowInfo.accInterest;

        // Global borrow ratio interest
        if (borrow > 0) {
            uint128 interestIndexCur = _getInterestIndex(
                _mintPoolAddress,
                _timePassed(_mintPoolAddress)
            );
            interest += borrow * interestIndexCur / borrowInfo.interestIndex - borrow;
        }

        // peUSD mint fee
        if (isRebase[_mintPoolAddress]) {
            uint256 fpt = _feePerToken(_mintPoolAddress, _timePassed(_mintPoolAddress));
            interest += supplied[_mintPoolAddress][_account] * 
                (fpt - borrowInfo.userFeePerTokenPaid) / 1e18;
        }
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Set Functions ************************************* //
    // ---------------------------------------------------------------------------------------- //

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

    // function setDlpRatioRange(
    //     uint256 _lower,
    //     uint256 _upper,
    //     uint256 _ideal
    // ) public onlyOwner {
    //     dlpRatioLower = _lower;
    //     dlpRatioUpper = _upper;
    //     dlpRatioIdeal = _ideal;
    //     emit DlpRatioChanged(_lower, _upper, _ideal);
    // }

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
        uint256 _global
    ) public onlyOwner {
        maxBorrowRatio = _individual;
        globalBorrowRatioThreshold = _global;
        emit BorrowRatioChanged(_individual, _global);
    }

    // function setLiquidationParams(
    //     uint128 _discount,
    //     uint128 _closeFactor
    // ) public onlyOwner {
    //     liquidationDiscount = _discount;
    //     closeFactor = _closeFactor;
    //     emit LiquidationParamsChanged(_discount, _closeFactor);
    // }

    function setLiquidationParamsNormal(
        uint128 _discount,
        uint128 _closeFactor
    ) public onlyOwner {
        if (_discount < MIN_LIQUIDATION_DISCOUNT && _discount > MAX_LIQUIDATION_DISCOUNT)
            revert InvalidRange(1);
        if (_closeFactor > MAX_CLOSE_FACTOR) revert InvalidRange(2);
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
        if (_isRebase) isRebase[_mintPool] = _isRebase;
        interestTracker[_mintPool].interestIndexGlobal = 1e18;
        emit MintPoolAdded(_mintPool);
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Main Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    // Only deposit ETH
    // Transform to ETH/LBR LP token
    function zap(
        uint256 _swapMinOut,
        uint256 _lpMinETH,
        uint256 _lpMinLBR
    ) external payable nonReentrant {
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

        IERC20 _ethlbrLpToken = ethlbrLpToken;
        IStakePool _ethlbrStakePool = ethlbrStakePool;

        // Stake LP
        uint256 allowance = _ethlbrLpToken.allowance(
            address(this),
            address(_ethlbrStakePool)
        );
        if (allowance < lpAmount)
            _ethlbrLpToken.approve(address(_ethlbrStakePool), type(uint256).max);

        _ethlbrStakePool.stake(lpAmount);
        totalStaked += lpAmount;
        staked[msg.sender] += lpAmount;

        emit LpStaked(msg.sender, lpAmount);
    }

    // Stake LBR-ETH LP token
    function stakeLP(uint256 _amount) external {
        if (stakePaused) revert StakePaused();
        if (stakeLimit != 0 && getLpValue(totalStaked + _amount) > stakeLimit)
            revert ExceedLimit();

        rewardManager.dlpUpdateReward(msg.sender);

        IERC20 _ethlbrLpToken = ethlbrLpToken;
        IStakePool _ethlbrStakePool = ethlbrStakePool;

        _ethlbrLpToken.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 allowance = _ethlbrLpToken.allowance(
            address(this),
            address(_ethlbrStakePool)
        );
        if (allowance < _amount)
            _ethlbrLpToken.approve(address(_ethlbrStakePool), type(uint256).max);

        _ethlbrStakePool.stake(_amount);
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
        bool isRebasePool = isRebase[mintPoolAddress];

        uint256 amount = depositHelpers[mintPoolAddress].toLSD{ value: msg.value }();
        if (
            supplyLimit != 0 && ((totalSupplied[mintPoolAddress] + amount) * 
                mintPool.getAssetPrice()) / 1e18 > supplyLimit
        ) revert ExceedLimit();

        // Only non-rebase pools have to update interest before changing supply amounts
        if (isRebasePool) accrueInterest(mintPoolAddress, msg.sender);
        rewardManager.lsdUpdateReward(msg.sender, isRebasePool);

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
        bool isRebasePool = isRebase[mintPoolAddress];

        if (
            supplyLimit != 0 && ((totalSupplied[mintPoolAddress] + _amount) * 
                mintPool.getAssetPrice()) / 1e18 > supplyLimit
        ) revert ExceedLimit();

        // Only non-rebase pools have to update interest before changing supply amounts
        if (isRebasePool) accrueInterest(mintPoolAddress, msg.sender);
        rewardManager.lsdUpdateReward(msg.sender, isRebasePool);
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

    function withdrawLSD(uint256 _poolIndex, uint256 _amount) external nonReentrant {
        IMintPool mintPool = mintPools[_poolIndex];
        address mintPoolAddress = address(mintPool);
        bool isRebasePool = isRebase[mintPoolAddress];
        uint256 tokenPrice = mintPool.getAssetPrice();

        accrueInterest(mintPoolAddress, msg.sender);
        BorrowInfo storage borrowInfo = borrowed[mintPoolAddress][msg.sender];
        Calc memory calc;
        if (borrowInfo.principal > 0) {
            // Amount of LSD required to back borrow
            calc.requiredLSD = (borrowInfo.principal * collateralRatioIdeal / maxBorrowRatio) 
                * 1e18 / tokenPrice;
            if (calc.requiredLSD < supplied[mintPoolAddress][msg.sender])
                calc.withdrawable = supplied[mintPoolAddress][msg.sender] - calc.requiredLSD;
        } 
        else calc.withdrawable = supplied[mintPoolAddress][msg.sender];

        calc.interestLSD = borrowInfo.accInterest * 1e18 / tokenPrice;
        calc.amountWithInterest = _amount + calc.interestLSD;
        if (calc.amountWithInterest > calc.withdrawable) 
            revert ExceedAmountAllowed(_amount, calc.withdrawable);
        calc.totalDeposited = totalDeposited[mintPoolAddress];
        calc.totalMinted = totalMinted[mintPoolAddress];

        rewardManager.lsdUpdateReward(msg.sender, isRebasePool);

        calc.idleAmount = totalSupplied[mintPoolAddress] - calc.totalDeposited;
        if (isRebasePool) {
            if (calc.idleAmount > 0.01 ether) calc.idleAmount -= 0.01 ether;
            else calc.idleAmount = 0;
        }

        supplied[mintPoolAddress][msg.sender] -= calc.amountWithInterest;
        totalSupplied[mintPoolAddress] -= calc.amountWithInterest;

        // Store supply amount in terms of stETH
        if (_poolIndex > 0) {
            uint256 newSuppliedReward = supplied[mintPoolAddress][msg.sender] * 
                mintPool.getAsset2EtherExchangeRate() / 1e18;
            totalSuppliedReward[mintPoolAddress] -= (
                suppliedReward[mintPoolAddress][msg.sender] - newSuppliedReward
            );
            suppliedReward[mintPoolAddress][msg.sender] = newSuppliedReward;
        }

        IERC20 asset = IERC20(mintPool.getAsset());
        uint256 punishment;
        // Withdraw additional LSD from Lybra vault if contract does not have enough idle LSD
        if (calc.idleAmount < calc.amountWithInterest) {
            uint256 withdrawFromLybra = calc.amountWithInterest - calc.idleAmount;
            // Amount of LSD that can be withdrawn without burning eUSD
            uint256 withdrawableFromLybra = _getDepositAmountDelta(
                calc.totalDeposited,
                calc.totalMinted,
                tokenPrice
            );

            // Burn eUSD to withdraw LSD required
            if (withdrawFromLybra > withdrawableFromLybra) {
                uint256 amountToBurn = _getBurnAmountDelta(
                    calc.totalDeposited - withdrawFromLybra,
                    calc.totalMinted,
                    tokenPrice
                );
                _burnUSD(mintPoolAddress, amountToBurn);
            }

            // Get withdrawal amount after punishment (if any) from Lybra, 
            // accepted by user, only for stETH
            uint256 actualAmount = isRebasePool
                ? mintPool.checkWithdrawal(address(this), withdrawFromLybra)
                : withdrawFromLybra;
            punishment = withdrawFromLybra - actualAmount;
            _withdrawFromLybra(mintPoolAddress, withdrawFromLybra);
        }

        if (calc.interestLSD > 0) 
            asset.safeTransfer(rewardManager.treasury(), calc.interestLSD);
        asset.safeTransfer(msg.sender, _amount - punishment);
        borrowInfo.accInterest = 0;

        emit LSDWithdrew(
            mintPoolAddress,
            msg.sender,
            calc.amountWithInterest,
            punishment
        );

        mintUSD(mintPoolAddress);
    }

    // Take out/borrow eUSD/peUSD from Match Pool
    function borrowUSD(uint256 _poolIndex, uint256 _amount) external nonReentrant {
        if (borrowPaused) revert BorrowPaused();

        IMintPool mintPool = mintPools[_poolIndex];
        address mintPoolAddress = address(mintPool);
        bool isRebasePool = isRebase[mintPoolAddress];
        BorrowInfo storage borrowInfo = borrowed[mintPoolAddress][msg.sender];

        uint256 maxBorrow = _getMaxBorrow(
            supplied[mintPoolAddress][msg.sender],
            mintPool.getAssetPrice()
        );
        uint256 available = totalMinted[mintPoolAddress] - 
            totalBorrowed[mintPoolAddress];
        uint256 newBorrowAmount = borrowInfo.principal + _amount;
        accrueInterest(mintPoolAddress, msg.sender);
        uint256 borrowPlusInterest = newBorrowAmount + borrowInfo.accInterest;
        if (borrowPlusInterest > maxBorrow)
            revert ExceedAmountAllowed(borrowPlusInterest, maxBorrow);
        if (_amount > available) revert ExceedAmountAllowed(_amount, available);

        // No need to update user reward info as there are no changes in supply amount
        rewardManager.lsdUpdateReward(address(0), isRebasePool);

        borrowInfo.principal = newBorrowAmount;
        totalBorrowed[mintPoolAddress] += _amount;

        address asset = isRebasePool
            ? lybraConfigurator.getEUSDAddress() : lybraConfigurator.peUSD();
        IERC20(asset).safeTransfer(msg.sender, _amount);

        emit USDBorrowed(asset, msg.sender, _amount);

        mintUSD(mintPoolAddress);
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
     * @dev Must be called before updating totalMinted/totalBorrowed for rebase pools
     *   & totalMinted/totalSupplied for non-rebase pools
     */
    function accrueInterest(address _mintPoolAddress, address _account) public {
        uint256 timeDelta = _timePassed(_mintPoolAddress);
        // Avoid calling multiple times in same tx
        if (timeDelta == 0) return;

        InterestTracker storage interestInfo = interestTracker[_mintPoolAddress];
        uint128 currentInterestIndex = _getInterestIndex(_mintPoolAddress, timeDelta);
        uint256 fpt; // Fee per LSD supplied

        if (currentInterestIndex > interestInfo.interestIndexGlobal)
            interestInfo.interestIndexGlobal = currentInterestIndex;

        // Update peUSD mint fee
        if (isRebase[_mintPoolAddress]) {
            fpt = _feePerToken(_mintPoolAddress, timeDelta);
            feePerTokenStored[_mintPoolAddress] = fpt;
        }

        interestInfo.lastAccrualtime = uint128(block.timestamp);

        if (_account != address(0)) {
            BorrowInfo storage borrowInfo = borrowed[_mintPoolAddress][_account];

            uint256 newInterest = borrowInfo.principal * currentInterestIndex / 
                borrowInfo.interestIndex - borrowInfo.principal;
            if (fpt > 0) {
                newInterest += supplied[_mintPoolAddress][_account] * 
                    (fpt - borrowInfo.userFeePerTokenPaid) / 1e18;
                borrowInfo.userFeePerTokenPaid = fpt;
            }
            borrowInfo.accInterest += newInterest;
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
            _getCollateralRatio(
                _totalDeposited, 
                _totalMinted, 
                tokenPrice
            ) > _collateralRatioIdeal
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
            _getCollateralRatio(
                _totalDeposited + totalIdle, 
                _totalMinted, 
                tokenPrice
            ) >= _collateralRatioIdeal
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
            eUSD.safeTransfer(msg.sender, amount);
        }

        return amount;
    }

    function claimRewards() external {
        ethlbrStakePool.getReward();
        IMining(lybraConfigurator.eUSDMiningIncentives()).getReward();
    }

    // !! @modify Code added by Eric 20231228
    // !!         Remove access control
    function claimProtocolRevenue() external {
        IConfigurator config = lybraConfigurator;

        IRewardPool(config.getProtocolRewardsPool()).getReward();
        _sendRevenue(config.peUSD());
        _sendRevenue(config.stableToken());
    }

    function boostReward(uint256 _settingId, uint256 _amount) external onlyOwner {
        esLBRBoost.setLockStatus(_settingId, _amount, false);
    }

    // ---------------------------------------------------------------------------------------- //
    // *********************************** Internal Functions ********************************* //
    // ---------------------------------------------------------------------------------------- //

    function _timePassed(address _mintPoolAddress) private view returns (uint256) {
        return block.timestamp - interestTracker[_mintPoolAddress].lastAccrualtime;
    }

    function _getInterestIndex(
        address _mintPoolAddress,
        uint256 _timeDelta
    ) private view returns (uint128) {
        InterestTracker memory info = interestTracker[_mintPoolAddress];

        if (_timeDelta == 0) return info.interestIndexGlobal;

        if (_getBorrowRatio(_mintPoolAddress) >= globalBorrowRatioThreshold) {
            return uint128(info.interestIndexGlobal + 
                info.interestIndexGlobal * _timeDelta * borrowRatePerSec / 1e18);
        }

        return info.interestIndexGlobal;
    }

    function _feeAccrued(
        address _mintPoolAddress, 
        uint256 _timeDelta
    ) private view returns (uint256) {
        return totalMinted[_mintPoolAddress] * lybraConfigurator.vaultMintFeeApy(_mintPoolAddress) 
            * _timeDelta / (86_400 * 365) / 10_000;
    }

    function _feePerToken(
        address _mintPoolAddress,
        uint256 _timeDelta
    ) private view returns (uint256) {
        return totalSupplied[_mintPoolAddress] > 0 
            ? feePerTokenStored[_mintPoolAddress] + 
                _feeAccrued(_mintPoolAddress, _timeDelta) * 1e18 / totalSupplied[_mintPoolAddress]
            : feePerTokenStored[_mintPoolAddress];
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

    function _sendRevenue(address _token) private {
        IERC20(_token).safeTransfer(msg.sender, IERC20(_token).balanceOf(address(this)));
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

    function _nonReentrantBefore() private {
        if (reentracncy == ENTERED) revert ReentrancyGuardReentrantCall();
        reentracncy = ENTERED;
    }

    function _nonReentrantAfter() private {
        reentracncy = NOT_ENTERED;
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
        IMintPool(_mintPoolAddress).withdraw(address(this), _amount);
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
        (uint256 borrow, uint256 interest) = getBorrowAndInterest(mintPoolAddress, _account);
        uint256 borrowPlusInterest = borrow + interest;
        if (borrowPlusInterest <= liquidationThreshold) revert HealthyAccount();

        // Both liquidator's & liquidatee's supplied amount will be changed
        rewardManager.lsdUpdateReward(_account, isRebasePool);
        rewardManager.lsdUpdateReward(msg.sender, isRebasePool);

        uint256 maxRepay = (borrowPlusInterest * closeFactorNormal) / 1e20;
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
