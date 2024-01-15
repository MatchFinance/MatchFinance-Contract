import { task } from "hardhat/config";

import { readMTokenAddressList } from "../scripts/contractAddress";

const TGE = 1705327200;

task("createDistributor", "Create new reward distributor").setAction(async (_taskArgs, hre) => {
  const { network, ethers } = hre;
  const addressList = readMTokenAddressList();

  const factory = await ethers.getContractAt(
    "RewardDistributorFactory",
    addressList[network.name].RewardDistributorFactory,
  );

  const rewardToken = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const receiver = "0x7D027083e55724A1082b8cDC51eE90781f41Ff14";

  const tx1 = await factory.createDistributor(rewardToken, receiver);
  console.log(tx1.hash);
});

task("checkDistributor", "Check distributor info").setAction(async (_taskArgs, hre) => {
  const { network, ethers } = hre;
  const addressList = readMTokenAddressList();

  const factory = await ethers.getContractAt(
    "RewardDistributorFactory",
    addressList[network.name].RewardDistributorFactory,
  );

  const rewardToken = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const receiver = "0x7D027083e55724A1082b8cDC51eE90781f41Ff14";

  const distributorAddress = await factory.distributors(rewardToken, receiver);
  console.log(distributorAddress);
});
task("setFactoryInMStaking").setAction(async (_taskArgs, hre) => {
  const { network, ethers } = hre;
  const addressList = readMTokenAddressList();

  const factory = addressList[network.name].RewardDistributorFactory;
  console.log("factory: ", factory);

  const mStaking = await ethers.getContractAt("MTokenStaking", addressList[network.name].MTokenStaking);

  const tx1 = await mStaking.setRewardDistributorFactory(factory);
  console.log(tx1.hash);
});
