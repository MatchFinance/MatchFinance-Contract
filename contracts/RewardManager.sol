// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/LybraInterfaces.sol";
import "./interfaces/IMatchPool.sol";

interface IERC20Mintable {
	function mint(address _to, uint256 _amount) external;
}

error UnpaidInterest(uint256 unpaidAmount);

contract RewardManager is Ownable {
	IMatchPool public immutable matchPool;

	// reward pool => amount
	// 1. dlp reward pool (dlp + 20% mining incentive) 
	// 2. lsd reward pool (70% mining incentive)
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

	address public dlpRewardPool;
	address public lsdRewardPool;
	address public eUSD;
	// Receive eUSD rebase and esLBR from mining incentive;
	address public treasury;

	IERC20Mintable public mesLBR;

	// Mining reward share, out of 100
	uint128 treasuryShare = 10;
	uint128 stakerShare = 10;

	event RewardShareChanged(uint128 newTreasuryShare, uint128 newStakerShare);
	event DLPRewardClaimed(address account, uint256 rewardAmount);
	event LSDRewardClaimed(address account, uint256 rewardAmount);
	event eUSDRewardClaimed(address account, uint256 rewardAmount);

	constructor(address _matchPool) {
        matchPool = IMatchPool(_matchPool);
    }

	/**
	 * @notice Rewards earned by Match Pool since last update, get most updated value by directly calculating
	 */
	function earnedSinceLastUpdate(address _rewardPool) public view returns (uint256, uint256) {
		IRewardPool rewardPool = IRewardPool(_rewardPool);
		address _matchPool = address(matchPool);
		uint256 share;
		if (_rewardPool == dlpRewardPool) share = rewardPool.balanceOf(_matchPool);
		if (_rewardPool == lsdRewardPool) share = rewardPool.stakedOf(_matchPool);

		uint256 rpt = rewardPool.rewardPerToken();
		return (share * rewardPool.getBoost(_matchPool) * (rpt - rewardPerTokenPaid[_rewardPool]) / 1e38, rpt);
	}

	function rewardPerToken(address _rewardPool, uint256 _rewardAmount) public view returns (uint256) {
		uint256 rptStored = rewardPerTokenStored[_rewardPool];
		uint256 totalToken;
		if (_rewardPool == dlpRewardPool) totalToken = matchPool.totalStaked();
		if (_rewardPool == lsdRewardPool || _rewardPool == eUSD) totalToken = matchPool.totalSupplied();

		return totalToken > 0 ? rptStored + _rewardAmount * 1e18 / totalToken : rptStored;
	}

	function earned(address _account, address _rewardPool, uint256 _rewardAmount) public view returns (uint256) {
		uint256 share;
		if (_rewardPool == dlpRewardPool) share = matchPool.staked(_account);
		if (_rewardPool == lsdRewardPool || _rewardPool == eUSD) share = matchPool.supplied(_account);

		return share * (rewardPerToken(_rewardPool, _rewardAmount) - 
			userRewardsPerTokenPaid[_rewardPool][_account]) / 1e18 + userRewards[_rewardPool][_account];
	}

	function setRewardPools(address _dlp, address _lsd, address _eUSD) external onlyOwner {
		dlpRewardPool = _dlp;
		lsdRewardPool = _lsd;
		eUSD = _eUSD;
	}

	function setMesLBR(address _mesLBR) external onlyOwner {
		mesLBR = IERC20Mintable(_mesLBR);
	}

	function setMiningRewardShares(uint128 _treasuryShare, uint128 _stakerShare) external onlyOwner {
		treasuryShare = _treasuryShare;
		stakerShare = _stakerShare;

		emit RewardShareChanged(_treasuryShare, _stakerShare);
	}
	
	// Update rewards for dlp stakers, includes esLBR from dlp and eUSD
	function dlpUpdateReward(address _account) public {
		address _dlpRewardPool = dlpRewardPool;
		address _lsdRewardPool = lsdRewardPool;

		// esLBR earned from Lybra ETH-LBR LP stake reward pool
		(uint256 dlpEarned, uint256 dlpRpt) = earnedSinceLastUpdate(_dlpRewardPool);
		rewardPerTokenPaid[_dlpRewardPool] = dlpRpt;
		// esLBR earned from Lybra eUSD mining incentive
		(uint256 lsdEarned, uint256 lsdRpt) = earnedSinceLastUpdate(_lsdRewardPool);
		rewardPerTokenPaid[_lsdRewardPool] = lsdRpt;

		uint256 toTreasury = lsdEarned * treasuryShare / 100;
		userRewards[_lsdRewardPool][treasury] += toTreasury;
		// esLBR reward from mining incentive given to dlp stakers
		uint256 toStaker = lsdEarned * stakerShare / 100;
		// esLBR reward from mining incentive given to stETH suppliers
		uint256 toSupplier = lsdEarned - toTreasury - toStaker;

		rewardPerTokenStored[_dlpRewardPool] = rewardPerToken(_dlpRewardPool, dlpEarned + toStaker);
		rewardPerTokenStored[_lsdRewardPool] = rewardPerToken(_lsdRewardPool, toSupplier);

		if (_account == address(0)) return;

		userRewards[_dlpRewardPool][_account] = earned(_account, _dlpRewardPool, dlpEarned + toStaker);
		userRewardsPerTokenPaid[_dlpRewardPool][_account] = rewardPerTokenStored[_dlpRewardPool];
	}

	function lsdUpdateReward(address _account) public {
		address _dlpRewardPool = dlpRewardPool;
		address _lsdRewardPool = lsdRewardPool;
		address _eUSD = eUSD;

		uint256 eusdEarned = matchPool.claimRebase();
		totalEUSD += eusdEarned;

		// esLBR earned from Lybra eUSD mining incentive
		(uint256 lsdEarned, uint256 rpt) = earnedSinceLastUpdate(_lsdRewardPool);
		rewardPerTokenPaid[_lsdRewardPool] = rpt;

		uint256 toTreasury = lsdEarned * treasuryShare / 100;
		userRewards[_lsdRewardPool][treasury] += toTreasury;
		// esLBR reward from mining incentive given to dlp stakers
		uint256 toStaker = lsdEarned * stakerShare / 100;
		// esLBR reward from mining incentive given to stETH suppliers
		uint256 toSupplier = lsdEarned - toTreasury - toStaker;

		rewardPerTokenStored[_dlpRewardPool] = rewardPerToken(_dlpRewardPool, toStaker);
		rewardPerTokenStored[_lsdRewardPool] = rewardPerToken(_lsdRewardPool, toSupplier);
		rewardPerTokenStored[_eUSD] = rewardPerToken(_eUSD, eusdEarned);

		if (_account == address(0)) return;

		userRewards[_lsdRewardPool][_account] = earned(_account, _lsdRewardPool, toSupplier);
		userRewardsPerTokenPaid[_lsdRewardPool][_account] = rewardPerTokenStored[_lsdRewardPool];

		(uint256 borrowedAmount,,,) = matchPool.borrowed(_account);
		if (borrowedAmount == 0) userRewards[_eUSD][_account] = earned(_account, _eUSD, eusdEarned);
		// Users who borrowed eUSD will not share rebase reward
		else userRewards[_eUSD][treasury] += (earned(_account, _eUSD, eusdEarned) - userRewards[_eUSD][_account]);
		userRewardsPerTokenPaid[_eUSD][_account] = rewardPerTokenStored[_eUSD];
	}

	function getReward(address _rewardPool) public {
		// Cannot claim rewards if has not fully repaid eUSD interest
		// due to borrowing when above { globalBorrowRatioThreshold }
		(,, uint256 unpaidInterest,) = matchPool.borrowed(msg.sender);
		if (unpaidInterest > 0) revert UnpaidInterest(unpaidInterest);

		address _dlpRewardPool = dlpRewardPool;
		address _lsdRewardPool = lsdRewardPool;
		uint256 rewardAmount;

		if (_rewardPool == _dlpRewardPool) {
			dlpUpdateReward(msg.sender);

			rewardAmount = userRewards[_dlpRewardPool][msg.sender];
			if (rewardAmount > 0) {
				userRewards[_dlpRewardPool][msg.sender] = 0;
				mesLBR.mint(msg.sender, rewardAmount);
				emit DLPRewardClaimed(msg.sender, rewardAmount);
			}

			return;
		}

		if (_rewardPool == _lsdRewardPool) {
			lsdUpdateReward(msg.sender);

			rewardAmount = userRewards[_lsdRewardPool][msg.sender];
			if (rewardAmount > 0) {
				userRewards[_lsdRewardPool][msg.sender] = 0;
				mesLBR.mint(msg.sender, rewardAmount);
				emit LSDRewardClaimed(msg.sender, rewardAmount);
			}

			rewardAmount = userRewards[eUSD][msg.sender];
			if (rewardAmount > 0) {
				IERC20 _eUSD = IERC20(eUSD);
				// Get actual claim amount, including newly rebased eUSD in this contract
				uint256 actualAmount = _eUSD.balanceOf(address(this)) * userRewards[eUSD][msg.sender] / totalEUSD;
				userRewards[eUSD][msg.sender] = 0;
				totalEUSD -= rewardAmount;

				_eUSD.transfer(msg.sender, actualAmount);
				emit LSDRewardClaimed(msg.sender, rewardAmount);
			}

			return;
		}
	}

	function getAllRewards() external {
		getReward(dlpRewardPool);
		getReward(lsdRewardPool);
	}
}
