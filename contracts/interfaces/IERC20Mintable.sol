// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IERC20Mintable {
    function mint(address _to, uint256 _amount) external;
}
