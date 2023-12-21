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

  const proxyOptions: ProxyOptions = {
    proxyContract: "OpenZeppelinTransparentProxy",
    execute: {
      init: {
        methodName: "initialize",
        args: ["mesLBR", "mesLBR"],
      },
    },
  };

  const mToken = await deploy("MToken", {
    contract: "MToken",
    from: deployer,
    proxy: proxyOptions,
    args: [],
    log: true,
  });
  addressList[network.name].mesLBR = mToken.address;
  implList[network.name].mesLBR = mToken.implementation;

  storeMTokenAddressList(addressList);
  storeMTokenImplList(implList);
};

func.tags = ["MesLBR"];
export default func;
