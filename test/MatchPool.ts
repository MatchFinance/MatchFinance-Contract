import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

import { deployMPFixture } from "./MatchPool.fixture";
import { toWei, fromWei, mineBlocks, zeroAddress } from "./utils";

async function logPoolInfo(contract) {
  console.log("\nTotal dlp Staked: ", fromWei(await contract.totalStaked()));
  // console.log("Total stETH Supplied: ", fromWei(await contract.totalSupplied()));
  // console.log("Total stETH Deposited: ", fromWei(await contract.totalDeposited()));
  // console.log("Total eUSD Minted: ", fromWei(await contract.totalMinted()));
  // console.log("Total eUSD Borrowed: ", fromWei(await contract.totalBorrowed()));
}

async function checkCR(contract, ethPrice = toWei("1600")) {
  const vault = await contract.getMintPool();

  const deposited = await contract.totalDeposited(vault);
  const minted = await contract.totalMinted(vault);
  const cr = deposited.mul(ethPrice).div(minted);

  // Only log when CR is less than 200%
  if (cr.lt(toWei("2"))) console.log("Collateral ratio risk: ", cr);
}

function separator() {
  console.log("===================");
}

function log(amount) {
  console.log(fromWei(amount));
}

describe("Match Pool", function () {
  before(async function () {
    this.loadFixture = loadFixture;
  })

  beforeEach(async function () {
    const { 
      matchPool, manager,
      stakePool, mining, 
      mintPool, boost,
      esLBR, stETH,
      admin, bob 
    } = await this.loadFixture(deployMPFixture);

    this.matchPool = matchPool;
    this.stakePool = stakePool;
    this.mining = mining;
    this.mintPool = mintPool;
    this.stETH = stETH;
    this.manager = manager;
    this.esLBR = esLBR;
    this.boost = boost;
    this.admin = admin;
    this.bob = bob;

    await this.stakePool.connect(this.bob).stake(toWei("100"));
    await this.mintPool.connect(this.bob).depositEtherToMint(toWei("1000"), { value: toWei("2") })

    await this.matchPool.stakeLP(toWei("200"));
    await this.matchPool.supplyETH({ value: toWei("4.01") });
  });

  describe("Reward calculation", async function () {
    it("should be correct after minting", async function () {
      // Lybra updateReward() is called but Reward Manager lsdUpdateReward() is not
      await this.matchPool.monitorMint(toWei("200"));
      //< 0.7 * 4000/5000 = 0.56 >//
      await mineBlocks(1);
      //< 0.56 + 0.7 * 4200/5200 = 1.125 >//
      const lybraRecord = await this.mining.earned(this.matchPool.address);
      // As all mining reward goes to supplier
      // Admin reward (only supplier) = match pool reward
      const managerRecord = await this.manager.earned(this.admin.address, this.mining.address);
      log(managerRecord);
      expect(managerRecord).to.be.lte(lybraRecord);
      expect(managerRecord).to.be.closeTo(lybraRecord, 10);
    });

    it("should be correct after burning", async function () {
      // Lybra updateReward() is called but Reward Manager lsdUpdateReward() is not
      await this.matchPool.monitorBurn(toWei("200"));
      //< 0.7 * 4000/5000 = 0.56 >//
      await mineBlocks(1);
      //< 0.56 + 0.7 * 3800/4800 = 1.114 >//
      const lybraRecord = await this.mining.earned(this.matchPool.address);
      const managerRecord = await this.manager.earned(this.admin.address, this.mining.address);
      log(managerRecord);
      expect(managerRecord).to.be.lte(lybraRecord);
      expect(managerRecord).to.be.closeTo(lybraRecord, 10);
    });

    it("should be correct after depositing", async function () {
      await this.stETH.submit(this.admin.address, { value: toWei("10") });
      await this.stETH.transfer(this.matchPool.address, toWei("1"));
      // Lybra updateReward() is called but Reward Manager lsdUpdateReward() is not
      await this.matchPool.monitorDeposit(toWei("1"), toWei("200"));
      //< 3 * 0.7 * 4000/5000 = 1.68 >//
      await mineBlocks(1);
      //< 1.68 + 0.7 * 4200/5200 = 2.245 >//
      const lybraRecord = await this.mining.earned(this.matchPool.address);
      const managerRecord = await this.manager.earned(this.admin.address, this.mining.address);
      log(managerRecord);
      expect(managerRecord).to.be.lte(lybraRecord);
      expect(managerRecord).to.be.closeTo(lybraRecord, 10);
    });

    it("should be correct after claiming reward", async function () {
      await mineBlocks(10);
      //< 10 * 0.7 * 4000/5000 = 5.6 >//
      await this.manager.claimLybraRewards();
      //< 0.56 + 0.7 * 4000/5000 = 6.16 >//
      await mineBlocks(5);
      //< 6.16 + 5 * 0.56 = 8.96 >//
      const claimed = await this.esLBR.balanceOf(this.matchPool.address);
      const earnedAfterClaim = (await this.mining.earned(this.matchPool.address))
        .add(await this.stakePool.earned(this.matchPool.address));
      const managerRecord = (await this.manager.earned(this.admin.address, this.mining.address))
        .add(await this.manager.earned(this.admin.address, this.stakePool.address));
      log(await this.manager.earned(this.admin.address, this.mining.address));
      expect(managerRecord).to.be.lte(claimed.add(earnedAfterClaim));
      expect(managerRecord).to.be.closeTo(claimed.add(earnedAfterClaim), 10);
    });

    it("should be correct with changing boost multiplier", async function () {
      await mineBlocks(100);
      await this.manager.claimLybraRewards();
      await mineBlocks(8);
      // esLBR total supply = 124.56, ~1.2x
      await this.matchPool.boostReward(3, toWei("40"));
      //< 110 * 0.7 * 4000/5000 = 61.6 >//
      const oldBoost = await this.mining.getBoost(this.matchPool.address);
      const boostScale = toWei("100");
      await mineBlocks(10);
      // Boost reward ~= 10 * 0.56 * 1.2 - 10 * 0.56 ~= 1.12
      const normalReward = toWei("5.6")
      let boostReward = normalReward.mul(oldBoost).div(boostScale).sub(normalReward);
      let managerRecordBoost = (await this.manager.earnedSinceLastUpdate(this.mining.address))[2];
      log(managerRecordBoost);
      expect(managerRecordBoost).to.equal(boostReward);

      // ~1.3x
      await this.matchPool.boostReward(3, toWei("20"));
      const newBoost = await this.mining.getBoost(this.matchPool.address);
      await this.matchPool.supplyETH({ value: toWei("0.5") }); // invoke lsdUpdateReward()
      expect(await this.manager.pendingBoostReward()).to.be.closeTo(managerRecordBoost
        // Reward earned when calling boostReward()
        .add(toWei("0.56").mul(oldBoost).div(boostScale).sub(toWei("0.56")))
        // Reward earned when calling lsdUpdateReward()
        .add(toWei("0.56").mul(newBoost).div(boostScale).sub(toWei("0.56"))), 10
      );
      await mineBlocks(10);
      boostReward = normalReward.mul(newBoost).div(boostScale).sub(normalReward);
      managerRecordBoost = (await this.manager.earnedSinceLastUpdate(this.mining.address))[2];
      log(managerRecordBoost);
      expect(managerRecordBoost).to.equal(boostReward);
    });
  });

  // xit("stake LP", async function () {
  //   console.log("Reward ratio: ", fromWei(await this.stakePool.rewardRatio()));
  //   await this.stakePool.stake(toWei("100"));
  //   await mineBlocks(100);
  //   await this.matchPool.stakeLP(toWei("100"));
  //   await mineBlocks(100);
  //   console.log(await this.manager.earnedSinceLastUpdate(this.stakePool.address));
  //   await this.matchPool.connect(this.signers.bob).stakeLP(toWei("100"));
  //   await mineBlocks(100);
  //   console.log(await this.manager.earnedSinceLastUpdate(this.stakePool.address));
  //   await this.stakePool.stake(toWei("100"));
  //   await mineBlocks(100);
  //   console.log(await this.manager.earnedSinceLastUpdate(this.stakePool.address));
  //   await this.matchPool.claimRewards(1);
  // });

  // xcontext("supply ETH/stETH", async function () {
  //   beforeEach(async function () {
  //     // dLP value $86
  //     await this.matchPool.stakeLP(toWei("1"));
  //   });

  //   it("should succeed without triggering eUSD minting", async function () {
  //     const vault = await this.matchPool.getMintPool();

  //     // stETH total value: $640
  //     await this.matchPool.supplyStETH(toWei("0.2"));
  //     await this.matchPool.connect(this.signers.bob).supplyETH({ value: toWei("0.2") });
  //     expect(await this.matchPool.totalSupplied(vault)).to.equal(toWei("0.4"));
  //     expect(await this.matchPool.supplied(vault, this.signers.admin.address)).to.equal(toWei("0.2"));
  //     expect(await this.matchPool.supplied(vault, this.signers.bob.address)).to.equal(toWei("0.2"));
  //     // Does not change deposit/eUSD mint amount
  //     expect(await this.matchPool.totalDeposited(vault)).to.equal(0);
  //     expect(await this.matchPool.totalMinted(vault)).to.equal(0);
  //   });

  //   it("should succeed with eUSD minting triggered", async function () {
  //     const vault = await this.matchPool.getMintPool();

  //     // stETH total value: $1600
  //     await this.matchPool.supplyStETH(toWei("1"));
  //     // Rebalance changes deposit/eUSD mint amount
  //     // Mint amount given dlp value: 86 / 0.03 = 2866
  //     // Mint amount given collateral value: 1600 / 2 = 800
  //     expect(await this.matchPool.totalDeposited(vault)).to.equal(toWei("1"));
  //     expect(await this.matchPool.totalMinted(vault)).to.equal(toWei("800"));

  //     await mineBlocks(100);

  //     // stETH total value $6400
  //     await this.matchPool.supplyStETH(toWei("3"));
  //     await checkCR(this.matchPool);
  //     // Mint amount given dlp value: 86 / 0.03 - 800 = 2066
  //     // Mint amount given collateral value: 4800 / 2 = 2400
  //     // New deposit amount: (86 / 0.03 - 800) * 2 / 1600 = 2.583
  //     const newDeposit = (toWei("86").mul(100).div(3).sub(toWei("800"))).mul(2).div(1600).add(1);
  //     // Total minted: 800 + (86 / 0.03 - 800) = 86 / 0.03
  //     expect(await this.matchPool.totalDeposited(vault)).to.equal(newDeposit.add(toWei("1")));
  //     expect(await this.matchPool.totalMinted(vault)).to.equal(toWei("86").mul(100).div(3));
  //   });
  // });

  // xcontext("withdraw stETH", async function () {
  //   const adminStake = toWei("1");
  //   const adminSupply = toWei("2");
  //   const bobSupply = toWei("2");
  //   const totalSupplied = adminSupply.add(bobSupply);

  //   beforeEach(async function () {
  //     // dLP value $86
  //     await this.matchPool.stakeLP(adminStake);
  //     // stETH total value: $6400
  //     await this.matchPool.supplyStETH(adminSupply);
  //     await this.matchPool.connect(this.signers.bob).supplyETH({ value: bobSupply });
  //     // Total minted: 2866, Idle stETH: 4 - 3.583 = 0.417
  //   });

  //   let totalDeposited = (toWei("86").mul(100).div(3)).mul(2).div(1600).add(1);
  //   const withdrawAmount = toWei("0.5");

  //   it("should succeed without withdrawing from Lybra", async function () {
  //     const vault = await this.matchPool.getMintPool();

  //     // Withdraw less than idle stETH available
  //     const _withdrawAmount = withdrawAmount.sub(toWei("0.1"));
  //     await this.matchPool.withdrawStETH(_withdrawAmount);
  //     await checkCR(this.matchPool);
  //     // No withdrawal from Lybra
  //     expect(await this.matchPool.totalDeposited(vault)).to.equal(totalDeposited);
  //     expect(await this.matchPool.totalSupplied(vault)).to.equal(totalSupplied.sub(_withdrawAmount));
  //     expect(await this.matchPool.supplied(vault, this.signers.admin.address)).to.equal(adminSupply.sub(_withdrawAmount));
  //   });

  //   xcontext("should succeed with withdrawal from Lybra", async function () {
  //     it("and without burning eUSD", async function () {
  //       const vault = await this.matchPool.getMintPool();

  //       // Price increase leads to over-collateralization
  //       await this.mintPool.setEtherPrice(toWei("1700"));

  //       const totalMinted = await this.matchPool.totalMinted(vault);
  //       // Withdraw 0.5 - 0.417 = 0.083 from Lybra
  //       // Amount withdrawable without burning eUSD: (3.583 * 1700 / 2 - 2866) / 1700 = 0.105
  //       const withdrawFromLybra = withdrawAmount.sub(totalSupplied.sub(totalDeposited));
        
  //       await this.matchPool.withdrawStETH(withdrawAmount);
  //       await checkCR(this.matchPool, toWei("1700"));
  //       expect(await this.matchPool.totalDeposited(vault)).to.equal(totalDeposited.sub(withdrawFromLybra));
  //       expect(await this.matchPool.totalSupplied(vault)).to.equal(totalSupplied.sub(withdrawAmount));
  //       expect(await this.matchPool.supplied(vault, this.signers.admin.address)).to.equal(adminSupply.sub(withdrawAmount));
  //       expect(await this.matchPool.totalMinted(vault)).to.equal(totalMinted);
  //     });

  //     it("and with burning eUSD", async function () {
  //       const vault = await this.matchPool.getMintPool();

  //       // Withdraw 0.5 - 0.417 = 0.083 from Lybra
  //       const withdrawFromLybra = withdrawAmount.sub(totalSupplied.sub(totalDeposited));
  //       // New total deposit amount after withdrawal
  //       totalDeposited = totalDeposited.sub(withdrawFromLybra);
  //       // New total mint amount after burning
  //       const totalMinted = totalDeposited.mul(1600).div(2);
        
  //       await this.matchPool.withdrawStETH(withdrawAmount);
  //       await checkCR(this.matchPool);
  //       expect(await this.matchPool.totalDeposited(vault)).to.equal(totalDeposited);
  //       expect(await this.matchPool.totalSupplied(vault)).to.equal(totalSupplied.sub(withdrawAmount));
  //       expect(await this.matchPool.supplied(vault, this.signers.admin.address)).to.equal(adminSupply.sub(withdrawAmount));
  //       expect(await this.matchPool.totalMinted(vault)).to.equal(totalMinted);
  //     });
  //   });
  // });

  // xcontext("borrow eUSD", async function () {
  //   beforeEach(async function () {
  //     // dLP value $86
  //     await this.matchPool.stakeLP(toWei("1"));
  //     await this.matchPool.supplyStETH(toWei("1"));
  //     // Mint amount: 800 eUSD
  //   });

  //   it("should succeed", async function () {
  //     const vault = await this.matchPool.getMintPool();

  //     await this.matchPool.borrowEUSD(toWei("500"));
  //     expect(await this.matchPool.totalBorrowed(vault)).to.equal(toWei("500"));
  //     expect((await this.matchPool.borrowed(vault, this.signers.admin.address))[0]).to.equal(toWei("500"));

  //     // await this.matchPool.withdrawStETH(toWei("0.26"));
  //     // await this.matchPool.repayEUSD(this.signers.admin.address, toWei("500"));
  //     // expect(await this.matchPool.totalBorrowed(vault)).to.equal(0);
  //     // expect((await this.matchPool.borrowed(vault, this.signers.admin.address))[0]).to.equal(0);

  //     await this.matchPool.connect(this.signers.bob).supplyETH({ value: toWei("1") });
  //     await this.matchPool.borrowEUSD(toWei("150"));
  //     await this.matchPool.connect(this.signers.bob).borrowEUSD(toWei("600"));
  //     await this.matchPool.connect(this.signers.bob).borrowEUSD(toWei("50"));
  //     expect(await this.matchPool.totalBorrowed(vault)).to.equal(toWei("1300"));
  //     expect((await this.matchPool.borrowed(vault, this.signers.bob.address))[0]).to.equal(toWei("650"));
  //     expect((await this.matchPool.borrowed(vault, this.signers.bob.address))[1]).to.equal(toWei("650"));
  //     console.log(await this.matchPool.borrowed(vault, this.signers.bob.address));
  //     await this.matchPool.connect(this.signers.bob).repayEUSD(this.signers.bob.address, toWei("50"));
  //     expect((await this.matchPool.borrowed(vault, this.signers.bob.address))[0]).to.equal(toWei("600"));
  //     expect((await this.matchPool.borrowed(vault, this.signers.bob.address))[1]).to.equal(toWei("600"));
  //   });
  // });

  // xcontext("liquidate eUSD", async function () {
  //   it ("should succeed", async function () {

  //   });
  // });
});


