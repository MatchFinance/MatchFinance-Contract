// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMatchPool {
	// Total amount of ETH-LBR staked
	function totalStaked() external view returns (uint256);
	function staked(address _user) external view returns (uint256);
	// Total amount of stETH deposited to contract
	function totalSupplied() external view returns (uint256);
	function supplied(address _user) external view returns (uint256);
	function totalMinted() external view returns (uint256);
	function claimRebase() external returns (uint256);
	function borrowed(address _account) external view returns (uint256, uint256, uint256, uint256);
}

interface IRewardPool {
	function stakedOf(address user) external view returns (uint256);
	function balanceOf(address user) external view returns (uint256);
	function getBoost(address _account) external view returns (uint256);
	function rewardPerToken() external view returns (uint256);
}

interface IERC20Mintable {
	function mint(address _to, uint256 _amount) external;
}

error UnpaidInterest(uint256 unpaidAmount);

contract RewardManager is Ownable {
	IMatchPool public immutable matchPool;

	// dlp reward pool (dlp + 20% mining incentive) / lsd reward pool (70% mining incentive) / eUSD (rebase)
	// reward pool => amount
	mapping(address => uint256) public rewardPerTokenStored;
	// Maintain own version of token paid for calculating most updated reward amount
	mapping(address => uint256) public rewardPerTokenPaid;
	// reward pool => account => amount
	mapping(address => mapping(address => uint256)) public userRewardsPerTokenPaid;
	mapping(address => mapping(address => uint256)) public userRewards;

	address public dlpRewardPool;
	address public lsdRewardPool;
	address public eUSD;
	// Amount of esLBR reward from eUSD that goes to treasury
	uint256 public toTreasury;

	IERC20Mintable public mesLBR;

	constructor(address _matchPool) {
        matchPool = IMatchPool(_matchPool);
    }

	// Rewards earned by Match Pool since last update
	// Get most updated value by directly calculating
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

	function setRewardPools(address _dlp, address _lsd) external onlyOwner {
		dlpRewardPool = _dlp;
		lsdRewardPool = _lsd;
	}

	function setMesLBR(address _mesLBR) external onlyOwner {
		mesLBR = IERC20Mintable(_mesLBR);
	}
	
	// Update rewards for dlp stakers, includes esLBR from dlp and eUSD
	function dlpUpdateReward(address _account) public {
		// esLBR earned from Lybra ETH-LBR LP stake reward pool
		(uint256 dlpEarned, uint256 dlpRpt) = earnedSinceLastUpdate(dlpRewardPool);
		rewardPerTokenPaid[dlpRewardPool] = dlpRpt;
		// esLBR earned from Lybra eUSD mining incentive
		(uint256 lsdEarned, uint256 lsdRpt) = earnedSinceLastUpdate(lsdRewardPool);
		rewardPerTokenPaid[lsdRewardPool] = lsdRpt;

		toTreasury += lsdEarned * 10 / 100;
		// esLBR reward from mining incentive given to dlp stakers
		uint256 toStaker = lsdEarned * 20 / 100;
		// esLBR reward from mining incentive given to stETH suppliers
		uint256 toSupplier = lsdEarned - toTreasury - toStaker;

		rewardPerTokenStored[dlpRewardPool] = rewardPerToken(dlpRewardPool, dlpEarned + toStaker);
		rewardPerTokenStored[lsdRewardPool] = rewardPerToken(lsdRewardPool, toSupplier);

		if (_account == address(0)) return;

		userRewards[dlpRewardPool][_account] = earned(_account, dlpRewardPool, dlpEarned + toStaker);
		userRewardsPerTokenPaid[dlpRewardPool][_account] = rewardPerTokenStored[dlpRewardPool];
	}

	function lsdUpdateReward(address _account) public {
		uint256 eusdEarned = matchPool.claimRebase();
		// esLBR earned from Lybra eUSD mining incentive
		(uint256 lsdEarned, uint256 rpt) = earnedSinceLastUpdate(lsdRewardPool);
		rewardPerTokenPaid[lsdRewardPool] = rpt;

		toTreasury += lsdEarned * 10 / 100;
		// esLBR reward from mining incentive given to dlp stakers
		uint256 toStaker = lsdEarned * 20 / 100;
		// esLBR reward from mining incentive given to stETH suppliers
		uint256 toSupplier = lsdEarned - toTreasury - toStaker;

		rewardPerTokenStored[dlpRewardPool] = rewardPerToken(dlpRewardPool, toStaker);
		rewardPerTokenStored[lsdRewardPool] = rewardPerToken(lsdRewardPool, toSupplier);
		// Encourage borrowing eUSD? Rebase reward from borrowed eUSD
		rewardPerTokenStored[eUSD] = rewardPerToken(eUSD, eusdEarned);

		if (_account == address(0)) return;

		userRewards[lsdRewardPool][_account] = earned(_account, lsdRewardPool, toSupplier);
		userRewardsPerTokenPaid[lsdRewardPool][_account] = rewardPerTokenStored[lsdRewardPool];
		userRewards[eUSD][_account] = earned(_account, eUSD, eusdEarned);
		userRewardsPerTokenPaid[eUSD][_account] = rewardPerTokenStored[eUSD];
	}

	function getReward(address _rewardPool) public {
		// Does not allow claiming rewards if has not fully repaid eUSD interest
		// due to borrowing when above { globalBorrowRatioThreshold }
		(,, uint256 unpaidInterest,) = matchPool.borrowed(msg.sender);
		if (unpaidInterest > 0) revert UnpaidInterest(unpaidInterest);

		uint256 rewardAmount;

		if (_rewardPool == dlpRewardPool) {
			dlpUpdateReward(msg.sender);

			rewardAmount = userRewards[dlpRewardPool][msg.sender];
			if (rewardAmount > 0) {
				userRewards[dlpRewardPool][msg.sender] = 0;
				mesLBR.mint(msg.sender, rewardAmount);

			}

			return;
		}

		if (_rewardPool == lsdRewardPool) {
			lsdUpdateReward(msg.sender);

			rewardAmount = userRewards[lsdRewardPool][msg.sender];
			if (rewardAmount > 0) {
				userRewards[lsdRewardPool][msg.sender] = 0;
				mesLBR.mint(msg.sender, rewardAmount);
			}

			rewardAmount = userRewards[eUSD][msg.sender];
			if (rewardAmount > 0) {
				userRewards[eUSD][msg.sender] = 0;
				IERC20(eUSD).transfer(msg.sender, rewardAmount);
			}

			return;
		}
	}

	function getAllRewards() external {
		getReward(dlpRewardPool);
		getReward(lsdRewardPool);
	}
}
