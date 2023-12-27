// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IRewardCenter {
    function newOutgoingRewards(uint256 boostReward, uint256 treasuryReward, uint256 protocolRevenue) external;
}
