// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/DappInterfaces.sol";

contract STETHHelper {
    using SafeERC20 for IERC20;

    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /**
     * @return Amount to add to { supplied } mapping in Match Pool contract
     */
    function toLSD() external payable returns (uint256) {
        uint256 sharesAmount = ILido(STETH).submit{value: msg.value}(address(0));
        require(sharesAmount != 0, "ZERO_DEPOSIT");
        IERC20(STETH).safeTransfer(msg.sender, sharesAmount);
        return msg.value;
    }
}

contract WSTETHHelper {
    using SafeERC20 for IERC20;

    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /**
     * @return Amount to add to { supplied } mapping in Match Pool contract
     */
    function toLSD() external payable returns (uint256) {
        uint256 sharesAmount = ILido(STETH).submit{value: msg.value}(address(0));
        require(sharesAmount != 0, "ZERO_DEPOSIT");
        IERC20(STETH).approve(WSTETH, msg.value);
        uint256 wstETHAmount = IWstETH(WSTETH).wrap(msg.value);
        IERC20(WSTETH).safeTransfer(msg.sender, wstETHAmount);
        return wstETHAmount;
    }
}

contract WBETHHelper {
    using SafeERC20 for IERC20;

    address constant WBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;

    /**
     * @dev Starting balance must be zero, under no circumstances will helper contract keep any LSD
     * @return Amount to add to { supplied } mapping in Match Pool contract
     */
    function toLSD() external payable returns (uint256) {
        IWBETH(WBETH).deposit{value: msg.value}(address(0));
        uint256 balance = IERC20(WBETH).balanceOf(address(this));
        IERC20(WBETH).safeTransfer(msg.sender, balance);
        return balance;
    }
}

contract RETHHelper {
    using SafeERC20 for IERC20;

    IRocketStorageInterface constant rocketStorage = IRocketStorageInterface(0x1d8f8f00cfa6758d7bE78336684788Fb0ee0Fa46);
    address constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;

    function toLSD() external payable returns (uint256) {
        IRocketDepositPool(rocketStorage.getAddress(keccak256(abi.encodePacked("contract.address", "rocketDepositPool")))).deposit{value: msg.value}();
        uint256 balance = IERC20(RETH).balanceOf(address(this));
        IERC20(RETH).safeTransfer(msg.sender, balance);
        return balance;
    }
}