import { DeployFunction, ProxyOptions } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

import {
  readMTokenAddressList,
  readMTokenImplList,
  storeMTokenAddressList,
  storeMTokenImplList,
} from "../scripts/contractAddress";

// Deploy mesLBR

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre;
  const { deploy } = deployments;

  network.name = network.name == "hardhat" ? "localhost" : network.name;

  const { deployer } = await getNamedAccounts();

  console.log("deployer: ", deployer);

  const addressList = readMTokenAddressList();
  const implList = readMTokenImplList();

  const rewardManager = addressList[network.name].RewardManager;
  const mesLBR = addressList[network.name].mesLBR;
  const peUSD = addressList[network.name].peUSD;
  const altStablecoin = addressList[network.name].altStablecoin;

  const proxyOptions: ProxyOptions = {
    proxyContract: "OpenZeppelinTransparentProxy",
    execute: {
      init: {
        methodName: "initialize",
        args: [rewardManager, mesLBR, peUSD, altStablecoin],
      },
    },
  };

  const mTokenStaking = await deploy("MTokenStaking", {
    contract: "MTokenStaking",
    from: deployer,
    proxy: proxyOptions,
    args: [],
    log: true,
  });
  addressList[network.name].MTokenStaking = mTokenStaking.address;
  implList[network.name].MTokenStaking = mTokenStaking.implementation;

  storeMTokenAddressList(addressList);
  storeMTokenImplList(implList);
};

func.tags = ["MTokenStaking"];
export default func;
