// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;
/**
 * @title EUSDMiningIncentives is a stripped down version of Synthetix StakingRewards.sol, to reward esLBR to eUSD&peUSD minters.
 * Differences from the original contract,
 * - totalStaked and stakedOf(user) are different from the original version.
 * - When a user's borrowing changes in any of the Lst vaults, the `refreshReward()` function needs to be called to update the data.
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "../interfaces/LybraInterfaces.sol";

contract MiningIncentive is Ownable {
    IConfigurator public immutable configurator;
    IMintPool public vault;

    // Duration of rewards to be paid out (in seconds)
    uint256 public duration = 604_800;
    // Timestamp of when the rewards finish
    uint256 public finishAt;
    // Minimum of last updated time and reward finish time
    uint256 public updatedAt;
    // Reward to be paid out per second
    uint256 public rewardRatio = 7e17;
    // Sum of (reward ratio * dt * 1e18 / total supply)
    uint256 public rewardPerTokenStored;
    // User address => rewardPerTokenStored
    mapping(address => uint256) public userRewardPerTokenPaid;
    // User address => rewards to be claimed
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userUpdatedAt;
    uint256 public biddingFeeRatio = 3000;
    address public ethlbrStakePool;
    uint256 public minDlpRatio = 250;
    AggregatorV3Interface internal lpPriceFeed;
    AggregatorV3Interface internal lbrPriceFeed;
    bool public isEUSDBuyoutAllowed = true;

    event VaultChanged(address vaults, uint256 time);
    event LpOracleChanged(address newOracle, uint256 time);
    event LBROracleChanged(address newOracle, uint256 time);
    event ClaimReward(address indexed user, uint256 amount, uint256 time);
    event ClaimedOtherEarnings(address indexed user, address indexed Victim, uint256 buyAmount, uint256 biddingFee, bool useEUSD, uint256 time);
    event NotifyRewardChanged(uint256 addAmount, uint256 time);

    constructor(address _config, address _lpOracle, address _lbrOracle) {
        configurator = IConfigurator(_config);
        lpPriceFeed = AggregatorV3Interface(_lpOracle);
        lbrPriceFeed = AggregatorV3Interface(_lbrOracle);
    }

    modifier updateReward(address _account) {
        rewardPerTokenStored = rewardPerToken();
        updatedAt = lastTimeRewardApplicable();

        if (_account != address(0)) {
            rewards[_account] = earned(_account);
            userRewardPerTokenPaid[_account] = rewardPerTokenStored;
            userUpdatedAt[_account] = block.timestamp;
        }
        _;
    }

    function setLpOracle(address _lpOracle) external onlyOwner {
        lpPriceFeed = AggregatorV3Interface(_lpOracle);
        emit LpOracleChanged(_lpOracle, block.timestamp);
    }

    function setLBROracle(address _lbrOracle) external onlyOwner {
        lbrPriceFeed = AggregatorV3Interface(_lbrOracle);
        emit LBROracleChanged(_lbrOracle, block.timestamp);
    }

    // Set stETH mint vault
    function setPool(address _vault) external onlyOwner {
        vault = IMintPool(_vault);
        emit VaultChanged(_vault, block.timestamp);
    }

    function setBiddingCost(uint256 _biddingRatio) external onlyOwner {
        require(_biddingRatio <= 8000, "BCE");
        biddingFeeRatio = _biddingRatio;
    }

    function setMinDlpRatio(uint256 ratio) external onlyOwner {
        require(ratio <= 1_000, "BCE");
        minDlpRatio = ratio;
    }

    function setRewardsDuration(uint256 _duration) external onlyOwner {
        require(finishAt < block.timestamp, "reward duration not finished");
        duration = _duration;
    }

    function setEthlbrStakeInfo(address _pool) external onlyOwner {
        ethlbrStakePool = _pool;
    }
    function setEUSDBuyoutAllowed(bool _bool) external onlyOwner {
        isEUSDBuyoutAllowed = _bool;
    }

    /**
     * @notice Returns the total amount of minted eUSD&peUSD in the asset pools.
     * @return The total amount of minted eUSD&peUSD.
     * @dev It iterates through the vaults array and retrieves the total circulation of each asset pool using the getPoolTotalCirculation()
     * function from the ILybra interface. The total staked amount is calculated by multiplying the total circulation by the vault's
     * weight (obtained from configurator.getVaultWeight()). 
     */
    function totalStaked() public view returns (uint256) {
        return vault.getPoolTotalCirculation() * configurator.getVaultWeight(address(vault)) / 1e20;
    }

    /**
     * @notice Returns the total amount of borrowed eUSD and peUSD by the user.
     */
    function stakedOf(address user) public view returns (uint256) {
        return vault.getBorrowedOf(user) * configurator.getVaultWeight(address(vault)) / 1e20;
    }

    /**
     * @notice Returns the value of the user's staked LP tokens in the ETH-LBR liquidity pool.
     * @param user The user's address.
     * @return The value of the user's staked LP tokens.
     */
    function stakedLBRLpValue(address user) public view returns (uint256) {
        (, int lpPrice, , , ) = lpPriceFeed.latestRoundData();
        return IEUSD(ethlbrStakePool).balanceOf(user) * uint256(lpPrice) / 1e8;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return _min(finishAt, block.timestamp);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked() == 0) {
            return rewardPerTokenStored;
        }

        return rewardPerTokenStored + (rewardRatio * (lastTimeRewardApplicable() - updatedAt) * 1e18) / totalStaked();
    }

    /**
     * @notice Update user's claimable reward data and record the timestamp.
     */
    function refreshReward(address _account) external updateReward(_account) {}

    function getBoost() public pure returns (uint256) {
        return 100 * 1e18;
    }

    function earned(address _account) public view returns (uint256) {
        return ((stakedOf(_account) * getBoost() * (rewardPerToken() - userRewardPerTokenPaid[_account])) / 1e38) + rewards[_account];
    }

    /**
     * @notice Checks if the user's earnings can be claimed by others.
     * @param user The user's address.
     * @return  A boolean indicating if the user's earnings can be claimed by others.
     */
    function isOtherEarningsClaimable(address user) public view returns (bool) {
        uint256 staked = stakedOf(user);
        if(staked == 0) return true;
        return (stakedLBRLpValue(user) * 10_000) / staked < minDlpRatio;
    }

    function getReward() external updateReward(msg.sender) {
        require(!isOtherEarningsClaimable(msg.sender), "Insufficient DLP, unable to claim rewards");
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            emit ClaimReward(msg.sender, reward, block.timestamp);
        }
    }

    // /**
    //  * @notice Purchasing the esLBR earnings from users who have insufficient DLP.
    //  * @param user The address of the user whose earnings will be purchased.
    //  * @param useEUSD Boolean indicating if the purchase will be made using eUSD.
    //  * Requirements:
    //  * The user's earnings must be claimable by others.
    //  * If using eUSD, the purchase must be permitted.
    //  * The user must have non-zero rewards.
    //  * If using eUSD, the caller must have sufficient eUSD balance and allowance.
    //  */
    // function _buyOtherEarnings(address user, bool useEUSD) internal updateReward(user) {
    //     require(isOtherEarningsClaimable(user), "The rewards of the user cannot be bought out");
    //     require(rewards[user] != 0, "ZA");
    //     if(useEUSD) {
    //         require(isEUSDBuyoutAllowed, "The purchase using eUSD is not permitted.");
    //     }
    //     uint256 reward = rewards[user];
    //     rewards[user] = 0;
    //     uint256 biddingFee = (reward * biddingFeeRatio) / 10_000;
    //     if(useEUSD) {
    //         (, int lbrPrice, , , ) = lbrPriceFeed.latestRoundData();
    //         biddingFee = biddingFee * uint256(lbrPrice) / 1e8;
    //         bool success = EUSD.transferFrom(msg.sender, address(owner()), biddingFee);
    //         require(success, "TF");
    //     } else {
    //         IesLBR(LBR).burn(msg.sender, biddingFee);
    //     }
    //     IesLBR(esLBR).mint(msg.sender, reward);
    //     emit ClaimedOtherEarnings(msg.sender, user, reward, biddingFee, useEUSD, block.timestamp);
    // }

    // function buyOthersEarnings(address[] memory users, bool useEUSD) external {
    //     for(uint256 i; i < users.length; i++) {
    //         _buyOtherEarnings(users[i], useEUSD);
    //     }
    // }

    // function notifyRewardAmount(
    //     uint256 amount
    // ) external onlyOwner updateReward(address(0)) {
    //     require(amount != 0, "amount = 0");
    //     if (block.timestamp >= finishAt) {
    //         rewardRatio = amount / duration;
    //     } else {
    //         uint256 remainingRewards = (finishAt - block.timestamp) * rewardRatio;
    //         rewardRatio = (amount + remainingRewards) / duration;
    //     }

    //     require(rewardRatio != 0, "reward ratio = 0");

    //     finishAt = block.timestamp + duration;
    //     updatedAt = block.timestamp;
    //     emit NotifyRewardChanged(amount, block.timestamp);
    // }

    // Reward amount for a week
    function setRewardRatio(uint256 _amount) external onlyOwner updateReward(address(0)) {
        rewardRatio = _amount / duration;
    }

    function getLBRPrice() external view returns (uint256) {
        (, int lbrPrice, , , ) = lbrPriceFeed.latestRoundData();
        return uint256(lbrPrice);
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }
}