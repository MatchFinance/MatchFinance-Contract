// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MTokenStaking (staking mesLBR on Match Finance)
 * @author Eric Lee
 *
 * @notice
 *         Reward manager records the "extra boost reward" for each user
 *         Every time user stake/unstake, the reward manager will update the reward
 */

contract MTokenStaking is OwnableUpgradeable {
    uint256 public constant SCALE = 1e18;

    IERC20 public mToken;
    IERC20 public esLBR;
    // TODO: maybe have other stablecoin rewards
    IERC20 public peUSD;

    address public rewardManager;

    // total esLBR and USDC to be distributed
    uint256 public totalBoostReward;
    uint256 public totalProtocolRevenue;

    uint256 public accBoostRewardPerMToken;
    uint256 public accProtocolRevenuePerMToken;

    uint256 public totalStaked;

    struct UserInfo {
        uint256 stakedAmount;
        uint256 boostRewardDebt;
        uint256 protocolRevenueDebt;
    }
    mapping(address user => UserInfo info) public users;

    event RewardUpdated(uint256 boostReward, uint256 protocolRevenue);
    event Stake(address indexed user, uint256 amount, uint256 boostReward, uint256 protocolRevenue);
    event Unstake(address indexed user, uint256 amount, uint256 boostReward, uint256 protocolRevenue);

    error InsufficientStakedAmount();
    error ZeroAmount();
    error NotRewardManager();

    function initialize() external initializer {
        __Ownable_init();
    }

    modifier onlyRewardManager() {
        if (msg.sender != rewardManager) revert NotRewardManager();
        _;
    }

    function setRewardManager(address _rewardManager) external onlyOwner {
        rewardManager = _rewardManager;
    }   

    function stake(uint256 _amount) external {
        _stake(_amount, msg.sender);
    }

    function unstake(uint256 _amount) external {
        _unstake(_amount, msg.sender);
    }

    function delegateStake(address _to, uint256 _amount) external onlyRewardManager {
        _stake(_amount, _to);
    }

    function delegateUnstake(address _to, uint256 _amount) external onlyRewardManager {
        _unstake(_amount, _to);
    }

    function compound() external {
        UserInfo storage user = users[msg.sender];

        uint256 pendingBoostReward = (user.stakedAmount * accBoostRewardPerMToken) / SCALE - user.boostRewardDebt;
        uint256 pendingProtocolRevenue = (user.stakedAmount * accProtocolRevenuePerMToken) /
            SCALE -
            user.protocolRevenueDebt;

        mToken.transfer(msg.sender, pendingBoostReward);
        peUSD.transfer(msg.sender, pendingProtocolRevenue);

        _stake(pendingBoostReward, msg.sender);
    }

    function _stake(uint256 _amount, address _user) internal {
        if (_amount == 0) revert ZeroAmount();

        mToken.transferFrom(_user, address(this), _amount);

        UserInfo storage user = users[_user];

        uint256 pendingBoostReward;
        uint256 pendingProtocolRevenue;

        if (user.stakedAmount > 0) {
            pendingBoostReward = (user.stakedAmount * accBoostRewardPerMToken) / SCALE - user.boostRewardDebt;

            pendingProtocolRevenue =
                (user.stakedAmount * accProtocolRevenuePerMToken) /
                SCALE -
                user.protocolRevenueDebt;

            mToken.transfer(_user, pendingBoostReward);
            peUSD.transfer(_user, pendingProtocolRevenue);
        }

        user.stakedAmount += _amount;
        totalStaked += _amount;

        updateUserDebt(_user);

        emit Stake(_user, _amount, pendingBoostReward, pendingProtocolRevenue);
    }

    function _unstake(uint256 _amount, address _user) internal {
        UserInfo storage user = users[_user];

        if (user.stakedAmount < _amount) revert InsufficientStakedAmount();

        uint256 pendingBoostReward = (user.stakedAmount * accBoostRewardPerMToken) / SCALE - user.boostRewardDebt;
        uint256 pendingProtocolRevenue = (user.stakedAmount * accProtocolRevenuePerMToken) /
            SCALE -
            user.protocolRevenueDebt;

        user.stakedAmount -= _amount;
        totalStaked -= _amount;

        mToken.transfer(_user, pendingBoostReward + _amount);
        peUSD.transfer(_user, pendingProtocolRevenue);

        updateUserDebt(_user);

        emit Unstake(_user, _amount, pendingBoostReward, pendingProtocolRevenue);
    }

    function harvest() external {
        UserInfo storage user = users[msg.sender];

        uint256 pendingBoostReward = (user.stakedAmount * accBoostRewardPerMToken) / SCALE - user.boostRewardDebt;
        uint256 pendingProtocolRevenue = (user.stakedAmount * accProtocolRevenuePerMToken) /
            SCALE -
            user.protocolRevenueDebt;

        mToken.transfer(msg.sender, pendingBoostReward);
        peUSD.transfer(msg.sender, pendingProtocolRevenue);

        updateUserDebt(msg.sender);
    }

    // New reward comes into the pool
    // Only triggered by the reward manager
    function updateReward(uint256 _boostReward, uint256 _protocolRevenue) external onlyRewardManager {
        totalBoostReward += _boostReward;
        totalProtocolRevenue += _protocolRevenue;

        if (totalStaked != 0) {
            accBoostRewardPerMToken = (totalBoostReward * SCALE) / totalStaked;
            accProtocolRevenuePerMToken = (totalProtocolRevenue * SCALE) / totalStaked;
        }

        emit RewardUpdated(_boostReward, _protocolRevenue);
    }

    function updateUserDebt(address _user) internal {
        users[_user].boostRewardDebt = (users[_user].stakedAmount * accBoostRewardPerMToken) / SCALE;
        users[_user].protocolRevenueDebt = (users[_user].stakedAmount * accProtocolRevenuePerMToken) / SCALE;
    }
}
