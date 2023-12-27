import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { expect } from "chai";
import { ethers } from "hardhat";

import { MTokenStaking, MockERC20, RewardDistributor, RewardDistributor__factory, RewardManager } from "../types";

describe("Reward Distribution Test", function () {
  let dev: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;

  let mDistributor: RewardDistributor; // mesLBR staking distributor
  let vlDistributor: RewardDistributor; // vlMatch staking distributor

  let mesLBR: MockERC20;
  let vlMatch: MockERC20;

  let mStaking: MTokenStaking;

  let manager: RewardManager;

  before(async function () {
    [dev, user1, user2] = await ethers.getSigners();

    mDistributor = await (await ethers.getContractFactory("RewardDistributor")).deploy();
    vlDistributor = await (await ethers.getContractFactory("RewardDistributor")).deploy();

    mStaking = await (await ethers.getContractFactory("MTokenStaking")).deploy();

    mesLBR = await (await ethers.getContractFactory("MockERC20")).deploy();
    vlMatch = await (await ethers.getContractFactory("MockERC20")).deploy();

    manager = await (await ethers.getContractFactory("RewardManager")).deploy();
  });

  describe("mesLBR staking", function() {
    it("should be able to ")
  })
});
