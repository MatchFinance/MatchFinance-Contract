import { BigNumber, Contract, ContractFactory } from "ethers";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/dist/src/signer-with-address";

// import { ethers } from "hardhat";

const hre = require("hardhat");
const ethers = hre.ethers;
const upgrades = hre.upgrades;

export const deploy = async (contractName: string, params: Array<any>) => {
  const signers = await ethers.getSigners();

  const factory: ContractFactory = await ethers.getContractFactory(contractName);
  let contract: Contract;

  if (params.length > 0) contract = await factory.connect(signers[0]).deploy(...params);
  else contract = await factory.connect(signers[0]).deploy();

  return await contract.deployed();
};

export const deployUpgradeable = async (contractName: string, params: Array<any>, testing = false) => {
  const signers = await ethers.getSigners();
  const factory: ContractFactory = await ethers.getContractFactory(contractName);
  const contract: Contract = await upgrades.deployProxy(
    factory, params, testing ? { initializer: "initializeTest" } : {}
  );

  return await contract.deployed();
};

// ERC20 and ERC721 batch token minting, only specify one amount if all accounts are minting the same amount
export const mintTokens = async (tokenContract: Contract, mintAddress: Array<string>, mintAmount: Array<number | string>) => {
  if (mintAmount.length != mintAddress.length) {
    // Mint same amount for all minters
    for (let i = 0; i < mintAddress.length; ++i) {
      await tokenContract.mint(mintAddress[i], mintAmount[0]);
    }
  } else {
    // Mint different amounts for different minters
    for (let i = 0; i < mintAddress.length; ++i) {
      await tokenContract.mint(mintAddress[i], mintAmount[i]);
    }
  }
};

// ERC20 and ERC721 batch token approval, specify amount if approving ERC20
export const approveTokens = async (tokenContract: Contract, approver: Array<SignerWithAddress>, approvee: string, amount: Array<string> = []) => {
  if (amount.length == 0) {
    for (let i = 0; i < approver.length; ++i) {
      await tokenContract.connect(approver[i]).setApprovalForAll(approvee, true);
    }
  } else {
    if (amount.length != approver.length) {
      // Approve same amount for all approvers
      for (let i = 0; i < approver.length; ++i) {
        await tokenContract.connect(approver[i]).approve(approvee, amount[0]);  
      }
    } else {
      // Approve different amounts for different approvers
      for (let i = 0; i < approver.length; ++i) {
        await tokenContract.connect(approver[i]).approve(approvee, amount[i]);  
      }
    }
  }
}

export const toWei = (etherAmount: string, decimals: number = 18) => {
  return ethers.utils.parseUnits(etherAmount, decimals);
};

export const fromWei = (amount: string) => {
  return ethers.utils.formatUnits(amount, 18);
};

export const formatTokenAmount = (amount: string) => {
  return ethers.utils.formatUnits(amount, 18);
};

export const stablecoinToWei = (stablecoinAmount: string) => {
  return ethers.utils.parseUnits(stablecoinAmount, 6);
};

export const formatStablecoin = (stablecoinAmount: string | BigNumber) => {
  return ethers.utils.formatUnits(stablecoinAmount, 6);
};

export const zeroAddress = () => {
  return ethers.constants.AddressZero;
};

export const getLatestBlockNumber = async () => {
  const blockNumber = await ethers.provider.getBlockNumber();
  return blockNumber;
};

export const getLatestBlockTimestamp = async () => {
  const blockNumBefore = await ethers.provider.getBlockNumber();
  const blockBefore = await ethers.provider.getBlock(blockNumBefore);
  return blockBefore.timestamp;
};

export const mineBlocks = async (blockNumber: number) => {
  await hre.network.provider.send("hardhat_mine", [ethers.utils.hexValue(blockNumber)]);
};

export const mineTimestamp = async (timestamp: number) => {
  await ethers.provider.send("evm_mine", [timestamp]);
};

// Get the current timestamp in seconds
export const getNow = () => {
  const time = new Date().getTime();
  const now = Math.floor(time / 1000);
  return now;
};

export const toBN = (normalNumber: number) => {
  return ethers.BigNumber.from(normalNumber);
};

export const customErrorMsg = (msg: string) => {
  return "custom error " + msg;
};