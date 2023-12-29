// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../../interfaces/LybraInterfaces.sol";

contract LybraConfigurator is Ownable {
    IMining public eUSDMiningIncentives;
    IEUSD public EUSD;
    IEUSD public peUSD;
    IRewardPool public lybraProtocolRewardsPool;
    uint256 mintFeeApy = 150;
    mapping(address => uint256) vaultWeight;

    event SendProtocolRewards(address indexed token, uint256 amount, uint256 timestamp);

    constructor (address _eusd, address _peusd) {
        EUSD = IEUSD(_eusd);
        peUSD = IEUSD(_peusd);
    }

    function setMining(address _mining) external onlyOwner {
        eUSDMiningIncentives = IMining(_mining);
    }

    function setVaultWeight(address pool, uint256 weight) external onlyOwner {
        vaultWeight[pool] = weight;
    }

    function setEUSD(address _eusd) external onlyOwner {
        EUSD = IEUSD(_eusd);
    }

    function setProtocolRewardsPool(address _protocolRewards) external onlyOwner {
        lybraProtocolRewardsPool = IRewardPool(_protocolRewards);
    }

    function getVaultWeight(address pool) external view returns (uint256) {
        if (vaultWeight[pool] == 0) return 100 * 1e18;
        return vaultWeight[pool];
    }

    function getEUSDAddress() external view returns (address) {
        return address(EUSD);
    }

    function getProtocolRewardsPool() external view returns (address) {
        return address(lybraProtocolRewardsPool);
    }

    function vaultMintFeeApy(address _pool) external view returns(uint256) {
        uint256 weight = vaultWeight[_pool];
        return mintFeeApy + (weight - weight);
    }

    function getSafeCollateralRatio(address _pool) external view returns (uint256) {
        uint256 weight = vaultWeight[_pool];
        return 150e18 + (weight - weight);
    }

    /**
     * @notice Distributes rewards to the LybraProtocolRewardsPool based on the available balance of peUSD and eUSD. 
     * If the balance is greater than 1e21, the distribution process is triggered.
     * 
     * First, if the eUSD balance is greater than 1,000 and the premiumTradingEnabled flag is set to true, 
     * and the eUSD/USDC premium exceeds 0.5%, eUSD will be exchanged for USDC and added to the LybraProtocolRewardsPool. 
     * Otherwise, eUSD will be directly converted to peUSD, and the entire peUSD balance will be transferred to the LybraProtocolRewardsPool.
     * @dev The protocol rewards amount is notified to the LybraProtocolRewardsPool for proper reward allocation.
     */
    function distributeRewards() external {
        // uint256 balance = EUSD.balanceOf(address(this));
        // if (balance >= 1e21) {
        //     if(premiumTradingEnabled){
        //         (, int price, , , ) = eUSDPriceFeed.latestRoundData();
        //         if(price >= 100_500_000){
        //             EUSD.approve(address(curvePool), balance);
        //             uint256 amount = curvePool.exchange_underlying(0, 2, balance, balance * uint(price) * 995 / 1e23);
        //             IERC20(stableToken).safeTransfer(address(lybraProtocolRewardsPool), amount);
        //             lybraProtocolRewardsPool.notifyRewardAmount(amount, 1);
        //             emit SendProtocolRewards(stableToken, amount, block.timestamp);
        //         }
        //     } else {
        //         peUSD.convertToPeUSD(address(this), balance);
        //     }
        // }
        uint256 peUSDBalance = peUSD.balanceOf(address(this));
        if(peUSDBalance >= 1e21) {
            peUSD.transfer(address(lybraProtocolRewardsPool), peUSDBalance);
            lybraProtocolRewardsPool.notifyRewardAmount(peUSDBalance, 0);
            emit SendProtocolRewards(address(peUSD), peUSDBalance, block.timestamp);
        }
    }

    function refreshMintReward(address _account) external {
         eUSDMiningIncentives.refreshReward(_account);
    }
}