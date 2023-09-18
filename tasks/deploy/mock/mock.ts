import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

import { readAddressList } from "../../../scripts/contractAddress";
import { deploy, getNetwork, writeDeployment } from "../../helpers";

task("deploy:LPToken", "Deploy mock ETH-LBR LP token")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();

    console.log("Deploying...");

    const token = await deploy(ethers, "LPToken", []);

    console.log(`ETH-LBR LP token deployed to: ${token.address} on ${network}`);

    writeDeployment(network, "LPToken", token.address, []);
  });

task("deploy:LPOracle", "Deploy mock ETH-LBR LP token oracle")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();

    console.log("Deploying...");

    const oracle = await deploy(ethers, "LPOracle", []);

    console.log(`ETH-LBR LP token oracle deployed to: ${oracle.address} on ${network}`);

    writeDeployment(network, "LPOracle", oracle.address, []);
  });

task("deploy:StakePool", "Deploy mock Lybra stake pool contract")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();

    console.log("Deploying...");

    const args = [readAddressList()[network]["LPToken"]];

    const pool = await deploy(ethers, "StakePool", args);

    console.log(`StakePool deployed to: ${pool.address} on ${network}`);

    writeDeployment(network, "StakePool", pool.address, args);
  });

task("deploy:Configurator", "Deploy mock Lybra configurator contract")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();

    console.log("Deploying...");

    const configurator = await deploy(ethers, "LybraConfigurator", []);

    console.log(`Lybra configurator deployed to: ${configurator.address} on ${network}`);

    writeDeployment(network, "LybraConfigurator", configurator.address, []);
  });

task("deploy:MintPool", "Deploy mock Lybra stETH mint pool contract")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();

    console.log("Deploying...");

    const args = [
      readAddressList()[network]["stETHMock"],
      readAddressList()[network]["EUSDMock"]
    ];

    const pool = await deploy(ethers, "LybraMintPool", args);

    console.log(`Lybra stETH mint pool deployed to: ${pool.address} on ${network}`);

    writeDeployment(network, "LybraMintPool", pool.address, args);
  });

task("deploy:stETH", "Deploy mock stETH token")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();

    console.log("Deploying...");

    const token = await deploy(ethers, "stETHMock", []);

    console.log(`stETH token deployed to: ${token.address} on ${network}`);

    writeDeployment(network, "stETHMock", token.address, []);
  });

task("deploy:eUSD", "Deploy mock Lybra eUSD contract")
  .setAction(async function (_, { ethers, upgrades }) {
    const hre = require("hardhat");
    const network = getNetwork();

    console.log("Deploying...");

    // const args = [readAddressList()[network]["LPToken"]];
    const args = ["0x0000000000000000000000000000000000000000"];

    const token = await deploy(ethers, "EUSDMock", args);

    console.log(`eUSD deployed to: ${token.address} on ${network}`);

    writeDeployment(network, "EUSDMock", token.address, args);
  });



