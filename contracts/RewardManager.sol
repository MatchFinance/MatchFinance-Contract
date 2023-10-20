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

error UnpaidInterest();
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

	event RewardShareChanged(uint128 newTreasuryShare, uint128 newStakerShare);
	event DLPRewardClaimed(address account, uint256 rewardAmount);
	event LSDRewardClaimed(address account, uint256 rewardAmount);
	event eUSDRewardClaimed(address account, uint256 rewardAmount);

	function initialize(address _matchPool) public initializer {
		__Ownable_init();

        matchPool = IMatchPool(_matchPool);
        setMiningRewardShares(0, 20);
    }

	/**
	 * @notice Rewards earned by Match Pool since last update, get most updated value by directly calculating
	 */
	function earnedSinceLastUpdate(address _rewardPool) public view returns (uint256, uint256) {
		IRewardPool rewardPool = IRewardPool(_rewardPool);
		address _matchPool = address(matchPool);
		uint256 share;
		if (_rewardPool == dlpRewardPool) share = rewardPool.balanceOf(_matchPool);
		else if (_rewardPool == miningIncentive) share = rewardPool.stakedOf(_matchPool);

		uint256 rpt = rewardPool.rewardPerToken();
		return (share * rewardPool.getBoost(_matchPool) * (rpt - rewardPerTokenPaid[_rewardPool]) / 1e38, rpt);
	}

	function rewardPerToken(address _rewardPool) public view returns (uint256) {
		(uint256 dlpEarned,) = earnedSinceLastUpdate(dlpRewardPool);
		(uint256 lsdEarned,) = earnedSinceLastUpdate(miningIncentive);
		uint256 rewardAmount;
		if (_rewardPool == dlpRewardPool) rewardAmount = dlpEarned + lsdEarned * stakerShare / 100;
		else if (_rewardPool == miningIncentive) rewardAmount = lsdEarned * (100 - stakerShare - treasuryShare) / 100;

		(uint256 rpt,) = _rewardPerToken(address(0), _rewardPool, rewardAmount);
		return rpt;
	}

	function earned(address _account, address _rewardPool) public view returns (uint256) {
		(uint256 dlpEarned,) = earnedSinceLastUpdate(dlpRewardPool);
		(uint256 lsdEarned,) = earnedSinceLastUpdate(miningIncentive);
		uint256 rewardAmount;
		if (_rewardPool == dlpRewardPool) rewardAmount = dlpEarned + lsdEarned * stakerShare / 100;
		else if (_rewardPool == miningIncentive) rewardAmount = lsdEarned * (100 - stakerShare - treasuryShare) / 100;

		return _earned(_account, _rewardPool, rewardAmount);
	}

	/**
	 * @notice Cannot get eUSD rebase reward if borrowed eUSD from any mint pool
	 */
	function hasBorrwedEUSD(address _account) public view returns (bool) {
		address[] memory mintPools = matchPool.getMintPools();

		for (uint256 i; i < mintPools.length; ) {
			if (matchPool.isRebase(mintPools[i])) {
				(uint256 borrowedAmount,,,) = matchPool.borrowed(mintPools[i], _account);
				if (borrowedAmount > 0) return true;
			}

			unchecked {
				++i;
			}
		}

		return false;
	}

	/**
	 * @notice Cannot claim rewards if has unpaid interest
	 */
	function hasUnpaidInterest(address _account) public view returns (bool) {
		address[] memory mintPools = matchPool.getMintPools();

		for (uint256 i; i < mintPools.length; ) {
			(,, uint256 unpaidInterest,) = matchPool.borrowed(mintPools[i], _account);
			if (unpaidInterest > 0) return true;

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
	            address mintPoolAddress = address(mintPools[i]);
	            if (matchPool.isRebase(mintPoolAddress) && matchPool.totalMinted(mintPoolAddress) > 0)
	                total += matchPool.totalSupplied(mintPoolAddress);

	            unchecked { ++i; }
	        }
		}
		else {
			for (uint256 i; i < mintPools.length; ) {
	            address mintPoolAddress = address(mintPools[i]);
	            if (matchPool.isRebase(mintPoolAddress) && matchPool.totalMinted(mintPoolAddress) > 0) {
	                total += matchPool.totalSupplied(mintPoolAddress);
	                individual += matchPool.supplied(mintPoolAddress, _account);
	            }

	            unchecked { ++i; }
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
	            address mintPoolAddress = mintPools[i];
	            if (matchPool.totalMinted(mintPoolAddress) > 0) total += matchPool.totalSupplied(mintPoolAddress);

	            unchecked { ++i; }
	        }
        }
        else {
        	for (uint256 i; i < mintPools.length; ) {
	            address mintPoolAddress = mintPools[i];
	            if (matchPool.totalMinted(mintPoolAddress) > 0) {
	                total += matchPool.totalSupplied(mintPoolAddress);
	                individual += matchPool.supplied(mintPoolAddress, _account);
	            }

	            unchecked { ++i; }
	        }
        }
    }

	function setDlpRewardPool(address _dlp) external onlyOwner {
		dlpRewardPool = _dlp;
	}

	function setMiningRewardPools(address _mining, address _eUSD) external onlyOwner {
		miningIncentive = _mining;
		eUSD = _eUSD;
	}

	function setMiningRewardShares(uint128 _treasuryShare, uint128 _stakerShare) public onlyOwner {
		treasuryShare = _treasuryShare;
		stakerShare = _stakerShare;

		emit RewardShareChanged(_treasuryShare, _stakerShare);
	}

	function setTreasury(address _treasury) external onlyOwner {
		treasury = _treasury;
	}

	function setMesLBR(address _mesLBR) external onlyOwner {
		mesLBR = IERC20Mintable(_mesLBR);
	}
	
	// Update rewards for dlp stakers, includes esLBR from dlp and eUSD
	function dlpUpdateReward(address _account) public {
		address _dlpRewardPool = dlpRewardPool;
		address _miningIncentive = miningIncentive;

		// esLBR earned from Lybra ETH-LBR LP stake reward pool
		(uint256 dlpEarned, uint256 dlpRpt) = earnedSinceLastUpdate(_dlpRewardPool);
		rewardPerTokenPaid[_dlpRewardPool] = dlpRpt;

		uint256 toStaker;
		uint256 rpt;
		if (_miningIncentive != address(0)) {
			// esLBR earned from Lybra eUSD mining incentive
			(uint256 lsdEarned, uint256 lsdRpt) = earnedSinceLastUpdate(_miningIncentive);
			rewardPerTokenPaid[_miningIncentive] = lsdRpt;

			uint256 toTreasury = lsdEarned * treasuryShare / 100;
			if (toTreasury > 0) userRewards[_miningIncentive][treasury] += toTreasury;
			// esLBR reward from mining incentive given to dlp stakers
			toStaker = lsdEarned * stakerShare / 100;
			// esLBR reward from mining incentive given to stETH suppliers
			uint256 toSupplier = lsdEarned - toTreasury - toStaker;

			(rpt,) = _rewardPerToken(address(0), _miningIncentive, toSupplier);
			rewardPerTokenStored[_miningIncentive] = rpt;
		}

		(rpt,) = _rewardPerToken(address(0), _dlpRewardPool, dlpEarned + toStaker);
		rewardPerTokenStored[_dlpRewardPool] = rpt;

		if (_account == address(0)) return;

		userRewards[_dlpRewardPool][_account] = _earned(_account, _dlpRewardPool, dlpEarned + toStaker);
		userRewardsPerTokenPaid[_dlpRewardPool][_account] = rewardPerTokenStored[_dlpRewardPool];
	}

	function lsdUpdateReward(address _account, bool _isRebase) public {
		address _dlpRewardPool = dlpRewardPool;
		address _miningIncentive = miningIncentive;

		// esLBR earned from Lybra eUSD mining incentive
		(uint256 lsdEarned, uint256 lsdRpt) = earnedSinceLastUpdate(_miningIncentive);
		rewardPerTokenPaid[_miningIncentive] = lsdRpt;

		uint256 toSupplier;
		uint256 rpt;
		if (lsdEarned > 0) {
			uint256 toTreasury = lsdEarned * treasuryShare / 100;
			if (toTreasury > 0) userRewards[_miningIncentive][treasury] += toTreasury;
			// esLBR reward from mining incentive given to dlp stakers
			uint256 toStaker = lsdEarned * stakerShare / 100;
			// esLBR reward from mining incentive given to stETH suppliers
			toSupplier = lsdEarned - toTreasury - toStaker;

			(rpt,) = _rewardPerToken(address(0), _dlpRewardPool, toStaker);
			rewardPerTokenStored[_dlpRewardPool] = rpt;
			(rpt,) = _rewardPerToken(address(0), _miningIncentive, toSupplier);
			rewardPerTokenStored[_miningIncentive] = rpt;
		}

		uint256 eusdEarned;
		address _eUSD;
		if (_isRebase) {
			_eUSD = eUSD;
			eusdEarned = matchPool.claimRebase();
			if (eusdEarned > 0) {
				totalEUSD += eusdEarned;
				(rpt,) = _rewardPerToken(address(0), _eUSD, eusdEarned);
				rewardPerTokenStored[_eUSD] = rpt;
			}
		}

		if (_account == address(0)) return;

		userRewards[_miningIncentive][_account] = _earned(_account, _miningIncentive, toSupplier);
		userRewardsPerTokenPaid[_miningIncentive][_account] = rewardPerTokenStored[_miningIncentive];

		if (_isRebase) {
			if (!hasBorrwedEUSD(_account)) userRewards[_eUSD][_account] = _earned(_account, _eUSD, eusdEarned);
			// Users who borrowed eUSD will not share rebase reward
			else userRewards[_eUSD][treasury] += (_earned(_account, _eUSD, eusdEarned) - userRewards[_eUSD][_account]);
			userRewardsPerTokenPaid[_eUSD][_account] = rewardPerTokenStored[_eUSD];
		}
	}

	function getReward(address _rewardPool) public {
		if (address(mesLBR) == address(0)) revert RewardNotOpen();

		// Cannot claim rewards if has not fully repaid eUSD/peUSD interest 
		// due to borrowing when above { globalBorrowRatioThreshold }
		if (hasUnpaidInterest(msg.sender)) revert UnpaidInterest();

		address _dlpRewardPool = dlpRewardPool;
		address _miningIncentive = miningIncentive;
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

		if (_rewardPool == _miningIncentive) {
			lsdUpdateReward(msg.sender, true);

			rewardAmount = userRewards[_miningIncentive][msg.sender];
			if (rewardAmount > 0) {
				userRewards[_miningIncentive][msg.sender] = 0;
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
				emit eUSDRewardClaimed(msg.sender, rewardAmount);
			}

			return;
		}
	}

	function getAllRewards() external {
		getReward(dlpRewardPool);
		getReward(miningIncentive);
	}

	function _rewardPerToken(address _account, address _rewardPool, uint256 _rewardAmount) private view returns (uint256, uint256) {
		uint256 totalToken;
		uint256 share;
		if (_rewardPool == dlpRewardPool) totalToken = matchPool.totalStaked();
		else if (_rewardPool == miningIncentive) (totalToken, share) = getEarningSupplies(_account);
		else if (_rewardPool == eUSD) (totalToken, share) = getRebaseSupplies(_account);

		uint256 rptStored = rewardPerTokenStored[_rewardPool];
		return (totalToken > 0 ? rptStored + _rewardAmount * 1e18 / totalToken : rptStored, share);
	}

	function _earned(address _account, address _rewardPool, uint256 _rewardAmount) private view returns (uint256) {
		(uint256 rpt, uint256 share) = _rewardPerToken(_account, _rewardPool, _rewardAmount);
		// _rewardPerToken() for dlpRewardPool returns 0 as share
		if (_rewardPool == dlpRewardPool) share = matchPool.staked(_account);

		return share * (rpt - userRewardsPerTokenPaid[_rewardPool][_account]) / 1e18 + userRewards[_rewardPool][_account];
	}
}
