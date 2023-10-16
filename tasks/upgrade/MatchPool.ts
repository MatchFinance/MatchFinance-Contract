import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

import { readAddressList, readArgs, storeArgs } from "../../scripts/contractAddress";
import { upgrade, getNetwork } from "../helpers";

task("upgrade:MatchPool", "Upgrade MatchPool contract")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();
    const addressList = readAddressList()[network];

    console.log("Upgrading...");

    await upgrade(ethers, upgrades, "MatchPool", addressList.MatchPool);

    console.log(`MatchPool upgraded on ${network}`);
  });

task("upgrade:RewardManager", "Upgrade Reward Manager contract")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();
    const addressList = readAddressList()[network];

    console.log("Upgrading...");

    await upgrade(ethers, upgrades, "RewardManager", addressList.RewardManager);

    console.log(`Reward Manager upgraded on ${network}`);
  });