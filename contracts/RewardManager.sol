// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IMatchPool {
	// Total amount of ETH-LBR staked
	function totalStaked() external view returns (uint256);
	function staked(address _user) external view returns (uint256);
	// Total amount of stETH deposited to contract
	function totalSupplied() external view returns (uint256);
	function supplied(address _user) external view returns (uint256);
}

interface IRewardPool {
	// Get rewards earned by Match Pool
	function earned(address _account) external view returns (uint256);
	function rewards(address _account) external view returns (uint256);
}

contract RewardManager is Ownable {
	IMatchPool public immutable matchPool;

	struct Reward {
		address rewardContract;
		uint256 rewardPerTokenStored;
		mapping(address => uint256) userRewardsPerTokenPaid;
		mapping(address => uint256) userRewards;
	}

	// Users may get different rewards by staking the same token
	// Staking token => reward token => Reward info
	mapping(address => mapping(address => Reward)) public rewards;

	constructor(address _matchPool) {
		matchPool = IMatchPool(_matchPool);
	}

	// Rewards earned by Match Pool since last update
	function earnedSinceLastUpdate(address _rewardContract) public view returns (uint256) {
		IRewardPool rewardPool = IRewardPool(_rewardContract);
		return rewardPool.earned(address(matchPool)) - rewardPool.rewards(address(matchPool));
	}

	// Amount of reward per dLP token staked from last updated time to now
	function dlpRewardPerToken() public view returns (uint256) {
		address dlpRewardPool;
		return rewardPerTokenStored + earnedSinceLastUpdate(dlpRewardPool) / matchPool.totalStaked();
	} 

	// Total amount earned by staking dLP
	function getDlpEarning(address _account) public view returns (uint256) {
		return matchPool.staked(_account) * (dlpRewardPerToken - userRewardPerTokenPaid[_account]) / 1e18 + userRewards[_account];
	}

	function addRewardSource(address _stakingToken, address _rewardToken, address) external onlyOwner {
		Reward storage reward = Reward({ rewardPerTokenStored: 0 });
		rewards[_stakingToken][_rewardToken] = reward;
	}
	
	function updateDlpReward(address _account) public {
		userRewards[_account] = getDlpEarning(_account);
        userRewardPerTokenPaid[_account] = dlpRewardPerToken();
	}
}