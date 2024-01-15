// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/LybraInterfaces.sol";
import "./interfaces/IMatchPool.sol";
import { IMTokenStaking } from "./interfaces/IMTokenStaking.sol";
import { IRewardCenter } from "./interfaces/IRewardCenter.sol";
import { IERC20Mintable } from "./interfaces/IERC20Mintable.sol";
import { IRewardDistributorFactory } from "./interfaces/IRewardDistributorFactory.sol";

error UnpaidInterest();
error RewardNotOpen();
error ReentrancyGuardReentrantCall();
error WIP();

contract RewardManager is Initializable, OwnableUpgradeable {
    uint256 constant ENTERED = 1;
    uint256 constant NOT_ENTERED = 2;

    IMatchPool public matchPool;

    // reward pool => amount
    // 1. dlp reward pool (dlp + 20% mining incentive)
    // 2. lsd reward pool (80% mining incentive)
    // 3. eUSD (rebase)
    mapping(address => uint256) public rewardPerTokenStored;
    // Last update timestamp in reward pool may not be now
    // Maintain own version of token paid for calculating most updated reward amount
    mapping(address => uint256) public rewardPerTokenPaid;
    // reward pool => account => amount
    mapping(address => mapping(address => uint256)) public userRewardsPerTokenPaid;
    mapping(address => mapping(address => uint256)) public userRewards;

    // Total amount of eUSD claimed from Match Pool
    // Get actual claim amount after/if eUSD has rebased within this contract
    uint256 totalEUSD;

    address public dlpRewardPool; // stake reward pool
    address public miningIncentive; // eUSD mining incentive
    address public eUSD; // eUSD rebase
    // Receive eUSD rebase and esLBR from mining incentive;
    address public treasury;

    // Mining reward share, out of 100
    uint128 treasuryShare;
    uint128 stakerShare;

    IERC20Mintable public mesLBR;

    /******************************************************************/

    uint256 reentracncy;

    // !! @modify Eric 20231030
    IMTokenStaking public mesLBRStaking;
    address public vlMatchStaking;

    // !! @modify Eric 20231030
    uint256 public pendingBoostReward;

    IConfigurator public lybraConfigurator;

    address public rewardDistributorFactory;

    // ---------------------------------------------------------------------------------------- //
    // *************************************** Events ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    event dlpRewardPoolChanged(address newPool);
    event MiningRewardPoolsChanged(address newMiningIncentive, address newEUSD);
    event ProtocolRevenuePoolChanged(address newPool);
    event mesLBRStakingPoolChanged(address newPool);
    event RewardSharesChanged(uint128 newTreasuryShare, uint128 newStakerShare);
    event TreasuryChanged(address newTreausry);
    event mesLBRChanged(address newMesLBR);
    event RewardDistributorChanged(address rewardToken, address newDistributor);
    event LybraConfiguratorChanged(address newConfigurator);
    event DLPRewardClaimed(address account, uint256 rewardAmount);
    event LSDRewardClaimed(address account, uint256 rewardAmount);
    event eUSDRewardClaimed(address account, uint256 rewardAmount);
    event RewardDistributedToDistributors(
        uint256 boostReward,
        uint256 treasuryReward,
        uint256 peUSDAmount,
        uint256 altStablecoinAmount
    );

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    // function initializeTest(address _matchPool) public initializer {
    //     __Ownable_init();

    //     matchPool = IMatchPool(_matchPool);
    //     setMiningRewardShares(0, 20);
    // }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ View Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Rewards earned by Match Pool since last update, get most updated value by directly calculating
     */
    function earnedSinceLastUpdate(address _rewardPool) public view returns (uint256, uint256, uint256) {
        IRewardPool rewardPool = IRewardPool(_rewardPool);
        address _matchPool = address(matchPool);

        uint256 matchPoolShares;

        // DLP reward pool is calculated with the staked amount of "DLP"
        if (_rewardPool == dlpRewardPool)
            matchPoolShares = rewardPool.balanceOf(_matchPool);
            // eUSD mining incentive pool is calculated with the total borrowed(minted) amount of eUSD or peUSD
        else if (_rewardPool == miningIncentive) matchPoolShares = rewardPool.stakedOf(_matchPool);
        else return (0, 0, 0);

        uint256 rpt = rewardPool.rewardPerToken();

        // !! @modify Code added by Eric 20231030
        // Seperate earned esLBR to two parts: normal and boost
        // Boost part goes to mesLBR stakers
        uint256 normalReward = (matchPoolShares * (rpt - rewardPerTokenPaid[_rewardPool])) / 1e18;
        uint256 totalReward = (normalReward * rewardPool.getBoost(_matchPool)) / 1e20;

        uint256 boostReward = totalReward - normalReward;

        // !! @modify Code added by Eric 20231030
        // Only return normal reward part
        return (normalReward, rpt, boostReward);
    }

    function rewardPerToken(address _rewardPool) public view returns (uint256) {
        (uint256 dlpEarned, , ) = earnedSinceLastUpdate(dlpRewardPool);
        (uint256 lsdEarned, , ) = earnedSinceLastUpdate(miningIncentive);

        uint256 rewardAmount;
        if (_rewardPool == dlpRewardPool) rewardAmount = dlpEarned + (lsdEarned * stakerShare) / 100;
        else if (_rewardPool == miningIncentive) rewardAmount = (lsdEarned * (100 - stakerShare - treasuryShare)) / 100;
        else return 0;

        (uint256 rpt, ) = _rewardPerToken(address(0), _rewardPool, rewardAmount);
        return rpt;
    }

    function earned(address _account, address _rewardPool) public view returns (uint256) {
        (uint256 dlpEarned, , ) = earnedSinceLastUpdate(dlpRewardPool);
        (uint256 lsdEarned, , ) = earnedSinceLastUpdate(miningIncentive);
        uint256 rewardAmount;
        if (_rewardPool == dlpRewardPool) rewardAmount = dlpEarned + (lsdEarned * stakerShare) / 100;
        else if (_rewardPool == miningIncentive) rewardAmount = (lsdEarned * (100 - stakerShare - treasuryShare)) / 100;
        else return 0;

        return _earned(_account, _rewardPool, rewardAmount);
    }

    /**
     * @notice Cannot get eUSD rebase reward if borrowed eUSD from any mint pool
     */
    function hasBorrowedEUSD(address _account) public view returns (bool) {
        address[] memory mintPools = matchPool.getMintPools();

        for (uint256 i; i < mintPools.length; ) {
            if (matchPool.isRebase(mintPools[i])) {
                (uint256 borrowedAmount, , , ) = matchPool.borrowed(mintPools[i], _account);
                if (borrowedAmount > 0) return true;
            }

            unchecked {
                ++i;
            }
        }

        return false;
    }

    /**
     * @notice Returns amount of rebase LSD that contributed to earning eUSD rebase
     * @dev Rebase mint pools that did not mint anything will not share rebase reward
     */
    function getRebaseSupplies(address _account) public view returns (uint256 total, uint256 individual) {
        address[] memory mintPools = matchPool.getMintPools();

        if (_account == address(0)) {
            for (uint256 i; i < mintPools.length; ) {
                IMintPool mintPool = IMintPool(mintPools[i]);
                address mintPoolAddress = address(mintPool);
                if (matchPool.isRebase(mintPoolAddress) && matchPool.totalMinted(mintPoolAddress) > 0) {
                    // stETH pool
                    if (i == 0) total += matchPool.totalSupplied(mintPoolAddress);
                    else total += matchPool.totalSuppliedReward(mintPoolAddress);
                }

                unchecked {
                    ++i;
                }
            }
        } else {
            for (uint256 i; i < mintPools.length; ) {
                IMintPool mintPool = IMintPool(mintPools[i]);
                address mintPoolAddress = address(mintPool);
                if (matchPool.isRebase(mintPoolAddress) && matchPool.totalMinted(mintPoolAddress) > 0) {
                    // stETH pool
                    if (i == 0) {
                        total += matchPool.totalSupplied(mintPoolAddress);
                        individual += matchPool.supplied(mintPoolAddress, _account);
                    } else {
                        total += matchPool.totalSuppliedReward(mintPoolAddress);
                        individual += matchPool.suppliedReward(mintPoolAddress, _account);
                    }
                }

                unchecked {
                    ++i;
                }
            }
        }
    }

    /**
     * @notice Returns amount of LSD (regardless of type) that contributed to earning mining rewards
     * @dev Mint pools that did not mint anything will not share mining reward
     */
    function getEarningSupplies(address _account) public view returns (uint256 total, uint256 individual) {
        address[] memory mintPools = matchPool.getMintPools();

        if (_account == address(0)) {
            for (uint256 i; i < mintPools.length; ) {
                IMintPool mintPool = IMintPool(mintPools[i]);
                address mintPoolAddress = address(mintPool);
                if (matchPool.totalMinted(mintPoolAddress) > 0) {
                    // stETH pool
                    if (i == 0) total += matchPool.totalSupplied(mintPoolAddress);
                    else total += matchPool.totalSuppliedReward(mintPoolAddress);
                }

                unchecked {
                    ++i;
                }
            }
        } else {
            for (uint256 i; i < mintPools.length; ) {
                IMintPool mintPool = IMintPool(mintPools[i]);
                address mintPoolAddress = address(mintPool);
                if (matchPool.totalMinted(mintPoolAddress) > 0) {
                    // stETH pool
                    if (i == 0) {
                        total += matchPool.totalSupplied(mintPoolAddress);
                        individual += matchPool.supplied(mintPoolAddress, _account);
                    } else {
                        total += matchPool.totalSuppliedReward(mintPoolAddress);
                        individual += matchPool.suppliedReward(mintPoolAddress, _account);
                    }
                }

                unchecked {
                    ++i;
                }
            }
        }
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Set Functions ************************************* //
    // ---------------------------------------------------------------------------------------- //

    function setDlpRewardPool(address _dlp) external onlyOwner {
        dlpRewardPool = _dlp;
        emit dlpRewardPoolChanged(_dlp);
    }

    function setMiningRewardPools(address _mining, address _eUSD) external onlyOwner {
        miningIncentive = _mining;
        eUSD = _eUSD;
        emit MiningRewardPoolsChanged(_mining, _eUSD);
    }

    function setMesLBRStakingPool(address _mesLBRStaking) external onlyOwner {
        mesLBRStaking = IMTokenStaking(_mesLBRStaking);
        emit mesLBRStakingPoolChanged(_mesLBRStaking);
    }

    function setMiningRewardShares(uint128 _treasuryShare, uint128 _stakerShare) public onlyOwner {
        treasuryShare = _treasuryShare;
        stakerShare = _stakerShare;
        emit RewardSharesChanged(_treasuryShare, _stakerShare);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit TreasuryChanged(_treasury);
    }

    function setMesLBR(address _mesLBR) external onlyOwner {
        mesLBR = IERC20Mintable(_mesLBR);
        emit mesLBRChanged(_mesLBR);
    }

    function setLybraConfigurator(address _lybraConfigurator) external onlyOwner {
        lybraConfigurator = IConfigurator(_lybraConfigurator);
        emit LybraConfiguratorChanged(_lybraConfigurator);
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Main Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    // Update rewards for dlp stakers, includes esLBR from dlp and eUSD
    function dlpUpdateReward(address _account) public {
        address _dlpRewardPool = dlpRewardPool;
        address _miningIncentive = miningIncentive;

        // esLBR earned from Lybra ETH-LBR LP stake reward pool
        // !! @modify Code added by Eric 20231030
        (uint256 dlpEarned, uint256 dlpRpt, uint256 boostReward) = earnedSinceLastUpdate(_dlpRewardPool);
        rewardPerTokenPaid[_dlpRewardPool] = dlpRpt;

        uint256 toStaker;
        uint256 rpt;
        if (_miningIncentive != address(0)) {
            // esLBR earned from Lybra eUSD mining incentive
            // !! @modify Code added by Eric 20231030
            (uint256 lsdEarned, uint256 lsdRpt, uint256 boostRewardFromMining) = earnedSinceLastUpdate(
                _miningIncentive
            );
            rewardPerTokenPaid[_miningIncentive] = lsdRpt;

            uint256 toTreasury = (lsdEarned * treasuryShare) / 100;
            if (toTreasury > 0) userRewards[_miningIncentive][treasury] += toTreasury;
            // esLBR reward from mining incentive given to dlp stakers
            toStaker = (lsdEarned * stakerShare) / 100;
            // esLBR reward from mining incentive given to stETH suppliers
            uint256 toSupplier = lsdEarned - toTreasury - toStaker;

            (rpt, ) = _rewardPerToken(address(0), _miningIncentive, toSupplier);
            rewardPerTokenStored[_miningIncentive] = rpt;

            // !! @modify Code added by Eric 20231030

            boostReward += boostRewardFromMining;
        }

        (rpt, ) = _rewardPerToken(address(0), _dlpRewardPool, dlpEarned + toStaker);
        rewardPerTokenStored[_dlpRewardPool] = rpt;

        // !! @modify Code added by Eric 20231030
        // !! @modify Code moved by Eric 20231228
        pendingBoostReward += boostReward;

        if (_account == address(0)) return;

        userRewards[_dlpRewardPool][_account] = _earned(_account, _dlpRewardPool, 0);
        userRewardsPerTokenPaid[_dlpRewardPool][_account] = rewardPerTokenStored[_dlpRewardPool];
    }

    function lsdUpdateReward(address _account, bool _isRebase) public {
        address _dlpRewardPool = dlpRewardPool;
        address _miningIncentive = miningIncentive;

        // esLBR earned from Lybra eUSD mining incentive
        // !! @modify Code added by Eric 20231030
        (uint256 lsdEarned, uint256 lsdRpt, uint256 boostReward) = earnedSinceLastUpdate(_miningIncentive);
        rewardPerTokenPaid[_miningIncentive] = lsdRpt;

        uint256 toSupplier;
        uint256 rpt;
        if (lsdEarned > 0) {
            uint256 toTreasury = (lsdEarned * treasuryShare) / 100;
            if (toTreasury > 0) userRewards[_miningIncentive][treasury] += toTreasury;
            // esLBR reward from mining incentive given to dlp stakers
            uint256 toStaker = (lsdEarned * stakerShare) / 100;
            // esLBR reward from mining incentive given to stETH suppliers
            toSupplier = lsdEarned - toTreasury - toStaker;

            (rpt, ) = _rewardPerToken(address(0), _dlpRewardPool, toStaker);
            rewardPerTokenStored[_dlpRewardPool] = rpt;
            (rpt, ) = _rewardPerToken(address(0), _miningIncentive, toSupplier);
            rewardPerTokenStored[_miningIncentive] = rpt;
        }

        uint256 eusdEarned;
        address _eUSD;
        if (_isRebase) {
            _eUSD = eUSD;
            eusdEarned = matchPool.claimRebase();
            if (eusdEarned > 0) {
                totalEUSD += eusdEarned;
                (rpt, ) = _rewardPerToken(address(0), _eUSD, eusdEarned);
                rewardPerTokenStored[_eUSD] = rpt;
            }
        }

        // !! @modify Code added by Eric 20231030
        // !! @modify Code moved by Eric 20231228
        pendingBoostReward += boostReward;

        if (_account == address(0)) return;

        userRewards[_miningIncentive][_account] = _earned(_account, _miningIncentive, 0);
        userRewardsPerTokenPaid[_miningIncentive][_account] = rewardPerTokenStored[_miningIncentive];

        if (_isRebase) {
            if (!hasBorrowedEUSD(_account))
                userRewards[_eUSD][_account] = _earned(_account, _eUSD, 0);
                // Users who borrowed eUSD will not share rebase reward
            else userRewards[_eUSD][treasury] += (_earned(_account, _eUSD, 0) - userRewards[_eUSD][_account]);
            userRewardsPerTokenPaid[_eUSD][_account] = rewardPerTokenStored[_eUSD];
        }
    }

    function getReward(address _rewardPool, bool _stakeNow) public nonReentrant {
        revert WIP();
        if (address(mesLBR) == address(0)) revert RewardNotOpen();

        address _dlpRewardPool = dlpRewardPool;
        address _miningIncentive = miningIncentive;
        uint256 rewardAmount;

        if (_rewardPool == _dlpRewardPool) {
            dlpUpdateReward(msg.sender);

            rewardAmount = userRewards[_dlpRewardPool][msg.sender];
            if (rewardAmount > 0) {
                userRewards[_dlpRewardPool][msg.sender] = 0;
                mesLBR.mint(msg.sender, rewardAmount);
                if (_stakeNow) mesLBRStaking.delegateStake(msg.sender, rewardAmount);
                emit DLPRewardClaimed(msg.sender, rewardAmount);
            }

            // !! @modify Code added by Eric 20231030
            // !! @modify Code commented by Eric 20231228
            // Only update when users claim their rewards
            // updateRewardDistributors();
            // return;
        }

        if (_rewardPool == _miningIncentive) {
            lsdUpdateReward(msg.sender, true);

            rewardAmount = userRewards[_miningIncentive][msg.sender];
            if (rewardAmount > 0) {
                userRewards[_miningIncentive][msg.sender] = 0;
                mesLBR.mint(msg.sender, rewardAmount);
                if (_stakeNow) mesLBRStaking.delegateStake(msg.sender, rewardAmount);
                emit LSDRewardClaimed(msg.sender, rewardAmount);
            }

            rewardAmount = userRewards[eUSD][msg.sender];
            if (rewardAmount > 0) {
                IERC20 _eUSD = IERC20(eUSD);
                // Get actual claim amount, including newly rebased eUSD in this contract
                uint256 actualAmount = (_eUSD.balanceOf(address(this)) * userRewards[eUSD][msg.sender]) / totalEUSD;
                userRewards[eUSD][msg.sender] = 0;
                totalEUSD -= rewardAmount;

                _eUSD.transfer(msg.sender, actualAmount);
                emit eUSDRewardClaimed(msg.sender, rewardAmount);
            }

            // !! @modify Code added by Eric 20231030
            // !! @modify Code commented by Eric 20231228
            // Only update when users claim their rewards
            // updateRewardDistributors();
            // return;
        }
    }

    // ! We can call this function periodically to update reward distributors
    // Update and distribute the reward to several distributors
    // Includes:
    //   - boost reward to mesLBR stakers (1 distributor)
    //   - treasury reward to vlMatch stakers (1 distributor)
    //   - protocol revenue to mesLBR stakers (2 distributors)
    function updateRewardDistributors() public {
        revert WIP();
        // !! @modify Code added by Eric 20231030
        uint256 protocolRevenue = IRewardPool(lybraConfigurator.getProtocolRewardsPool()).earned(address(matchPool));

        // Get peUSD(or peUSD & USDC)
        // Protocol revenue will first goes to this contract
        // In lybra protocol revenue cotract, it will give peUSD if it is enough,
        // if it is not enough, it will give peUSD + altStablecoin.
        // But it will not tell you the amount of each token.
        if (protocolRevenue > 0) {
            IMatchPool(matchPool).claimProtocolRevenue();
        }

        // Distribute treasury reward part to distributors, for vlMatch staking
        uint256 rewardToTreasury = userRewards[miningIncentive][treasury];
        userRewards[miningIncentive][treasury] = 0;

        // !! @modify Code added by Eric 20231030
        // pendingBoostReward has been updated in the previous "getReward" funciton inside "getAllRewards"
        if (pendingBoostReward > 0) {
            _distributeRewardToDistributors(pendingBoostReward, rewardToTreasury);

            // delete this buffer
            pendingBoostReward = 0;
        } else _distributeRewardToDistributors(0, rewardToTreasury);
    }

    /**
     * @notice Distribute the reward to corresponding distributor contracts
     *
     * @dev    Total mesLBR Reward: 150 = boost reward (50) + treasury reward (100)
     *
     *         Boost Reward to:
     *         1) mesLBR staking (40)
     *
     *         Treasury Reward to:
     *         1) vlMatch staking (10)
     *
     *         peUSD / altStablecoin to:
     *         1) mesLBR staking
     */
    function _distributeRewardToDistributors(uint256 _boostReward, uint256 _treasuryReward) internal {
        // Mint boost reward mesLBR to reward distributor
        // Reward token: mesLBR
        // Receiver: mesLBR staking contract
        mesLBR.mint(
            IRewardDistributorFactory(rewardDistributorFactory).distributors(address(mesLBR), address(mesLBRStaking)),
            _boostReward
        );

        // Transfer treasury reward to reward distributor for vlMatch staking
        // Reward token: mesLBR
        // Receiver: vlMatch staking contract
        mesLBR.mint(
            IRewardDistributorFactory(rewardDistributorFactory).distributors(address(mesLBR), vlMatchStaking),
            _treasuryReward
        );

        // Transfer stablecoin protocol revenue to reward distributor
        address peUSD = lybraConfigurator.peUSD();
        address altStablecoin = lybraConfigurator.stableToken();

        uint256 peUSDBalance = IERC20(peUSD).balanceOf(address(this));
        uint256 altStablecoinBalance = IERC20(altStablecoin).balanceOf(address(this));

        // ! Transfer all peUSD and altStablecoin to their distributors
        // ! It seems proper for now
        // ! All peUSD and altStablecoin inside this contract is from protocol revenue
        // ! --------------------
        // ! 20240112 Need to ensure the distributor contract exists or we will transfer to zero address
        // ! If Lybra changes the altStablecoin we need to add a new distributor (no change in this contract)
        address peUSDReceiver = IRewardDistributorFactory(rewardDistributorFactory).distributors(
            peUSD,
            address(mesLBRStaking)
        );
        require(peUSDReceiver != address(0), "No peUSD distributor");
        IERC20(peUSD).transfer(peUSDReceiver, peUSDBalance);

        address altStablecoinReceiver = IRewardDistributorFactory(rewardDistributorFactory).distributors(
            altStablecoin,
            address(mesLBRStaking)
        );
        require(altStablecoinReceiver != address(0), "No altStablecoin distributor");
        IERC20(altStablecoin).transfer(altStablecoinReceiver, altStablecoinBalance);

        emit RewardDistributedToDistributors(_boostReward, _treasuryReward, peUSDBalance, altStablecoinBalance);
    }

    function getAllRewards(bool _stakeNow) external {
        getReward(dlpRewardPool, _stakeNow);
        getReward(miningIncentive, _stakeNow);
    }

    // ---------------------------------------------------------------------------------------- //
    // *********************************** Internal Functions ********************************* //
    // ---------------------------------------------------------------------------------------- //

    function _rewardPerToken(
        address _account,
        address _rewardPool,
        uint256 _rewardAmount
    ) private view returns (uint256, uint256) {
        uint256 totalToken;
        uint256 share;
        // @note Cheap. Directly read.
        if (_rewardPool == dlpRewardPool) totalToken = matchPool.totalStaked();
        else if (_rewardPool == miningIncentive) (totalToken, share) = getEarningSupplies(_account);
        else if (_rewardPool == eUSD) (totalToken, share) = getRebaseSupplies(_account);

        uint256 rptStored = rewardPerTokenStored[_rewardPool];
        return (totalToken > 0 ? rptStored + (_rewardAmount * 1e18) / totalToken : rptStored, share);
    }

    function _earned(address _account, address _rewardPool, uint256 _rewardAmount) private view returns (uint256) {
        (uint256 rpt, uint256 share) = _rewardPerToken(_account, _rewardPool, _rewardAmount);
        // _rewardPerToken() for dlpRewardPool returns 0 as share
        if (_rewardPool == dlpRewardPool) share = matchPool.staked(_account);

        return
            (share * (rpt - userRewardsPerTokenPaid[_rewardPool][_account])) /
            1e18 +
            userRewards[_rewardPool][_account];
    }

    function _nonReentrantBefore() private {
        if (reentracncy == ENTERED) revert ReentrancyGuardReentrantCall();
        reentracncy = ENTERED;
    }

    function _nonReentrantAfter() private {
        reentracncy = NOT_ENTERED;
    }
}
