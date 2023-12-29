// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

contract LBROracle is Ownable {
    int256 price;

    constructor() {
        price = 0.92e8;
    }

    function setPrice(int256 _price) external onlyOwner {
        price = _price;
    }

    function latestRoundData() external view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {

        roundId = 0;
        answer = price;
        startedAt = 0;
        updatedAt = 0;
        answeredInRound = 0;
    }
}