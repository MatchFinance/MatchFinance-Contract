// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.19;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { RewardDistributorV2 } from "./RewardDistributorV2.sol";

interface IRewardReceiver {
    function updateReward() external;
}

/**
 * @title Reward Distributor (distributing rewards on Match Finance)
 * @author Eric Lee (ylikp.ust@gmail.com)
 *
 * @notice Distribute reward for mToken staking / vlMatch staking
 *
 * @dev
 *
 */

contract RewardDistributorFactory is OwnableUpgradeable {
    // ---------------------------------------------------------------------------------------- //
    // ************************************* Variables **************************************** //
    // ---------------------------------------------------------------------------------------- //

    address public manager;

    // Reward token => Receiver => Distributor
    mapping(address rewardToken => mapping(address receiver => address distributor)) public distributors;

    // ---------------------------------------------------------------------------------------- //
    // *************************************** Events ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    event NewDistributorDeployed(address rewardToken, address receiver, address distributor);

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Initialize *************************************** //
    // ---------------------------------------------------------------------------------------- //

    function initialize(address _manager) public initializer {
        __Ownable_init();

        manager = _manager;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Modifiers **************************************** //
    // ---------------------------------------------------------------------------------------- //

    modifier onlyManager() {
        require(msg.sender == manager, "Only manager can call");
        _;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ View Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Get pending reward from a distributor contract
     */
    function pendingReward(address _rewardToken, address _receiver) public view returns (uint256) {
        RewardDistributorV2 distributor = RewardDistributorV2(distributors[_rewardToken][_receiver]);
        return distributor.pendingReward();
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Set Functions ************************************* //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Change the reward distribution speed
     */
    function setRewardSpeed(address _rewardToken, address _receiver, uint256 _newSpeed) external onlyOwner {
        RewardDistributorV2 distributor = RewardDistributorV2(distributors[_rewardToken][_receiver]);
        distributor.setRewardSpeed(_newSpeed);
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Main Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    function createDistributor(address _rewardToken, address _receiver) external onlyOwner {
        require(distributors[_rewardToken][_receiver] == address(0), "Distributor already exist");

        RewardDistributorV2 newDistributor = new RewardDistributorV2(_rewardToken, _receiver);

        distributors[_rewardToken][_receiver] = address(newDistributor);

        emit NewDistributorDeployed(_rewardToken, _receiver, address(newDistributor));
    }

    function distribute(address _rewardToken, address _receiver) external onlyManager returns (uint256) {
        address distributorAddress = distributors[_rewardToken][_receiver];
        require(distributorAddress != address(0), "Distributor not exist");

        RewardDistributorV2 distributor = RewardDistributorV2(distributorAddress);
        return distributor.distribute();
    }

    function emergencyWithdraw(
        address _rewardToken,
        address _receiver,
        address _token,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        address distributorAddress = distributors[_rewardToken][_receiver];
        require(distributorAddress != address(0), "Distributor not exist");

        RewardDistributorV2 distributor = RewardDistributorV2(distributorAddress);
        distributor.emergencyWithdraw(_token, _to, _amount);
    }
}
