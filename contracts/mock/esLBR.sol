// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.19;
/**
 * @title esLBR is an ERC20-compliant token, but cannot be transferred and can only be minted through the esLBRMinter contract or redeemed for LBR by destruction.
 * - esLBR can be used for community governance voting.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract esLBR is ERC20 {
    // IConfigurator public immutable configurator;

    uint256 constant maxSupply = 100_000_000 * 1e18;

    constructor() ERC20("esLBR", "esLBR") {
        // configurator = IConfigurator(_config);
    }

    function _transfer(address, address, uint256) internal virtual override {
        revert("NA");
    }

    function mint(address user, uint256 amount) external returns (bool) {
        require(amount != 0, "ZA");
        // require(configurator.tokenMiner(msg.sender), "NA");
        require(totalSupply() + amount <= maxSupply, "exceeding the maximum supply quantity.");
        // IProtocolRewardsPool(configurator.getProtocolRewardsPool()).refreshReward(user);
        _mint(user, amount);
        return true;
    }

    function burn(address user, uint256 amount) external returns (bool) {
        require(amount != 0, "ZA");
        // require(configurator.tokenMiner(msg.sender), "NA");
        // IProtocolRewardsPool(configurator.getProtocolRewardsPool()).refreshReward(user);
        _burn(user, amount);
        return true;
    }
}