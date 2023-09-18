import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

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