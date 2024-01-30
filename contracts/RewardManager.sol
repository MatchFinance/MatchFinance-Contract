// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/LybraInterfaces.sol";
import "./interfaces/IMatchPool.sol";
import "./interfaces/IRewardDistributorFactory.sol";

interface IERC20Mintable {
	function mint(address _to, uint256 _amount) external;
}

error Unauthorized();
error UnpaidInterest(uint256 unpaidAmount);

contract RewardManager is Initializable, OwnableUpgradeable {
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

	// !! @modify Eric 20231030
    uint256 public pendingBoostReward;

    // reward pool => last updated earned() amount from Lybra
	mapping(address => uint256) public earnedPaid;

	// !! @modify Eric 20231030
    address public mesLBRStaking;
    address public vlMatchStaking;

    IConfigurator public lybraConfigurator;

    IRewardDistributorFactory public rewardDistributorFactory;

	event dlpRewardPoolChanged(address newPool);
	event MiningRewardPoolsChanged(address newMining, address newEUSD);
	event RewardShareChanged(uint128 newTreasuryShare, uint128 newStakerShare);
	event TreasuryChanged(address newTreasury);
	event mesLBRChanged(address newMesLBR);
	event mesLBRStakingPoolChanged(address newPool);
	event vlMatchStakingChanged(address newPool);
	event LybraConfiguratorChanged(address newConfigurator);
	event RewardDistributorFactoryChanged(address newFactory);
	event mesLBRRewardClaimed(address account, uint256 rewardAmount);
	event eUSDRewardClaimed(address account, uint256 rewardAmount);
	event RewardDistributedToDistributors(
        uint256 boostReward,
        uint256 treasuryReward,
        uint256 peUSDAmount,
        uint256 altStablecoinAmount
    );

	function initializeTest(address _matchPool) public initializer {
		__Ownable_init();

        matchPool = IMatchPool(_matchPool);
        setMiningRewardShares(10, 10);
    }

	/**
     * @notice Rewards earned by Match Pool since last update, get most updated value by directly calculating
     */
    function earnedSinceLastUpdate(address _rewardPool) public view returns (uint256, uint256, uint256, uint256) {
        IRewardPool rewardPool = IRewardPool(_rewardPool);
        address _matchPool = address(matchPool);

        uint256 matchPoolShares;

        // DLP reward pool is calculated with the staked amount of "DLP"
        if (_rewardPool == dlpRewardPool) matchPoolShares = rewardPool.balanceOf(_matchPool);
        // eUSD mining incentive pool is calculated with the total borrowed(minted) amount of eUSD or peUSD
        else if (_rewardPool == miningIncentive) matchPoolShares = rewardPool.stakedOf(_matchPool);
        else return (0, 0, 0, 0);

        uint256 rpt = rewardPool.rewardPerToken();
        uint256 earnedFromLybra = rewardPool.earned(_matchPool);

        // !! @modify Code added by Eric 20231030
        // Seperate earned esLBR to two parts: normal and boost
        // Boost part goes to mesLBR stakers
        uint256 normalReward = (matchPoolShares * (rpt - rewardPerTokenPaid[_rewardPool])) / 1e18;
        uint256 totalReward = earnedFromLybra - earnedPaid[_rewardPool];
        uint256 boostReward = totalReward - normalReward;

        // !! @modify Code added by Eric 20231030
        // Only return normal reward part
        return (normalReward, rpt, boostReward, earnedFromLybra);
    }

	function rewardPerToken(address _rewardPool) public view returns (uint256) {
		(uint256 dlpEarned, , , ) = earnedSinceLastUpdate(dlpRewardPool);
		(uint256 lsdEarned, , , ) = earnedSinceLastUpdate(miningIncentive);
		uint256 rewardAmount;
		if (_rewardPool == dlpRewardPool) rewardAmount = dlpEarned + lsdEarned * stakerShare / 100;
		else if (_rewardPool == miningIncentive) 
			rewardAmount = lsdEarned * (100 - stakerShare - treasuryShare) / 100;
		else return 0;

		return _rewardPerToken(_rewardPool, rewardAmount);
	}

	function earned(address _account, address _rewardPool) public view returns (uint256) {
		(uint256 dlpEarned, , , ) = earnedSinceLastUpdate(dlpRewardPool);
		(uint256 lsdEarned, , , ) = earnedSinceLastUpdate(miningIncentive);
		uint256 rewardAmount;
		if (_rewardPool == dlpRewardPool) rewardAmount = dlpEarned + lsdEarned * stakerShare / 100;
		else if (_rewardPool == miningIncentive) 
			rewardAmount = lsdEarned * (100 - stakerShare - treasuryShare) / 100;
		else return 0;

		return _earned(_rewardPool, _account, rewardAmount);
	}

	function setDlpRewardPool(address _dlp) external onlyOwner {
		dlpRewardPool = _dlp;

		emit dlpRewardPoolChanged(_dlp);
	}

	function setMiningRewardPools(address _mining, address _eUSD) external onlyOwner {
		miningIncentive = _mining;
		eUSD = _eUSD;

		emit MiningRewardPoolsChanged(_mining, _eUSD);
	}

	function setMiningRewardShares(uint128 _treasuryShare, uint128 _stakerShare) public onlyOwner {
		treasuryShare = _treasuryShare;
		stakerShare = _stakerShare;

		emit RewardShareChanged(_treasuryShare, _stakerShare);
	}

	function setTreasury(address _treasury) external onlyOwner {
		treasury = _treasury;

		emit TreasuryChanged(_treasury);
	}

	function setMesLBR(address _mesLBR) external onlyOwner {
		mesLBR = IERC20Mintable(_mesLBR);

		emit mesLBRChanged(_mesLBR);
	}

	function setMesLBRStakingPool(address _mesLBRStaking) external onlyOwner {
        mesLBRStaking = _mesLBRStaking;
        emit mesLBRStakingPoolChanged(_mesLBRStaking);
    }

    function setVlMatchStaking(address _vlMatchStaking) external onlyOwner {
    	vlMatchStaking = _vlMatchStaking;
    	emit vlMatchStakingChanged(_vlMatchStaking);
    }

    function setLybraConfigurator(address _lybraConfigurator) external onlyOwner {
        lybraConfigurator = IConfigurator(_lybraConfigurator);
        emit LybraConfiguratorChanged(_lybraConfigurator);
    }

    function setRewardDistributorFactory(address _factory) external onlyOwner {
    	rewardDistributorFactory = IRewardDistributorFactory(_factory);
    	emit RewardDistributorFactoryChanged(_factory);
    }
	
	// Update rewards for dlp stakers, includes esLBR from dlp and eUSD
	function dlpUpdateReward(address _account) external {
		// Boost multiplier obtained for calculating mining reward may not be the actual one 
		// Lybra uses if only just reward manager is updated
		if(msg.sender != address(matchPool)) revert Unauthorized();
		_dlpUpdateReward(_account);
	}

	function lsdUpdateReward(address _account) external {
		// Boost multiplier obtained for calculating mining reward may not be the actual one 
		// Lybra uses if only just reward manager is updated
		if(msg.sender != address(matchPool)) revert Unauthorized();
		_lsdUpdateReward(_account);
		_eusdUpdateReward(_account);
	}

	function claimLybraRewards() external {
		// Calculate reward earned since last update till right before claiming.
		// No need to update eUSD reward as claiming rewards from Lybra does not affect supply balances
		// dlpUpdateReward() updates both dlp and mining incentive rewards
		_dlpUpdateReward(address(0));
		matchPool.claimRewards();
		earnedPaid[dlpRewardPool] = 0;
		earnedPaid[miningIncentive] = 0;
	}

	function claimTreasury() external onlyOwner {
		address _treasury = treasury;
		uint256 rewardToTreasury = userRewards[miningIncentive][_treasury];
		userRewards[miningIncentive][_treasury] = 0;
		mesLBR.mint(_treasury, rewardToTreasury);
	}

	function getReward(address _rewardPool) external {
		address _dlpRewardPool = dlpRewardPool;
		address _miningIncentive = miningIncentive;
		uint256 rewardAmount;
 
		if (_rewardPool == _dlpRewardPool) {
			_dlpUpdateReward(msg.sender);

			rewardAmount = userRewards[_dlpRewardPool][msg.sender];
			if (rewardAmount > 0) {
				userRewards[_dlpRewardPool][msg.sender] = 0;
				mesLBR.mint(msg.sender, rewardAmount);
				emit mesLBRRewardClaimed(msg.sender, rewardAmount);
			}

			return;
		}

		if (_rewardPool == _miningIncentive) {
			_lsdUpdateReward(msg.sender);
			_eusdUpdateReward(msg.sender);

			rewardAmount = userRewards[_miningIncentive][msg.sender];
			if (rewardAmount > 0) {
				userRewards[_miningIncentive][msg.sender] = 0;
				mesLBR.mint(msg.sender, rewardAmount);
				emit mesLBRRewardClaimed(msg.sender, rewardAmount);
			}

			rewardAmount = userRewards[eUSD][msg.sender];
			if (rewardAmount > 0) {
				IERC20 _eUSD = IERC20(eUSD);
				// Get actual claim amount, including newly rebased eUSD in this contract
				uint256 actualAmount = _eUSD.balanceOf(address(this)) * 
					userRewards[address(_eUSD)][msg.sender] / totalEUSD;
				userRewards[address(_eUSD)][msg.sender] = 0;
				totalEUSD -= rewardAmount;

				_eUSD.transfer(msg.sender, actualAmount);
				emit eUSDRewardClaimed(msg.sender, rewardAmount);
			}

			return;
		}
	}

	function getAllRewards() external {
		address _dlpRewardPool = dlpRewardPool;
		address _miningIncentive = miningIncentive;
		// Update dlp & mining global var, dlp user var
		_dlpUpdateReward(msg.sender);
		// Update mining user var
		_updateUserVar(_miningIncentive, msg.sender);
		// Update eUSD global var & user var
		_eusdUpdateReward(msg.sender);

		uint256 rewardAmount = (userRewards[_dlpRewardPool][msg.sender] +
			userRewards[_miningIncentive][msg.sender]);
		userRewards[_dlpRewardPool][msg.sender] = 0;
		userRewards[_miningIncentive][msg.sender] = 0;
		mesLBR.mint(msg.sender, rewardAmount);
		emit mesLBRRewardClaimed(msg.sender, rewardAmount);

		rewardAmount = userRewards[eUSD][msg.sender];
		IERC20 _eUSD = IERC20(eUSD);
		// Get actual claim amount, including newly rebased eUSD in this contract
		uint256 actualAmount = _eUSD.balanceOf(address(this)) * userRewards[eUSD][msg.sender] / totalEUSD;
		userRewards[eUSD][msg.sender] = 0;
		totalEUSD -= rewardAmount;
		_eUSD.transfer(msg.sender, actualAmount);
		emit eUSDRewardClaimed(msg.sender, rewardAmount);
	}

	// ! We can call this function periodically to update reward distributors
    // Update and distribute the reward to several distributors
    // Includes:
    //   - boost reward to mesLBR stakers (1 distributor)
    //   - treasury reward to vlMatch stakers (1 distributor)
    //   - protocol revenue to mesLBR stakers (2 distributors)
    function updateRewardDistributors() public {
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
        address boostReceiver = IRewardDistributorFactory(rewardDistributorFactory).distributors(
            address(mesLBR),
            mesLBRStaking
        );
        require(boostReceiver != address(0), "Invalid distributor");
        mesLBR.mint(boostReceiver, _boostReward);

        // Transfer treasury reward to reward distributor for vlMatch staking
        // Reward token: mesLBR
        // Receiver: vlMatch staking contract
        address treasuryReceiver = IRewardDistributorFactory(rewardDistributorFactory).distributors(
            address(mesLBR),
            vlMatchStaking
        );
        require(treasuryReceiver != address(0), "Invalid distributor");
        mesLBR.mint(treasuryReceiver, _treasuryReward);

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
            mesLBRStaking
        );
        require(peUSDReceiver != address(0), "No peUSD distributor");
        IERC20(peUSD).transfer(peUSDReceiver, peUSDBalance);

        address altStablecoinReceiver = IRewardDistributorFactory(rewardDistributorFactory).distributors(
            altStablecoin,
            mesLBRStaking
        );
        require(altStablecoinReceiver != address(0), "No altStablecoin distributor");
        IERC20(altStablecoin).transfer(altStablecoinReceiver, altStablecoinBalance);

        emit RewardDistributedToDistributors(_boostReward, _treasuryReward, peUSDBalance, altStablecoinBalance);
    }

	function _rewardPerToken(address _rewardPool, uint256 _rewardAmount) private view returns (uint256) {
		uint256 rptStored = rewardPerTokenStored[_rewardPool];
		uint256 totalToken;
		if (_rewardPool == dlpRewardPool) totalToken = matchPool.totalStaked();
		// Support only stETH for version 1
		if (_rewardPool == miningIncentive || _rewardPool == eUSD) 
			totalToken = matchPool.totalSupplied(address(matchPool.getMintPool()));

		return totalToken > 0 ? rptStored + _rewardAmount * 1e18 / totalToken : rptStored;
	}

	function _earned(
		address _rewardPool,
		address _account,
		uint256 _rewardAmount
	) private view returns (uint256) {
		uint256 share;
		if (_rewardPool == dlpRewardPool) share = matchPool.staked(_account);
		// Support only stETH for version 1
		if (_rewardPool == miningIncentive || _rewardPool == eUSD) 
			share = matchPool.supplied(address(matchPool.getMintPool()), _account);

		return share * (_rewardPerToken(_rewardPool, _rewardAmount) - 
			userRewardsPerTokenPaid[_rewardPool][_account]) / 1e18 + userRewards[_rewardPool][_account];
	}

	function _dlpUpdateReward(address _account) private {
		address _dlpRewardPool = dlpRewardPool;
		address _miningIncentive = miningIncentive;

		// dLP stake pool does not have boost reward
		(uint256 dlpNormal,) = _updateGlobalVar(_dlpRewardPool);
		(uint256 lsdNormal, uint256 lsdBoost) = _updateGlobalVar(_miningIncentive);

		if (lsdNormal > 0) {
			(uint256 toStaker, uint256 toSupplier) = _calcRewardShares(lsdNormal);
			dlpNormal += toStaker;

			rewardPerTokenStored[_miningIncentive] = _rewardPerToken(_miningIncentive, toSupplier);

			// dLP stake pool does not have boost reward
	        pendingBoostReward += lsdBoost;
		}

		if (dlpNormal > 0) rewardPerTokenStored[_dlpRewardPool] = _rewardPerToken(_dlpRewardPool, dlpNormal);

		_updateUserVar(_dlpRewardPool, _account);
	}

	function _lsdUpdateReward(address _account) private {
		address _dlpRewardPool = dlpRewardPool;
		address _miningIncentive = miningIncentive;

		// esLBR earned from Lybra eUSD mining incentive
        // !! @modify Code added by Eric 20231030
        (uint256 lsdNormal, uint256 lsdBoost) = _updateGlobalVar(_miningIncentive);

		if (lsdNormal > 0) {
			(uint256 toStaker, uint256 toSupplier) = _calcRewardShares(lsdNormal);

			rewardPerTokenStored[_dlpRewardPool] = _rewardPerToken(_dlpRewardPool, toStaker);
			rewardPerTokenStored[_miningIncentive] = _rewardPerToken(_miningIncentive, toSupplier);

			// !! @modify Code added by Eric 20231030
	        // !! @modify Code moved by Eric 20231228
	        pendingBoostReward += lsdBoost;
		}

		_updateUserVar(_miningIncentive, _account);
	}

	function _eusdUpdateReward(address _account) private {
		address _eUSD = eUSD;
		uint256 eusdEarned = matchPool.claimRebase();
		if (eusdEarned > 0) {
			totalEUSD += eusdEarned;
			rewardPerTokenStored[_eUSD] = _rewardPerToken(_eUSD, eusdEarned);
		}

		if (_account == address(0)) return;

		(uint256 borrowedAmount,,,) = matchPool.borrowed(address(matchPool.getMintPool()), _account);
		if (borrowedAmount == 0) userRewards[_eUSD][_account] = _earned(_eUSD, _account, 0);
			// Users who borrowed eUSD will not share rebase reward
		else userRewards[_eUSD][treasury] += (_earned(_eUSD, _account, 0) - userRewards[_eUSD][_account]);

		userRewardsPerTokenPaid[_eUSD][_account] = rewardPerTokenStored[_eUSD];
	}

	/**
	 * @dev Update variables for Lybra reward calculation
	 */
	function _updateGlobalVar(address _rewardPool) private returns (uint256, uint256) {
		(
        	uint256 normalReward, 
        	uint256 lybraRpt, 
			uint256 boostReward, 
        	uint256 lybraEarned
        ) = earnedSinceLastUpdate(_rewardPool);
		rewardPerTokenPaid[_rewardPool] = lybraRpt;
		earnedPaid[_rewardPool] = lybraEarned;

		return (normalReward, boostReward);
	}

	/**
	 * @dev Update variables for user reward calculation
	 */
	function _updateUserVar(address _rewardPool, address _account) private {
		if (_account == address(0)) return;
		userRewards[_rewardPool][_account] = _earned(_rewardPool, _account, 0);
		userRewardsPerTokenPaid[_rewardPool][_account] = rewardPerTokenStored[_rewardPool];
	}

	/**
	 * @dev Divide mining reward to appropriate shares for treasury, stakers, suppliers
	 */
	function _calcRewardShares(uint256 _rewardAmount) private returns (
		uint256 toStaker,
		uint256 toSupplier
	) {
		uint256 toTreasury = _rewardAmount * treasuryShare / 100;
		if (toTreasury > 0) userRewards[miningIncentive][treasury] += toTreasury;
		// esLBR reward from mining incentive given to dlp stakers
		toStaker = _rewardAmount * stakerShare / 100;
		// esLBR reward from mining incentive given to stETH suppliers
		toSupplier = _rewardAmount - toTreasury - toStaker;
	}
}
