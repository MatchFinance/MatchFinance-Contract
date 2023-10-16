import { Contract, ContractFactory } from "ethers";

import {
  readAddressList,
  readArgs,
  storeAddressList,
  storeArgs
} from "../scripts/contractAddress";

export const getNetwork = () => {
  const hre = require("hardhat");
  const { network } = hre;
  const _network = network.name == "hardhat" ? "localhost" : network.name;
  return _network;
};

/********************************* Store addresses & args *************************************/

export const writeDeployment = (network: string, name: string, _address: string, _args: Array<any>) => {
  const addressList = readAddressList();
  addressList[network][name] = _address;
  storeAddressList(addressList);

  const argsList = readArgs();
  argsList[network][name] = { address: _address, args: _args };
  storeArgs(argsList);
};

export const writeUpgradeableDeployment = (network: string, name: string, _address: string, implementation: string) => {
  const addressList = readAddressList();
  addressList[network][name] = _address;
  storeAddressList(addressList);

  const argsList = readArgs();
  argsList[network][name] = { address: implementation, args: [] };
  storeArgs(argsList);
};

/**************************************** Deployment ****************************************/

export const deploy = async (ethers: HardhatEthersHelpers, artifact: string, params: Array<any>) => {
  const signers: SignerWithAddress[] = await ethers.getSigners();

  const factory: ContractFactory = <ContractFactory>await ethers.getContractFactory(artifact);
  let contract: Contract;

  if (params.length > 0) contract = await factory.connect(signers[0]).deploy(...params);
  else contract = await factory.connect(signers[0]).deploy();

  return await contract.deployed();
};

export const deployUpgradeable = async (
  ethers: HardhatEthersHelpers,
  upgrades: any,
  artifact: string,
  params: Array<any>,
) => {
  const FEE_DATA = {
    maxFeePerGas: ethers.utils.parseUnits('8', 'gwei'),
    maxPriorityFeePerGas: ethers.utils.parseUnits('3', 'gwei'),
  };

  // Wrap the provider so we can override fee data.
  const provider = new ethers.providers.FallbackProvider([ethers.provider], 1);
  provider.getFeeData = async () => FEE_DATA;

  // Create the signer for the mnemonic, connected to the provider with hardcoded fee data
  const signer = new ethers.Wallet(process.env.PRIVATE_KEY).connect(provider);

  const factory: ContractFactory = <ContractFactory>await ethers.getContractFactory(artifact,signer);
  let contract: Contract = await upgrades.deployProxy(factory, params);

  return await contract.deployed();
};

export const upgrade = async (ethers: HardhatEthersHelpers, upgrades: any, artifact: string, address: string) => {
  const FEE_DATA = {
      maxFeePerGas: ethers.utils.parseUnits('6', 'gwei'),
      maxPriorityFeePerGas: ethers.utils.parseUnits('3', 'gwei'),
    };

    // Wrap the provider so we can override fee data.
    const provider = new ethers.providers.FallbackProvider([ethers.provider], 1);
    provider.getFeeData = async () => FEE_DATA;

    // Create the signer for the mnemonic, connected to the provider with hardcoded fee data
    const signer = new ethers.Wallet(process.env.PRIVATE_KEY).connect(provider);

    const factory: ContractFactory = <ContractFactory>await ethers.getContractFactory(artifact, signer);
    let contract: Contract = await upgrades.upgradeProxy(address, factory);
};
