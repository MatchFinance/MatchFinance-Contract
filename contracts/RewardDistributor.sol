// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.19;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IRewardReceiver {
    function updateReward() external;
}

/**
 * @notice Reward Distributor for mToken staking
 *
 * @dev
 *      Reward token type: mesLBR and peUSD(or USDC)
 *      1) mesLBR comes from MatchPool's esLBR balance
 *      2) peUSD comes from MatchPool holding esLBR
 *
 *      Workflow for reward distribution:
 *      1) Reward manager calls "boostReward" to get boosting reward from Lybra (extra esLBR)
 *      2) Every time MatchPool contract claims esLBR & peUSD from Lybra, it will
 *         distribute the boosting part and protocol revenue part to this contract
 *      3) MTokenStaking contract needs to call "distriubte" to distribute the reward
 *
 *      For multiple reward tokens to be distributed to mToken stakers, we need to
 *      deploy multiple RewardDistributor contracts.
 *
 *      esLBR: Lybra -> MatchPool -> RewardDistributor -> MTokenStaking
 *      peUSD: Lybra -> MatchPool -> RewardDistributor -> MTokenStaking
 */

contract RewardDistributor is OwnableUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant SCALE = 1e18;

    // Reward token address
    address public rewardToken;

    uint256 public tokensPerInterval;

    uint256 public lastDistributionTime;

    address public rewardManager;

    address public rewardReceiver;

    event LastDistributionTimeUpdated(uint256 lastDistributionTime);
    event RewardSpeedUpdated(uint256 tokensPerInterval);
    event RewardDistributed(uint256 amount);

    function initialize(address _receiver, address _manager) public initializer {
        __Ownable_init();

        rewardReceiver = _receiver;
        rewardManager = _manager;
    }

    function pendingReward() public view returns (uint256) {
        if (block.timestamp == lastDistributionTime) return 0;

        return (block.timestamp - lastDistributionTime) * tokensPerInterval;
    }

    function setRewardReceiver(address _receiver) external onlyOwner {
        rewardReceiver = _receiver;
    }

    function setRewardManager(address _manager) external onlyOwner {
        rewardManager = _manager;
    }

    function updateLastDistributionTime() external onlyOwner {
        lastDistributionTime = block.timestamp;

        emit LastDistributionTimeUpdated(lastDistributionTime);
    }

    function setTokensPerInterval(uint256 _tokensPerInterval) external onlyOwner {
        require(lastDistributionTime > 0, "Not started");

        IRewardReceiver(rewardReceiver).updateReward();

        tokensPerInterval = _tokensPerInterval;

        emit RewardSpeedUpdated(_tokensPerInterval);
    }

    function distribute() external returns (uint256) {
        require(msg.sender == rewardManager, "Only reward manager can distribute");

        uint256 amountToDistribute = pendingReward();
        if (amountToDistribute == 0) return 0;

        lastDistributionTime = block.timestamp;

        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (balance < amountToDistribute) amountToDistribute = balance;

        IERC20(rewardToken).safeTransfer(rewardReceiver, amountToDistribute);

        emit RewardDistributed(amountToDistribute);

        return amountToDistribute;
    }

    function emergencyWithdraw(address _token, address _to, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(_to, _amount);
    }
}
