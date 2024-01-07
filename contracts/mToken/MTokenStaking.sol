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
 * @author Eric Lee (ylikp.ust@gmail.com)
 *
 * @notice Users can stake mesLBR inside this contract to get:
 *         1) 100% boosting reward from Lybra (more mesLBR)
 *         2) 100% protocol revenue from Lybra (peUSD / altStablecoin)
 *
 */
contract MTokenStaking is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Constants **************************************** //
    // ---------------------------------------------------------------------------------------- //

    uint256 public constant SCALE = 1e18;

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Variables **************************************** //
    // ---------------------------------------------------------------------------------------- //

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

    // Total esLBR and protocol revenue (ever received)
    uint256 public totalBoostReward;
    uint256 public totalProtocolRevenue; // Include both peUSD and altStablecoin

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

    // ---------------------------------------------------------------------------------------- //
    // *************************************** Events ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    event RewardManagerChanged(address newManager);
    event mTokenChanged(address newMToken);
    event peUSDChanged(address peUSD);
    event AltStableRewardChanged(address newAltStable);
    event RewardUpdated(uint256 boostReward, uint256 protocolRevenue);
    event Stake(address indexed user, uint256 amount, uint256 boostReward, uint256 protocolRevenue);
    event Unstake(address indexed user, uint256 amount, uint256 boostReward, uint256 protocolRevenue);
    event Compound(address indexed user, uint256 boostReward, uint256 protocolRevenue);
    event EmergencyWithdraw(address token, uint256 amount);

    // ---------------------------------------------------------------------------------------- //
    // *************************************** Errors ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    error InsufficientStakedAmount();
    error InsufficientStableReward();
    error ZeroAmount();
    error NotRewardManager();

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Initializer *************************************** //
    // ---------------------------------------------------------------------------------------- //

    function initialize(address _rewardManager, address _mToken, address _peUSD) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        rewardManager = _rewardManager;
        mToken = IERC20(_mToken);
        peUSD = IERC20(_peUSD);
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Modifiers **************************************** //
    // ---------------------------------------------------------------------------------------- //

    modifier onlyRewardManager() {
        if (msg.sender != rewardManager) revert NotRewardManager();
        _;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Set Functions ************************************* //
    // ---------------------------------------------------------------------------------------- //
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

    // ---------------------------------------------------------------------------------------- //
    // *********************************** Main Functions ************************************* //
    // ---------------------------------------------------------------------------------------- //

    function stake(uint256 _amount) external nonReentrant {
        _stake(_amount, msg.sender, false);
    }

    function unstake(uint256 _amount) external nonReentrant {
        _unstake(_amount, msg.sender);
    }

    function delegateStake(address _to, uint256 _amount) external onlyRewardManager {
        _stake(_amount, _to, false);
    }

    function delegateUnstake(address _to, uint256 _amount) external onlyRewardManager {
        _unstake(_amount, _to);
    }

    /**
     * @notice Get pending rewards for a user
     *         Rewards = boost reward (mesLBR) + protocol revenue (peUSD/USDC)
     *         (Protocol revenue is calculated as one number, not distinguish peUSD and USDC)
     *
     * # @dev  The amount of pending reward is got from reward distributor contracts with "pendingRewardInDistributor".
     * #       Each reward token has its own distributor, so we make 3 calls here for mesLBR, peUSD and altStablecoin.
     * #       Reward for peUSD and altStablecoin is calculated together.
     *
     * @param _user User address
     *
     * @return pendingBoostReward     Pending boost reward
     * @return pendingProtocolRevenue Pending protocol revenue
     */
    function pendingRewards(address _user) public view returns (uint256, uint256) {
        uint256 newPendingBoostReward = IRewardManager(rewardManager).pendingRewardInDistributor(
            address(mToken),
            address(this)
        );
        uint256 newPendingProtocolRevenue = IRewardManager(rewardManager).pendingRewardInDistributor(
            address(peUSD),
            address(this)
        ) + IRewardManager(rewardManager).pendingRewardInDistributor(address(altStableRewardToken), address(this));

        UserInfo memory user = users[_user];

        uint256 newAccBoostReward = accBoostRewardPerMToken + (newPendingBoostReward * SCALE) / totalStaked;
        uint256 newAccProtocolRevenue = accProtocolRevenuePerMToken + (newPendingProtocolRevenue * SCALE) / totalStaked;

        uint256 pendingBoostReward = (user.stakedAmount * newAccBoostReward) / SCALE - user.boostRewardDebt;
        uint256 pendingProtocolRevenue = (user.stakedAmount * newAccProtocolRevenue) / SCALE - user.protocolRevenueDebt;

        return (pendingBoostReward, pendingProtocolRevenue);
    }

    /**
     * @notice Compound (claim and stake)
     *         1) Claim all rewards (mesLBR and stablecoins)
     *         2) Stake all new mesLBR
     *         The stablecoin reward will be transferred to user
     */
    function compound() external nonReentrant {
        // First update the pool's status
        updateReward();

        // Then claim the reward (similar to "harvest")
        UserInfo storage user = users[msg.sender];

        // If no deposit before, can not compound
        if (user.stakedAmount == 0) revert ZeroAmount();

        uint256 pendingBoostReward = (user.stakedAmount * accBoostRewardPerMToken) / SCALE - user.boostRewardDebt;
        uint256 pendingProtocolRevenue = (user.stakedAmount * accProtocolRevenuePerMToken) /
            SCALE -
            user.protocolRevenueDebt;

        // Distribute stablecoin reward
        _distributeStableReward(msg.sender, pendingProtocolRevenue);

        // Distribute mesLBR reward and re-stake
        // mToken.safeTransfer(msg.sender, pendingBoostReward);
        _stake(pendingBoostReward, msg.sender, true);

        emit Compound(msg.sender, pendingBoostReward, pendingProtocolRevenue);
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
        // If no stake, no need to update
        if (totalStaked == 0) return;

        // Reward distributors will mint mesLBR and send peUSD & altStablecoin to this contract
        // Call rewardManager "distributeRewardFromDistributor" => Call distributors "distribute"
        uint256 mTokenReward = IRewardManager(rewardManager).distributeRewardFromDistributor(address(mToken));
        uint256 peUSDReward = IRewardManager(rewardManager).distributeRewardFromDistributor(address(peUSD));
        uint256 altStableReward = IRewardManager(rewardManager).distributeRewardFromDistributor(
            address(altStableRewardToken)
        );

        // Update total reward inside this staking contract
        totalBoostReward += mTokenReward;
        totalProtocolRevenue += peUSDReward + altStableReward;

        // Update accumulated reward inside this staking contract
        accBoostRewardPerMToken += (mTokenReward * SCALE) / totalStaked;
        accProtocolRevenuePerMToken += ((peUSDReward + altStableReward) * SCALE) / totalStaked;

        emit RewardUpdated(totalBoostReward, totalProtocolRevenue);
    }

    function emergencyWithdraw(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(_token, _amount);
    }

    // ---------------------------------------------------------------------------------------- //
    // ********************************* Internal Functions *********************************** //
    // ---------------------------------------------------------------------------------------- //

    function _stake(uint256 _amount, address _user, bool _isCompound) internal {
        if (_amount == 0) revert ZeroAmount();

        UserInfo storage user = users[_user];

        uint256 pendingBoostReward;
        uint256 pendingProtocolRevenue;

        // If this is a staked called from "compound"
        // no need to update the pool's reward
        // no need to transfer tokens
        // no need to distribute reward again
        if (!_isCompound) {
            updateReward();

            mToken.safeTransferFrom(_user, address(this), _amount);

            if (user.stakedAmount > 0) {
                pendingBoostReward = (user.stakedAmount * accBoostRewardPerMToken) / SCALE - user.boostRewardDebt;

                pendingProtocolRevenue =
                    (user.stakedAmount * accProtocolRevenuePerMToken) /
                    SCALE -
                    user.protocolRevenueDebt;

                mToken.safeTransfer(_user, pendingBoostReward);
                _distributeStableReward(_user, pendingProtocolRevenue);
            }
        }

        user.stakedAmount += _amount;
        totalStaked += _amount;

        // Even if this is called from "compound"
        // The user's reward debt has changed because his balance changed
        // Only need to be updated once here, not needed in "compound"
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
        _distributeStableReward(_user, pendingProtocolRevenue);

        _updateUserDebt(msg.sender);

        emit Unstake(_user, _amount, pendingBoostReward, pendingProtocolRevenue);
    }

    function _updateUserDebt(address _user) internal {
        users[_user].boostRewardDebt = (users[_user].stakedAmount * accBoostRewardPerMToken) / SCALE;
        users[_user].protocolRevenueDebt = (users[_user].stakedAmount * accProtocolRevenuePerMToken) / SCALE;
    }

    // Distribute stablecoin reward to user
    // If peUSD is enough, distribute peUSD
    // If peUSD is not enough, distribute altStablecoin
    // If peUSD + altStablecoin is not enough, revert
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
