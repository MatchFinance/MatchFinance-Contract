// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IStakingPool {
    function updateReward() external;
    function delegateStake(address _to, uint256 _amount) external;
}
