// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/LybraInterfaces.sol";
import "./interfaces/IMatchPool.sol";

interface IERC20Mintable {
	function mint(address _to, uint256 _amount) external;
}

error Unauthorized();
error UnpaidInterest(uint256 unpaidAmount);
error RewardNotOpen();

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

	event dlpRewardPoolChanged(address newPool);
	event MiningRewardPoolsChanged(address newMining, address newEUSD);
	event RewardShareChanged(uint128 newTreasuryShare, uint128 newStakerShare);
	event TreasuryChanged(address newTreasury);
	event mesLBRChanged(address newMesLBR);
	event DLPRewardClaimed(address account, uint256 rewardAmount);
	event LSDRewardClaimed(address account, uint256 rewardAmount);
	event eUSDRewardClaimed(address account, uint256 rewardAmount);

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
        if (_rewardPool == dlpRewardPool)
            matchPoolShares = rewardPool.balanceOf(_matchPool);
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
		else if (_rewardPool == miningIncentive) rewardAmount = lsdEarned * (100 - stakerShare - treasuryShare) / 100;

		return _rewardPerToken(_rewardPool, rewardAmount);
	}

	function earned(address _account, address _rewardPool) public view returns (uint256) {
		(uint256 dlpEarned, , , ) = earnedSinceLastUpdate(dlpRewardPool);
		(uint256 lsdEarned, , , ) = earnedSinceLastUpdate(miningIncentive);
		uint256 rewardAmount;
		if (_rewardPool == dlpRewardPool) rewardAmount = dlpEarned + lsdEarned * stakerShare / 100;
		else if (_rewardPool == miningIncentive) rewardAmount = lsdEarned * (100 - stakerShare - treasuryShare) / 100;

		return _earned(_account, _rewardPool, rewardAmount);
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

	function varInitialize() external onlyOwner {
    	// tx 0xacf569aae8ffd2202cfdeaf517151db5b17a72651fceeb5ed9dadea47558bda0 skipped eUSD reward update
    	userRewards[eUSD][0x2A52F2e021808f27b821Ff24204cE0a00b631e20] = 44854693994177419772;
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

	// function getReward(address _rewardPool) public {
	// 	if (address(mesLBR) == address(0)) revert RewardNotOpen();

	// 	// Cannot claim rewards if has not fully repaid eUSD interest
	// 	// due to borrowing when above { globalBorrowRatioThreshold }
	// 	(,, uint256 unpaidInterest,) = matchPool.borrowed(address(matchPool.getMintPool()), msg.sender);
	// 	if (unpaidInterest > 0) revert UnpaidInterest(unpaidInterest);

	// 	address _dlpRewardPool = dlpRewardPool;
	// 	address _miningIncentive = miningIncentive;
	// 	uint256 rewardAmount;

	// 	if (_rewardPool == _dlpRewardPool) {
	// 		dlpUpdateReward(msg.sender);

	// 		rewardAmount = userRewards[_dlpRewardPool][msg.sender];
	// 		if (rewardAmount > 0) {
	// 			userRewards[_dlpRewardPool][msg.sender] = 0;
	// 			mesLBR.mint(msg.sender, rewardAmount);
	// 			emit DLPRewardClaimed(msg.sender, rewardAmount);
	// 		}

	// 		return;
	// 	}

	// 	if (_rewardPool == _miningIncentive) {
	// 		lsdUpdateReward(msg.sender);

	// 		rewardAmount = userRewards[_miningIncentive][msg.sender];
	// 		if (rewardAmount > 0) {
	// 			userRewards[_miningIncentive][msg.sender] = 0;
	// 			mesLBR.mint(msg.sender, rewardAmount);
	// 			emit LSDRewardClaimed(msg.sender, rewardAmount);
	// 		}

	// 		rewardAmount = userRewards[eUSD][msg.sender];
	// 		if (rewardAmount > 0) {
	// 			IERC20 _eUSD = IERC20(eUSD);
	// 			// Get actual claim amount, including newly rebased eUSD in this contract
	// 			uint256 actualAmount = _eUSD.balanceOf(address(this)) * userRewards[eUSD][msg.sender] / totalEUSD;
	// 			userRewards[eUSD][msg.sender] = 0;
	// 			totalEUSD -= rewardAmount;

	// 			_eUSD.transfer(msg.sender, actualAmount);
	// 			emit eUSDRewardClaimed(msg.sender, rewardAmount);
	// 		}

	// 		return;
	// 	}
	// }

	// function getAllRewards() external {
	// 	getReward(dlpRewardPool);
	// 	getReward(miningIncentive);
	// }

	function _rewardPerToken(address _rewardPool, uint256 _rewardAmount) private view returns (uint256) {
		uint256 rptStored = rewardPerTokenStored[_rewardPool];
		uint256 totalToken;
		if (_rewardPool == dlpRewardPool) totalToken = matchPool.totalStaked();
		// Support only stETH for version 1
		if (_rewardPool == miningIncentive || _rewardPool == eUSD) totalToken = matchPool.totalSupplied(address(matchPool.getMintPool()));

		return totalToken > 0 ? rptStored + _rewardAmount * 1e18 / totalToken : rptStored;
	}

	function _earned(address _account, address _rewardPool, uint256 _rewardAmount) private view returns (uint256) {
		uint256 share;
		if (_rewardPool == dlpRewardPool) share = matchPool.staked(_account);
		// Support only stETH for version 1
		if (_rewardPool == miningIncentive || _rewardPool == eUSD) share = matchPool.supplied(address(matchPool.getMintPool()), _account);

		return share * (_rewardPerToken(_rewardPool, _rewardAmount) - 
			userRewardsPerTokenPaid[_rewardPool][_account]) / 1e18 + userRewards[_rewardPool][_account];
	}

	function _dlpUpdateReward(address _account) private {
		address _dlpRewardPool = dlpRewardPool;
		address _miningIncentive = miningIncentive;

		// esLBR earned from Lybra ETH-LBR LP stake reward pool
        // !! @modify Code added by Eric 20231030
        (
        	uint256 dlpNormal, 
        	uint256 dlpRpt, 
        	uint256 boostReward, 
        	uint256 dlpEarned
        ) = earnedSinceLastUpdate(_dlpRewardPool);
		rewardPerTokenPaid[_dlpRewardPool] = dlpRpt;
		earnedPaid[_dlpRewardPool] = dlpEarned;

		uint256 toStaker;
		if (_miningIncentive != address(0)) {
			// esLBR earned from Lybra eUSD mining incentive
            // !! @modify Code added by Eric 20231030
            (
            	uint256 lsdNormal, 
            	uint256 lsdRpt, 
            	uint256 boostRewardFromMining, 
            	uint256 lsdEarned
            ) = earnedSinceLastUpdate(_miningIncentive);
			rewardPerTokenPaid[_miningIncentive] = lsdRpt;
			earnedPaid[_miningIncentive] = lsdEarned;

			uint256 toTreasury = lsdNormal * treasuryShare / 100;
			if (toTreasury > 0) userRewards[_miningIncentive][treasury] += toTreasury;
			// esLBR reward from mining incentive given to dlp stakers
			toStaker = lsdNormal * stakerShare / 100;
			// esLBR reward from mining incentive given to stETH suppliers
			uint256 toSupplier = lsdNormal - toTreasury - toStaker;

			rewardPerTokenStored[_miningIncentive] = _rewardPerToken(_miningIncentive, toSupplier);

			// !! @modify Code added by Eric 20231030
            boostReward += boostRewardFromMining;
		}

		rewardPerTokenStored[_dlpRewardPool] = _rewardPerToken(_dlpRewardPool, dlpNormal + toStaker);

		// !! @modify Code added by Eric 20231030
        // !! @modify Code moved by Eric 20231228
        pendingBoostReward += boostReward;

		if (_account == address(0)) return;

		userRewards[_dlpRewardPool][_account] = _earned(_account, _dlpRewardPool, 0);
		userRewardsPerTokenPaid[_dlpRewardPool][_account] = rewardPerTokenStored[_dlpRewardPool];
	}

	function _lsdUpdateReward(address _account) private {
		address _dlpRewardPool = dlpRewardPool;
		address _miningIncentive = miningIncentive;

		// esLBR earned from Lybra eUSD mining incentive
        // !! @modify Code added by Eric 20231030
        (
        	uint256 lsdNormal, 
        	uint256 lsdRpt, 
        	uint256 boostReward, 
        	uint256 lsdEarned
        ) = earnedSinceLastUpdate(_miningIncentive);
		rewardPerTokenPaid[_miningIncentive] = lsdRpt;
		earnedPaid[_miningIncentive] = lsdEarned;

		if (lsdNormal > 0) {
			uint256 toTreasury = lsdNormal * treasuryShare / 100;
			if (toTreasury > 0) userRewards[_miningIncentive][treasury] += toTreasury;
			// esLBR reward from mining incentive given to dlp stakers
			uint256 toStaker = lsdNormal * stakerShare / 100;
			// esLBR reward from mining incentive given to stETH suppliers
			uint256 toSupplier = lsdNormal - toTreasury - toStaker;

			rewardPerTokenStored[_dlpRewardPool] = _rewardPerToken(_dlpRewardPool, toStaker);
			rewardPerTokenStored[_miningIncentive] = _rewardPerToken(_miningIncentive, toSupplier);
		}

		address _eUSD = eUSD;
		uint256 eusdEarned = matchPool.claimRebase();
		if (eusdEarned > 0) {
			totalEUSD += eusdEarned;
			rewardPerTokenStored[_eUSD] = _rewardPerToken(_eUSD, eusdEarned);
		}

		// !! @modify Code added by Eric 20231030
        // !! @modify Code moved by Eric 20231228
        pendingBoostReward += boostReward;

		if (_account == address(0)) return;

		userRewards[_miningIncentive][_account] = _earned(_account, _miningIncentive, 0);
		userRewardsPerTokenPaid[_miningIncentive][_account] = rewardPerTokenStored[_miningIncentive];

		(uint256 borrowedAmount,,,) = matchPool.borrowed(address(matchPool.getMintPool()), _account);
		if (borrowedAmount == 0) userRewards[_eUSD][_account] = _earned(_account, _eUSD, 0);
			// Users who borrowed eUSD will not share rebase reward
		else userRewards[_eUSD][treasury] += (_earned(_account, _eUSD, 0) - userRewards[_eUSD][_account]);

		userRewardsPerTokenPaid[_eUSD][_account] = rewardPerTokenStored[_eUSD];
	}
}
