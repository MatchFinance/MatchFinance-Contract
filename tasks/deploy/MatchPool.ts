import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

import { readAddressList } from "../../scripts/contractAddress";
import { deployUpgradeable, getNetwork, writeUpgradeableDeployment } from "../helpers";

task("deploy:MatchPool", "Deploy MatchPool contract")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();

    console.log("Deploying...");

    const pool = await deployUpgradeable(ethers, upgrades, "MatchPool", []);

    console.log(`MatchPool deployed to: ${pool.address} on ${network}`);

    const implementation = await upgrades.erc1967.getImplementationAddress(pool.address);
    writeUpgradeableDeployment(network, "MatchPool", pool.address, implementation);
  });

task("deploy:RewardManager", "Deploy Reward Manager contract")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();
    const addressList = readAddressList()[network];

    console.log("Deploying...");

    const manager = await deployUpgradeable(ethers, upgrades, "RewardManager", [addressList.MatchPool]);

    console.log(`Reward Manager deployed to: ${manager.address} on ${network}`);

    const implementation = await upgrades.erc1967.getImplementationAddress(manager.address);
    writeUpgradeableDeployment(network, "RewardManager", manager.address, implementation);
  });