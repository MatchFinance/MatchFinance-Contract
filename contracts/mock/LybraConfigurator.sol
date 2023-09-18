// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

contract LybraConfigurator is Ownable {
    mapping(address => uint256) vaultWeight;

    function setVaultWeight(address pool, uint256 weight) external onlyOwner {
        vaultWeight[pool] = weight;
    }

    function getVaultWeight(address pool) external view returns (uint256) {
        if (vaultWeight[pool] == 0) return 100 * 1e18;
        return vaultWeight[pool];
    }
}