import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

import { readAddressList } from "../scripts/contractAddress";
import { getNetwork } from "./helpers";

task("stakeLP")
  .setAction(async function (_, { ethers }) {
    const hre = require("hardhat");
    const network = getNetwork();
    const addressList = readAddressList()[network];

    const match = await ethers.getContractAt("MatchPool", addressList.MatchPool);
    const signer = (await ethers.getSigners())[0];

    console.log("Staking...");
    const amount = ethers.utils.parseUnits("0.41");
    try {
      await match.connect(signer).stakeLP(amount);
      console.log("Staked!");
    } catch (e) {
      console.log("\n", e);
    }
  });

task("withdrawLP")
  .setAction(async function (_, { ethers }) {
    const hre = require("hardhat");
    const network = getNetwork();
    const addressList = readAddressList()[network];

    const match = await ethers.getContractAt("MatchPool", addressList.MatchPool);
    const signer = (await ethers.getSigners())[0];

    console.log("Unstaking...");
    const amount = ethers.utils.parseUnits("0.41");
    try {
      await match.connect(signer).withdrawLP(amount);
      console.log("Unstaked!");
    } catch (e) {
      console.log("\n", e);
    }
  });

task("supplyETH")
  .setAction(async function (_, { ethers }) {
    const hre = require("hardhat");
    const network = getNetwork();
    const addressList = readAddressList()[network];

    const match = await ethers.getContractAt("MatchPool", addressList.MatchPool);
    const signer = (await ethers.getSigners())[0];

    console.log("Supplying...");
    const amount = ethers.utils.parseUnits("0.01");
    try {
      await match.connect(signer).supplyStETH(amount, {gasPrice: ethers.utils.parseUnits("20"), gasLimit: "400000"});
      console.log("Supplied!");
    } catch (e) {
      console.log("\n", e);
    }
  });

task("getCR")
  .setAction(async function (_, { ethers }) {
    const hre = require("hardhat");
    const network = getNetwork();
    const addressList = readAddressList()[network];

    const match = await ethers.getContractAt("MatchPool", addressList.MatchPool);
    const pool = await ethers.getContractAt("LybraMintPool", addressList.LybraMintPool);

    console.log(pool.getAssetPrice().call());
  });

