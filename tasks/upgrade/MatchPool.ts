import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

import { readAddressList, readArgs, storeArgs } from "../../scripts/contractAddress";
import { upgrade, getNetwork, validateUpgrade } from "../helpers";

task("upgrade:MatchPool", "Deploy new Match Pool implementation contract")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();
    const addressList = readAddressList()[network];

    console.log("Upgrading...");

    const res = await upgrade(ethers, upgrades, "MatchPool", addressList.MatchPool);

    console.log(`New Match Pool implementation deployed on ${network} at ${res}`);
  });

task("upgrade:RewardManager", "Deploy new Reward Manager implementation contract")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();
    const addressList = readAddressList()[network];

    console.log("Upgrading...");

    const res = await upgrade(ethers, upgrades, "RewardManager", addressList.RewardManager);

    console.log(`New Reward Manager implementation deployed on ${network} at ${res}`);
  });