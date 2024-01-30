// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IRewardDistributorFactory {
    function pendingReward(address rewardToken, address receiver) external view returns (uint256);

    function distribute(address rewardToken) external returns (uint256);

    function distributors(address rewardToken, address receiver) external view returns (address);
}