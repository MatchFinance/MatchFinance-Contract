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

  const mesLBR = "0x0aF0E83D064f160376303ac67DD9A7971AF88d4C";
  const peUSD = "0xD585aaafA2B58b1CD75092B51ade9Fa4Ce52F247";
  const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

  const receiver = "0x3580386F5366614F0F52ED34C9bF66BA50a91461";

  const distributorAddress = await factory.distributors(mesLBR, receiver);
  console.log("distributorAddress: ", distributorAddress);

  //   const tx1 = await factory.createDistributor(peUSD, receiver);
  //   console.log(tx1.hash);
});

task("checkDistributor", "Check distributor info").setAction(async (_taskArgs, hre) => {
  const { network, ethers } = hre;
  const addressList = readMTokenAddressList();

  const factory = await ethers.getContractAt(
    "RewardDistributorFactory",
    addressList[network.name].RewardDistributorFactory,
  );

  const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const mesLBR = "0x0aF0E83D064f160376303ac67DD9A7971AF88d4C";
  const vlMatchStaking = "0x7D027083e55724A1082b8cDC51eE90781f41Ff14";

  const distributorAddress1 = await factory.distributors(mesLBR, vlMatchStaking);
  console.log("mesLBR - vlMatch Staking distributor:", distributorAddress1);

  const distributorAddress2 = await factory.distributors(USDC, vlMatchStaking);
  console.log("USDC - vlMatch Staking distributor:", distributorAddress2);
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
task("addMinter", async (_, hre) => {
  const { network, ethers } = hre;
  const addressList = readMTokenAddressList();

  const mToken = await ethers.getContractAt("MToken", addressList[network.name].mesLBR);
  const tx1 = await mToken.addMinter(addressList[network.name].RewardManager);
  console.log(tx1.hash);
});
task("setRewardSpeed", async (_, hre) => {
  const { network, ethers } = hre;
  const addressList = readMTokenAddressList();

  const factory = await ethers.getContractAt(
    "RewardDistributorFactory",
    addressList[network.name].RewardDistributorFactory,
  );

  const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const mesLBR = "0x0aF0E83D064f160376303ac67DD9A7971AF88d4C";
  const vlMatchStaking = "0x7D027083e55724A1082b8cDC51eE90781f41Ff14";

  const distributor_USDC = "0x0F6362a9D06976FB0D69922758200c886E9e5C0e";
  const distributor_mesLBR = "0xA93AF92e800581e83207491F477Dc78AF196EC1B";

  const rewardSpeed = ethers.utils.parseUnits("0.00248", 18); // 1500 / week
  console.log("rewardSpeed: ", rewardSpeed.toString());

  const tx = await factory.setRewardSpeed(mesLBR, vlMatchStaking, rewardSpeed);
  console.log(tx.hash);
});

task("mintMesLBR", async (_, hre) => {
  const { network, ethers } = hre;
  const addressList = readMTokenAddressList();

  const [dev] = await ethers.getSigners();

  const mToken = await ethers.getContractAt("MToken", addressList[network.name].mesLBR);

  const isMinter = await mToken.isMinter(dev.address);
  console.log("isMinter: ", isMinter);

  

  const bal = await mToken.balanceOf("0x7D027083e55724A1082b8cDC51eE90781f41Ff14");
  console.log("bal: ", ethers.utils.formatEther(bal));



  // const tx = await mToken.addMinter(dev.address);
  // console.log(tx.hash);

  //   const tx1 = await mToken.mint("0x41869771a094bA7Ee2f61AfEcfaE82f6A2e04189", ethers.utils.parseUnits("1", 18));
  //   console.log(tx1.hash);
});
