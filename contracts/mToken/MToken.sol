// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title MToken (mesLBR for Match Finance)
 * @author Eric Lee (ylikp.ust@gmail.com)
 *
 * @notice mesLBR represents user's shares on Match Finance
 *         mesLBR is a ERC20 token
 *
 *         ! It is the transferrable version of "esLBR" (from Lybra)
 *         ! esLBR is designed to be not transferrable
 *         ! and Match Finance give it liquidity by transferring to mesLBR
 *
 *         It can be got from:
 *         1) Supply dLP / LSD assets on Match Finance
 *         2) Stake mesLBR
 *         3) Stake vlMatch (vlMatch is a special form of Match token)
 *
 *         it can be used to:
 *         1) Stake inside "mesLBRStaking" to get more mesLBR
 *         2) Stake inside "mesLBRStaking" to share protocol revenue from Lybra
 */

contract MToken is ERC20Upgradeable, OwnableUpgradeable {
    // ---------------------------------------------------------------------------------------- //
    // ************************************* Variables **************************************** //
    // ---------------------------------------------------------------------------------------- //
    mapping(address account => bool isValidMinter) public isMinter;

    // ---------------------------------------------------------------------------------------- //
    // ************************************** Events ****************************************** //
    // ---------------------------------------------------------------------------------------- //

    event MinterAdded(address minter);
    event MinterRemoved(address minter);

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Initializer *************************************** //
    // ---------------------------------------------------------------------------------------- //

    function initialize(string memory name_, string memory symbol_) external initializer {
        __ERC20_init(name_, symbol_);
        __Ownable_init();
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Set Functions ************************************* //
    // ---------------------------------------------------------------------------------------- //

    function addMinter(address _minter) external onlyOwner {
        isMinter[_minter] = true;
        emit MinterAdded(_minter);
    }

    function removeMinter(address _minter) external onlyOwner {
        isMinter[_minter] = false;
        emit MinterRemoved(_minter);
    }

    // ---------------------------------------------------------------------------------------- //
    // ********************************** Main Functions ************************************** //
    // ---------------------------------------------------------------------------------------- //

    function mint(address _to, uint256 _amount) external {
        require(isMinter[msg.sender], "MToken: only minter can mint");
        _mint(_to, _amount);
    }
}
