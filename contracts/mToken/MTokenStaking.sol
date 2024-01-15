// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRewardManager } from "../interfaces/IRewardManager.sol";
import { IRewardDistributorFactory } from "../interfaces/IRewardDistributorFactory.sol";

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
    using SafeERC20 for IERC20Metadata;

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Constants **************************************** //
    // ---------------------------------------------------------------------------------------- //

    uint256 public constant SCALE = 1e18;

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Variables **************************************** //
    // ---------------------------------------------------------------------------------------- //

    // mesLBR token
    IERC20Metadata public mToken;

    // Stablecoin reward from lybra may have two tokens
    // If peUSD is enough, it will distribute peUSD
    // Otherwise, it will distribute an alternative stablecoin (currently USDC)
    // Keep eyes on its contract: 0xC2966A73Bbc53f3C99268ED84D245dBE972eD89e
    IERC20Metadata public peUSD;
    IERC20Metadata public altStableRewardToken;

    // All reward calculation and fetching are done by reward manager
    address public rewardManager;

    // All reward distribution are done by reward distributor factory
    address public rewardDistributorFactory;

    // Total esLBR and protocol revenue (ever received)
    uint256 public totalBoostReward;
    uint256 public totalProtocolRevenue; // Include both peUSD and altStablecoin

    // Accumulated reward per staked mesLBR
    uint256 public accBoostRewardPerMToken;
    uint256 public accProtocolRevenuePerMToken;

    // Total staked mesLBR
    uint256 public totalStaked;

    struct UserInfo {
        uint256 amount;
        uint256 boostRewardDebt;
        uint256 protocolRevenueDebt;
        uint256 pendingReward;
        uint256 pendingProtocolRevenue;
    }
    mapping(address user => UserInfo info) public users;

    // ---------------------------------------------------------------------------------------- //
    // *************************************** Events ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    event RewardManagerChanged(address newManager);
    event MTokenChanged(address newMToken);
    event PEUSDChanged(address peUSD);
    event AltStableRewardChanged(address newAltStable);
    event RewardUpdated(uint256 boostReward, uint256 protocolRevenue);
    event Stake(address indexed user, uint256 amount);
    event Unstake(address indexed user, uint256 amount);
    event Harvest(address indexed user, uint256 boostReward, uint256 protocolRevenue);
    event Compound(address indexed user, uint256 boostReward);
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

    function initialize(
        address _rewardManager,
        address _mToken,
        address _peUSD,
        address _altStableRewardToken
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        rewardManager = _rewardManager;
        mToken = IERC20Metadata(_mToken);
        peUSD = IERC20Metadata(_peUSD);
        altStableRewardToken = IERC20Metadata(_altStableRewardToken);
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
        mToken = IERC20Metadata(_mToken);
        emit MTokenChanged(_mToken);
    }

    function setPEUSD(address _peUSD) external onlyOwner {
        peUSD = IERC20Metadata(_peUSD);
        emit PEUSDChanged(_peUSD);
    }

    function setAltStableReward(address _altStableRewardToken) external onlyOwner {
        altStableRewardToken = IERC20Metadata(_altStableRewardToken);
        emit AltStableRewardChanged(_altStableRewardToken);
    }

    function setRewardDistributorFactory(address _rewardDistributorFactory) external onlyOwner {
        rewardDistributorFactory = _rewardDistributorFactory;
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
    function pendingRewards(
        address _user
    ) public view returns (uint256 pendingBoostReward, uint256 pendingProtocolRevenue) {
        if (totalStaked == 0) return (0, 0);

        uint256 newPendingBoostReward = IRewardDistributorFactory(rewardDistributorFactory).pendingReward(
            address(mToken),
            address(this)
        );
        uint256 newPendingPEUSDReward = IRewardDistributorFactory(rewardDistributorFactory).pendingReward(
            address(peUSD),
            address(this)
        );
        uint256 newPendingAltStablecoinReward = IRewardDistributorFactory(rewardDistributorFactory).pendingReward(
            address(altStableRewardToken),
            address(this)
        );
        // Pending protocol revenue is with 18 decimals
        uint256 altDecimals = altStableRewardToken.decimals();
        uint256 newPendingProtocolRevenue = newPendingPEUSDReward +
            newPendingAltStablecoinReward *
            10 ** (18 - altDecimals);

        UserInfo memory user = users[_user];

        uint256 newAccBoostReward = accBoostRewardPerMToken + (newPendingBoostReward * SCALE) / totalStaked;
        uint256 newAccProtocolRevenue = accProtocolRevenuePerMToken + (newPendingProtocolRevenue * SCALE) / totalStaked;

        pendingBoostReward = (user.amount * newAccBoostReward) / SCALE - user.boostRewardDebt;
        pendingProtocolRevenue = (user.amount * newAccProtocolRevenue) / SCALE - user.protocolRevenueDebt;
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
        if (user.amount == 0) revert ZeroAmount();

        // ! Only record pending protocol revenue here
        // ! The pending boost reward is restaked
        uint256 pendingBoostReward = (user.amount * accBoostRewardPerMToken) / SCALE - user.boostRewardDebt;
        uint256 pendingProtocolRevenue = (user.amount * accProtocolRevenuePerMToken) / SCALE - user.protocolRevenueDebt;
        user.pendingProtocolRevenue += pendingProtocolRevenue;

        // Distribute mesLBR reward and re-stake
        // mToken.safeTransfer(msg.sender, pendingBoostReward);
        _stake(pendingBoostReward, msg.sender, true);

        emit Compound(msg.sender, pendingBoostReward);
    }

    function harvest() external nonReentrant {
        updateReward();

        _recordUserReward(msg.sender);
        _updateUserDebt(msg.sender);

        (uint256 actualBoostReward, uint256 actualProtocolRevenue) = _claimUserReward(msg.sender);

        emit Harvest(msg.sender, actualBoostReward, actualProtocolRevenue);
    }

    /**
     * @notice Update this contract's reward status
     */
    function updateReward() public {
        // If no stake, no need to update
        if (totalStaked == 0) return;

        // Reward distributors will mint mesLBR and send peUSD & altStablecoin to this contract
        // Call rewardManager "distributeRewardFromDistributor" => Call distributors "distribute"
        uint256 mTokenReward = IRewardDistributorFactory(rewardDistributorFactory).distribute(address(mToken));
        uint256 peUSDReward = IRewardDistributorFactory(rewardDistributorFactory).distribute(address(peUSD));
        uint256 altStableReward = IRewardDistributorFactory(rewardDistributorFactory).distribute(
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
        IERC20Metadata(_token).safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(_token, _amount);
    }

    // ---------------------------------------------------------------------------------------- //
    // ********************************* Internal Functions *********************************** //
    // ---------------------------------------------------------------------------------------- //

    function _stake(uint256 _amount, address _user, bool _isCompound) internal {
        if (_amount == 0) revert ZeroAmount();

        UserInfo storage user = users[_user];

        // If this is a staked called from "compound"
        // no need to update the pool's reward
        // no need to transfer tokens
        // no need to distribute reward again
        if (!_isCompound) {
            updateReward();

            mToken.safeTransferFrom(_user, address(this), _amount);

            if (user.amount > 0) {
                _recordUserReward(_user);
            }
        }

        user.amount += _amount;
        totalStaked += _amount;

        // Even if this is called from "compound"
        // The user's reward debt has changed because his balance changed
        // Only need to be updated once here, not needed in "compound"
        _updateUserDebt(msg.sender);

        emit Stake(_user, _amount);
    }

    function _unstake(uint256 _amount, address _user) internal {
        UserInfo storage user = users[_user];

        if (user.amount < _amount) revert InsufficientStakedAmount();

        updateReward();

        _recordUserReward(_user);

        user.amount -= _amount;
        totalStaked -= _amount;

        mToken.safeTransfer(_user, _amount);

        _updateUserDebt(msg.sender);

        emit Unstake(_user, _amount);
    }

    function _recordUserReward(address _user) internal {
        UserInfo storage user = users[_user];
        uint256 userAmount = user.amount;

        // If user has no staked amount before, return (0,0)
        if (userAmount > 0) {
            uint256 pendingMesLBRReward = (userAmount * accBoostRewardPerMToken) / SCALE - user.boostRewardDebt;
            user.pendingReward += pendingMesLBRReward;

            // Mint more vlMatch reward to the user
            uint256 pendingProtocolRevenue = (userAmount * accProtocolRevenuePerMToken) /
                SCALE -
                user.protocolRevenueDebt;
            user.pendingProtocolRevenue += pendingProtocolRevenue;
        }
    }

    function _claimUserReward(
        address _user
    ) internal returns (uint256 actualBoostReward, uint256 actualProtocolRevenue) {
        UserInfo storage user = users[_user];

        actualBoostReward = _safeMTokenTransfer(_user, user.pendingReward);

        actualProtocolRevenue = user.pendingProtocolRevenue;
        _distributeStableReward(_user, user.pendingProtocolRevenue);

        user.pendingReward -= actualBoostReward;
        user.pendingProtocolRevenue = 0;
    }

    function _updateUserDebt(address _user) internal {
        uint256 userAmount = users[_user].amount;

        users[_user].boostRewardDebt = (userAmount * accBoostRewardPerMToken) / SCALE;
        users[_user].protocolRevenueDebt = (userAmount * accProtocolRevenuePerMToken) / SCALE;
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
            // Alt stablecoin may have different decimals
            uint256 altDecimals = altStableRewardToken.decimals();

            uint256 altStableRewardBalance = altStableRewardToken.balanceOf(address(this)) * 10 ** (18 - altDecimals);

            if (_amount > peUSDBalance && _amount <= peUSDBalance + altStableRewardBalance) {
                peUSD.safeTransfer(_to, peUSDBalance);

                uint256 altStablecoinAmount = (_amount - peUSDBalance) / (10 ** (18 - altDecimals));
                altStableRewardToken.safeTransfer(_to, altStablecoinAmount);
            } else revert InsufficientStableReward();
        }
    }

    function _safeMTokenTransfer(address _to, uint256 _amount) internal returns (uint256 actualAmount) {
        uint256 balance = mToken.balanceOf(address(this));

        if (_amount > balance) {
            mToken.safeTransfer(_to, balance);
            actualAmount = balance;
        } else {
            mToken.safeTransfer(_to, _amount);
            actualAmount = _amount;
        }
    }
}
