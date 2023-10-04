// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/LybraInterfaces.sol";

contract LybraConfigurator is Ownable {
    IMining mining;
    address EUSD;
    mapping(address => uint256) vaultWeight;

    constructor (address _eusd) {
        EUSD = _eusd;
    }

    function setMining(address _mining) external onlyOwner {
        mining = IMining(_mining);
    }

    function setVaultWeight(address pool, uint256 weight) external onlyOwner {
        vaultWeight[pool] = weight;
    }

    function setEUSD(address _eusd) external onlyOwner {
        EUSD = _eusd;
    }

    function getVaultWeight(address pool) external view returns (uint256) {
        if (vaultWeight[pool] == 0) return 100 * 1e18;
        return vaultWeight[pool];
    }

    function getEUSDAddress() external view returns (address) {
        return EUSD;
    }

    function refreshMintReward(address _account) external {
         mining.refreshReward(_account);
    }
}