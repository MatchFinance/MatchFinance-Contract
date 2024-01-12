import { BigNumber } from "@ethersproject/bignumber";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/dist/src/signer-with-address";
import { expect } from "chai";
import { ethers } from "hardhat";

import { deploy, deployUpgradeable, mintTokens, approveTokens, toWei } from "./utils";

export async function deployMPFixture() {
  const signers: SignerWithAddress[] = await ethers.getSigners();
  const admin: SignerWithAddress = signers[0];
  const bob: SignerWithAddress = signers[1];

  const lpOracle = await deploy("LPOracle", []);
  const lp = await deploy("LPToken", []);
  await mintTokens(lp, [admin.address, bob.address], [toWei("1000")]);

  const stETH = await deploy("stETHMock", []);
  const eUSD = await deploy("EUSDMock", [admin.address]);
  const configurator = await deploy("LybraConfigurator", [eUSD.address]);

  const mintPool = await deploy("LybraMintPool", [stETH.address, eUSD.address, configurator.address]);
  await eUSD.setMintVault(mintPool.address);

  const stakePool = await deploy("StakePool", [lp.address]);

  const mining = await deploy("MiningIncentive", [configurator.address, lpOracle.address, "0x0000000000000000000000000000000000000000"]);
  await configurator.setMining(mining.address);
  await mining.setPool(mintPool.address);

  const matchPool = await deployUpgradeable("MatchPool", [], true);
  await matchPool.setLybraLP(lp.address, lpOracle.address, stakePool.address);
  await matchPool.setLybraConfigurator(configurator.address);
  await matchPool.addMintPool(mintPool.address);
  await matchPool.setMonitor(admin.address);

  const manager = await deployUpgradeable("RewardManager", [matchPool.address]);
  await manager.setDlpRewardPool(stakePool.address);
  await manager.setMiningRewardPools(mining.address, eUSD.address);
  await manager.setMiningRewardShares(0, 0);
  await matchPool.setRewardManager(manager.address);

  await approveTokens(lp, [admin, bob], stakePool.address, [toWei("100000")]);
  await approveTokens(lp, [admin, bob], matchPool.address, [toWei("100000")]);
  await approveTokens(stETH, [admin], matchPool.address, [toWei("100000")]);
  await approveTokens(eUSD, [admin, bob], matchPool.address, [toWei("100000")]);

  return { matchPool, stakePool, mining, mintPool, stETH, manager, admin, bob };
}