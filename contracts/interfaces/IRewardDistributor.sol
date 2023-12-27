// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// !! @modify Eric 20231207
interface IRewardDistributor {
    function pendingReward() external view returns (uint256);

    function distribute() external returns (uint256);
}
