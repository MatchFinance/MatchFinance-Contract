// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IMatchPool {
	// Total amount of ETH-LBR staked
	function totalStaked() external view returns (uint256);
	function staked(address _user) external view returns (uint256);
	// Total amount of stETH deposited to contract
	function totalSupplied() external view returns (uint256);
	function supplied(address _user) external view returns (uint256);
	function totalMinted() external view returns (uint256);
	function claimRebase() external returns (uint256);
	function borrowed(address _account) external view returns (uint256, uint256, uint256, uint256);
}