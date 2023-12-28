// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.19;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IRewardReceiver {
    function updateReward() external;
}

/**
 * @notice Reward Distributor
 *         for mToken staking / vlMatch staking
 *
 * @dev
 *      Reward token type: mesLBR and peUSD(or USDC)
 *      1) mesLBR comes from MatchPool's esLBR balance
 *      2) peUSD comes from MatchPool holding esLBR
 *
 *      Workflow for reward distribution:
 *      1) Owner calls the "boostReward" function inside MatchPool contract
 *      2) Every time when users stake dLP or LSD, the updating function will get boost reward amount
 *      3) Every time when users call "getReward" in RewardManager contract, it will distribute
 *         the boosting part and protocol revenue part to the correspongding distributor contract
 *         (different reward token and receiver has different distributors)
 *      4) MTokenStaking & VLMatchStaking contract needs to call "distriubte" to distribute the reward
 *         (maybe more receivers in the future)
 *
 *      For multiple reward tokens to be distributed to mToken stakers, we need to
 *      deploy multiple RewardDistributor contracts.
 *
 *      esLBR: Lybra -> MatchPool -> RewardDistributor -> MTokenStaking
 *                                                     -> VLMatchStaking
 *      peUSD: Lybra -> MatchPool -> RewardDistributor -> MTokenStaking
 *      altStablecoin: Lybra -> MatchPool -> RewardDistributor -> MTokenStaking
 *
 *      ! 2023-12-28 Note for deployment
 *      ! We will deploy four RewardDistributors:
 *      ! 1) distributing mesLBR to mesLBR staking
 *      ! 2) distributing peUSD to mesLBR staking
 *      ! 3) distributing altStablecoin to mesLBR staking
 *      ! 4) distributing mesLBR to vlMatch staking
 */

contract RewardDistributor is OwnableUpgradeable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Constants **************************************** //
    // ---------------------------------------------------------------------------------------- //

    uint256 public constant SCALE = 1e18;

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Variables **************************************** //
    // ---------------------------------------------------------------------------------------- //

    // Reward token address
    // Each reward token has a distributor
    address public rewardToken;

    // Manager is the only caller to distribute the reward
    address public manager;

    // Receiver is the only one who can receive the reward
    address public receiver;

    // Reward token amount per second
    // Manually set by owner
    // e.g.
    // Set to 100esLBR/s ------------------- Set to 200esLBR/s ------------------>>
    //                       (speed 100)                          (speed 200)
    //
    uint256 public speed;

    // Timestamp of last "distribution"
    // Distribution means the receiver calls "distribute" function to take the reward
    uint256 public lastDistributionTime;

    // ---------------------------------------------------------------------------------------- //
    // *************************************** Events ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    event LastDistributionTimeUpdated();
    event RewardSpeedUpdated(uint256 newSpeed);
    event RewardDistributed(uint256 amount);

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Initialize *************************************** //
    // ---------------------------------------------------------------------------------------- //

    function initialize(address _rewardToken, address _receiver, address _manager) public initializer {
        __Ownable_init();

        rewardToken = _rewardToken;
        receiver = _receiver;
        manager = _manager;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ View Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Get pending reward
     *         This is the reward amount pending to be distributed to receiver contract
     *         Only depends on the speed and time passed
     */
    function pendingReward() public view returns (uint256) {
        if (block.timestamp == lastDistributionTime) return 0;

        return (block.timestamp - lastDistributionTime) * speed;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Set Functions ************************************* //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Change the reward distribution speed
     */
    function setRewardSpeed(uint256 _newSpeed) external onlyOwner {
        // If this is the first time to set speed, will start this distributor
        // If already started, need to first distribute rewards out before changing speed
        if (lastDistributionTime != 0) {
            // When changing reward speed, will first calculate and update reward for the receiver
            // Inside this call to receiver contract, it will call back to this contract's "distribute" function
            // and update the last distribution time.
            // This --> call receiver "updateReward" --> call rewardManager --> call this "distribute"
            IRewardReceiver(receiver).updateReward();
        }

        lastDistributionTime = block.timestamp;
        speed = _newSpeed;

        emit RewardSpeedUpdated(_newSpeed);
        emit LastDistributionTimeUpdated();
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Main Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    function distribute() external returns (uint256) {
        require(msg.sender == manager, "Only manager can distribute");

        // The amount to distribute is only timePassed * speed
        uint256 amountToDistribute = pendingReward();
        if (amountToDistribute == 0) return 0;

        lastDistributionTime = block.timestamp;

        // Distribute all reward token if balance is not enough
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (balance < amountToDistribute) amountToDistribute = balance;

        IERC20(rewardToken).safeTransfer(receiver, amountToDistribute);

        emit RewardDistributed(amountToDistribute);
        emit LastDistributionTimeUpdated();

        // Will always return the actual amount the receiver received
        return amountToDistribute;
    }

    function emergencyWithdraw(address _token, address _to, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(_to, _amount);
    }
}
