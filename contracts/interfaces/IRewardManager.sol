// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IRewardManager {
    function dlpUpdateReward(address _account) external;

    function lsdUpdateReward(address _account, bool _isRebase) external;

    function treasury() external view returns (address);

    // !! @modify Eric Lee 20231207
    function distributeRewardFromDistributor(address _rewardToken) external returns (uint256);

    function pendingRewardInDistributor(address _rewardToken, address _receiver) external view returns (uint256);
}
