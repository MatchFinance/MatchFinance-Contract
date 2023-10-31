// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IStakingPool {
    function updateReward(uint256 esLBRReward, uint256 protocolRevenue) external;
}
