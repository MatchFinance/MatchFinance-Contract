// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRewardManager } from "../interfaces/IRewardManager.sol";

/**
 * @title MTokenStaking (staking mesLBR on Match Finance)
 * @author Eric Lee
 *
 * @notice
 *         Reward manager records the "extra boost reward" for each user
 *         Every time user stake/unstake, the reward manager will update the reward
 */
contract MTokenStaking is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant SCALE = 1e18;

    // mesLBR token
    IERC20 public mToken;

    // Stablecoin reward from lybra may have two tokens
    // If peUSD is enough, it will distribute peUSD
    // Otherwise, it will distribute an alternative stablecoin (currently USDC)
    // Keep eyes on its contract: 0xC2966A73Bbc53f3C99268ED84D245dBE972eD89e
    IERC20 public peUSD;
    IERC20 public altStableRewardToken;

    // All reward calculation and fetching are done by reward manager
    address public rewardManager;

    // Total esLBR and USDC to be distributed
    uint256 public totalBoostReward;
    uint256 public totalProtocolRevenue;

    // Accumulated reward per staked mesLBR
    uint256 public accBoostRewardPerMToken;
    uint256 public accProtocolRevenuePerMToken;

    // Total staked mesLBR
    uint256 public totalStaked;

    struct UserInfo {
        uint256 stakedAmount;
        uint256 boostRewardDebt;
        uint256 protocolRevenueDebt;
    }
    mapping(address user => UserInfo info) public users;

    event RewardManagerChanged(address newManager);
    event mTokenChanged(address newMToken);
    event peUSDChanged(address peUSD);
    event AltStableRewardChanged(address newAltStable);
    event RewardUpdated(uint256 boostReward, uint256 protocolRevenue);
    event Stake(address indexed user, uint256 amount, uint256 boostReward, uint256 protocolRevenue);
    event Unstake(address indexed user, uint256 amount, uint256 boostReward, uint256 protocolRevenue);

    error InsufficientStakedAmount();
    error InsufficientStableReward();
    error ZeroAmount();
    error NotRewardManager();

    function initialize(address _rewardManager, address _mToken, address _peUSD) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        rewardManager = _rewardManager;
        mToken = IERC20(_mToken);
        peUSD = IERC20(_peUSD);
    }

    modifier onlyRewardManager() {
        if (msg.sender != rewardManager) revert NotRewardManager();
        _;
    }

    function setRewardManager(address _rewardManager) external onlyOwner {
        rewardManager = _rewardManager;
        emit RewardManagerChanged(_rewardManager);
    }

    function setMToken(address _mToken) external onlyOwner {
        mToken = IERC20(_mToken);
        emit mTokenChanged(_mToken);
    }

    function setPEUSD(address _peUSD) external onlyOwner {
        peUSD = IERC20(_peUSD);
        emit peUSDChanged(_peUSD);
    }

    function setAltStableReward(address _altStableRewardToken) external onlyOwner {
        altStableRewardToken = IERC20(_altStableRewardToken);
        emit AltStableRewardChanged(_altStableRewardToken);
    }

    function stake(uint256 _amount) external nonReentrant {
        _stake(_amount, msg.sender);
    }

    function unstake(uint256 _amount) external nonReentrant {
        _unstake(_amount, msg.sender);
    }

    function delegateStake(address _to, uint256 _amount) external onlyRewardManager {
        _stake(_amount, _to);
    }

    function delegateUnstake(address _to, uint256 _amount) external onlyRewardManager {
        _unstake(_amount, _to);
    }

    /**
     * @notice Get pending rewards for a user
     *         Rewards = boost reward (mesLBR) + protocol revenue (peUSD/USDC)
     *         (Protocol revenue is calculated as one number, not distinguish peUSD and USDC)
     *
     * @param _user User address
     *
     * @return pendingBoostReward     Pending boost reward
     * @return pendingProtocolRevenue Pending protocol revenue
     */
    function pendingRewards(address _user) public view returns (uint256, uint256) {
        uint256 newPendingBoostReward = IRewardManager(rewardManager).pendingRewardInDistributor(address(mToken));
        uint256 newPendingProtocolRevenue = IRewardManager(rewardManager).pendingRewardInDistributor(address(peUSD)) +
            IRewardManager(rewardManager).pendingRewardInDistributor(address(altStableRewardToken));

        UserInfo memory user = users[_user];

        uint256 newAccBoostReward = accBoostRewardPerMToken + (newPendingBoostReward * SCALE) / totalStaked;
        uint256 newAccProtocolRevenue = accProtocolRevenuePerMToken + (newPendingProtocolRevenue * SCALE) / totalStaked;

        uint256 pendingBoostReward = (user.stakedAmount * newAccBoostReward) / SCALE - user.boostRewardDebt;
        uint256 pendingProtocolRevenue = (user.stakedAmount * newAccProtocolRevenue) / SCALE - user.protocolRevenueDebt;

        return (pendingBoostReward, pendingProtocolRevenue);
    }

    /**
     * @notice Compound (claim and stake)
     *         1) Claim all rewards
     *         2) Stake all new rewards
     */
    function compound() external {
        (uint256 pendingBoostReward, uint256 pendingProtocolRevenue) = pendingRewards(msg.sender);

        // Distribute stablecoin reward
        _distributeStableReward(msg.sender, pendingProtocolRevenue);

        // Distribute mesLBR reward and re-stake
        mToken.safeTransfer(msg.sender, pendingBoostReward);
        _stake(pendingBoostReward, msg.sender);
    }

    function _stake(uint256 _amount, address _user) internal {
        if (_amount == 0) revert ZeroAmount();

        updateReward();

        mToken.safeTransferFrom(_user, address(this), _amount);

        UserInfo storage user = users[_user];

        uint256 pendingBoostReward;
        uint256 pendingProtocolRevenue;

        if (user.stakedAmount > 0) {
            pendingBoostReward = (user.stakedAmount * accBoostRewardPerMToken) / SCALE - user.boostRewardDebt;

            pendingProtocolRevenue =
                (user.stakedAmount * accProtocolRevenuePerMToken) /
                SCALE -
                user.protocolRevenueDebt;

            mToken.safeTransfer(_user, pendingBoostReward);
            _distributeStableReward(_user, pendingProtocolRevenue);
        }

        user.stakedAmount += _amount;
        totalStaked += _amount;

        _updateUserDebt(msg.sender);

        emit Stake(_user, _amount, pendingBoostReward, pendingProtocolRevenue);
    }

    function _unstake(uint256 _amount, address _user) internal {
        UserInfo storage user = users[_user];

        if (user.stakedAmount < _amount) revert InsufficientStakedAmount();

        updateReward();

        uint256 pendingBoostReward = (user.stakedAmount * accBoostRewardPerMToken) / SCALE - user.boostRewardDebt;
        uint256 pendingProtocolRevenue = (user.stakedAmount * accProtocolRevenuePerMToken) /
            SCALE -
            user.protocolRevenueDebt;

        user.stakedAmount -= _amount;
        totalStaked -= _amount;

        mToken.safeTransfer(_user, pendingBoostReward + _amount);
        peUSD.safeTransfer(_user, pendingProtocolRevenue);

        _updateUserDebt(msg.sender);

        emit Unstake(_user, _amount, pendingBoostReward, pendingProtocolRevenue);
    }

    function harvest() external nonReentrant {
        UserInfo storage user = users[msg.sender];

        updateReward();

        uint256 pendingBoostReward = (user.stakedAmount * accBoostRewardPerMToken) / SCALE - user.boostRewardDebt;
        uint256 pendingProtocolRevenue = (user.stakedAmount * accProtocolRevenuePerMToken) /
            SCALE -
            user.protocolRevenueDebt;

        mToken.safeTransfer(msg.sender, pendingBoostReward);
        _distributeStableReward(msg.sender, pendingProtocolRevenue);

        _updateUserDebt(msg.sender);
    }

    /**
     * @notice Update this contract's reward status
     */
    function updateReward() public {
        // uint256 mTokenReward = IRewardDistributor(rewardDistributors[address(mToken)]).distribute();
        // uint256 peUSDReward = IRewardDistributor(rewardDistributors[address(peUSD)]).distribute();
        // uint256 altStableReward = IRewardDistributor(rewardDistributors[address(altStableRewardToken)]).distribute();

        if (totalStaked == 0) return;

        uint256 mTokenReward = IRewardManager(rewardManager).distributeRewardFromDistributor(address(mToken));
        uint256 peUSDReward = IRewardManager(rewardManager).distributeRewardFromDistributor(address(peUSD));
        uint256 altStableReward = IRewardManager(rewardManager).distributeRewardFromDistributor(
            address(altStableRewardToken)
        );

        totalBoostReward += mTokenReward;
        totalProtocolRevenue += peUSDReward + altStableReward;

        accBoostRewardPerMToken += (mTokenReward * SCALE) / totalStaked;
        accProtocolRevenuePerMToken += ((peUSDReward + altStableReward) * SCALE) / totalStaked;

        emit RewardUpdated(totalBoostReward, totalProtocolRevenue);
    }

    function _updateUserDebt(address _user) internal {
        users[_user].boostRewardDebt = (users[_user].stakedAmount * accBoostRewardPerMToken) / SCALE;
        users[_user].protocolRevenueDebt = (users[_user].stakedAmount * accProtocolRevenuePerMToken) / SCALE;
    }

    function emergencyWithdraw(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function _distributeStableReward(address _to, uint256 _amount) internal {
        uint256 peUSDBalance = peUSD.balanceOf(address(this));

        // If the user's stablecoin pending reward is less than the peUSD balance, give him peUSD
        if (_amount <= peUSDBalance) peUSD.safeTransfer(_to, _amount);
        else {
            uint256 altStableRewardBalance = altStableRewardToken.balanceOf(address(this));

            if (_amount > peUSDBalance && _amount <= peUSDBalance + altStableRewardBalance) {
                peUSD.safeTransfer(_to, peUSDBalance);
                altStableRewardToken.safeTransfer(_to, _amount - peUSDBalance);
            } else revert InsufficientStableReward();
        }
    }
}
