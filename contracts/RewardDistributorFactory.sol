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

    // Reward token => Receiver => Distributor
    mapping(address rewardToken => mapping(address receiver => address distributor)) public distributors;

    mapping(address receiver => bool isValid) public isValidReceiver;

    // ---------------------------------------------------------------------------------------- //
    // *************************************** Events ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    event NewDistributorDeployed(address rewardToken, address receiver, address distributor);

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Initialize *************************************** //
    // ---------------------------------------------------------------------------------------- //

    function initialize() public initializer {
        __Ownable_init();
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

        isValidReceiver[_receiver] = true;

        emit NewDistributorDeployed(_rewardToken, _receiver, address(newDistributor));
    }

    function distribute(address _rewardToken) external returns (uint256) {
        // Only called by distributors
        address receiver = msg.sender;
        require(isValidReceiver[receiver], "Invalid caller to distribute");

        address distributorAddress = distributors[_rewardToken][receiver];
        require(distributorAddress != address(0), "Distributor not exist");

        RewardDistributorV2 distributor = RewardDistributorV2(distributorAddress);
        return distributor.distribute();
    }

    function ownerDistribute(address _rewardToken, address _receiver) external onlyOwner returns (uint256) {
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
