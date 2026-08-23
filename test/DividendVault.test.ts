import { expect } from "chai";
import { ethers } from "hardhat";
import { DividendVault, MockERC20 } from "../typechain-types";

describe("DividendVault", function () {
  async function deployNativeVaultFixture(minHolding = 0n) {
    const [owner, processor, holderA, holderB, holderC] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const shareToken = await MockERC20.deploy("Share Token", "SHARE", 18) as MockERC20;

    const DividendVault = await ethers.getContractFactory("DividendVault");
    const vault = await DividendVault.deploy() as DividendVault;
    await vault.initialize(
      owner.address,
      await shareToken.getAddress(),
      ethers.ZeroAddress,
      true,
      minHolding,
      ethers.parseEther("30"),
      processor.address
    );

    await shareToken.mint(holderA.address, ethers.parseEther("100"));
    await shareToken.mint(holderB.address, ethers.parseEther("100"));

    const tokenAddress = await shareToken.getAddress();
    await ethers.provider.send("hardhat_setBalance", [
      tokenAddress,
      ethers.toBeHex(ethers.parseEther("1")),
    ]);
    const tokenSigner = await ethers.getImpersonatedSigner(tokenAddress);

    await vault.connect(tokenSigner).syncShare(holderA.address, ethers.parseEther("100"));
    await vault.connect(tokenSigner).syncShare(holderB.address, ethers.parseEther("100"));

    return { shareToken, vault, tokenSigner, processor, holderA, holderB, holderC };
  }

  it("allocates payment by current eligible shares", async function () {
    const { vault, tokenSigner, processor, holderA, holderB } = await deployNativeVaultFixture();

    await vault.connect(tokenSigner).createDividendEpoch(ethers.parseEther("1000"));
    await vault.connect(processor).notifyDividendPayment(
      ethers.parseEther("1000"),
      ethers.parseEther("30"),
      { value: ethers.parseEther("30") }
    );

    expect(await ethers.provider.getBalance(await vault.getAddress())).to.equal(ethers.parseEther("30"));
    expect(await vault.claimableDividendPayment()).to.equal(ethers.parseEther("30"));
    expect(await vault.pendingDividend(holderA.address)).to.equal(ethers.parseEther("15"));
    expect(await vault.pendingDividend(holderB.address)).to.equal(ethers.parseEther("15"));
    expect(await vault.totalDividendPerShare()).to.equal(ethers.parseEther("0.15"));

    await expect(vault.connect(processor).processAutoClaims())
      .to.emit(vault, "AutoClaimProcessed")
      .withArgs(processor.address, 2, 2, ethers.parseEther("30"), 0, 2);
    expect(await vault.claimableDividendPayment()).to.equal(0);
  });

  it("does not let a late holder share prior allocations", async function () {
    const { shareToken, vault, tokenSigner, processor, holderA, holderB, holderC } = await deployNativeVaultFixture();

    await vault.connect(tokenSigner).createDividendEpoch(ethers.parseEther("1000"));
    await vault.connect(processor).notifyDividendPayment(
      ethers.parseEther("1000"),
      ethers.parseEther("30"),
      { value: ethers.parseEther("30") }
    );

    await shareToken.mint(holderC.address, ethers.parseEther("100"));
    await vault.connect(tokenSigner).syncShare(holderC.address, ethers.parseEther("100"));

    expect(await vault.pendingDividend(holderA.address)).to.equal(ethers.parseEther("15"));
    expect(await vault.pendingDividend(holderB.address)).to.equal(ethers.parseEther("15"));
    expect(await vault.pendingDividend(holderC.address)).to.equal(0);

    await vault.connect(tokenSigner).createDividendEpoch(ethers.parseEther("1000"));
    await vault.connect(processor).notifyDividendPayment(
      ethers.parseEther("1000"),
      ethers.parseEther("30"),
      { value: ethers.parseEther("30") }
    );

    expect(await vault.pendingDividend(holderA.address)).to.equal(ethers.parseEther("25"));
    expect(await vault.pendingDividend(holderB.address)).to.equal(ethers.parseEther("25"));
    expect(await vault.pendingDividend(holderC.address)).to.equal(ethers.parseEther("10"));
  });

  it("preserves accrued claimable payment after a holder balance falls below eligibility", async function () {
    const { vault, tokenSigner, processor, holderA, holderB } = await deployNativeVaultFixture(ethers.parseEther("50"));

    await vault.connect(tokenSigner).createDividendEpoch(ethers.parseEther("1000"));
    await vault.connect(processor).notifyDividendPayment(
      ethers.parseEther("1000"),
      ethers.parseEther("30"),
      { value: ethers.parseEther("30") }
    );

    await vault.connect(tokenSigner).syncShare(holderA.address, ethers.parseEther("10"));

    expect(await vault.currentShare(holderA.address)).to.equal(0);
    expect(await vault.pendingDividend(holderA.address)).to.equal(ethers.parseEther("15"));

    await vault.connect(tokenSigner).createDividendEpoch(ethers.parseEther("1000"));
    await vault.connect(processor).notifyDividendPayment(
      ethers.parseEther("1000"),
      ethers.parseEther("10"),
      { value: ethers.parseEther("10") }
    );

    expect(await vault.pendingDividend(holderA.address)).to.equal(ethers.parseEther("15"));
    expect(await vault.pendingDividend(holderB.address)).to.equal(ethers.parseEther("25"));
  });

  it("preserves finalized and in-flight dividends when a holder is later excluded", async function () {
    const { vault, tokenSigner, processor, holderA, holderB } = await deployNativeVaultFixture();

    await vault.connect(tokenSigner).createDividendEpoch(ethers.parseEther("1000"));
    await vault.connect(processor).notifyDividendPayment(
      ethers.parseEther("1000"),
      ethers.parseEther("30"),
      { value: ethers.parseEther("30") }
    );

    await vault.connect(tokenSigner).createDividendEpoch(ethers.parseEther("1000"));
    await vault.setExcluded(holderA.address, true);

    expect(await vault.currentShare(holderA.address)).to.equal(0);
    expect(await vault.pendingDividend(holderA.address)).to.equal(ethers.parseEther("15"));

    await vault.connect(processor).notifyDividendPayment(
      ethers.parseEther("1000"),
      ethers.parseEther("10"),
      { value: ethers.parseEther("10") }
    );

    await vault.connect(tokenSigner).createDividendEpoch(ethers.parseEther("1000"));
    await vault.connect(processor).notifyDividendPayment(
      ethers.parseEther("1000"),
      ethers.parseEther("10"),
      { value: ethers.parseEther("10") }
    );

    expect(await vault.pendingDividend(holderA.address)).to.equal(ethers.parseEther("20"));
    expect(await vault.pendingDividend(holderB.address)).to.equal(ethers.parseEther("30"));

    await expect(vault.connect(holderA).claimDividend())
      .to.emit(vault, "DividendClaimed")
      .withArgs(holderA.address, ethers.parseEther("20"), 2, 3);
    expect(await vault.pendingDividend(holderA.address)).to.equal(0);
    await expect(vault.connect(holderA).claimDividend()).to.be.revertedWith("No dividend");
  });

  it("allocates pending epochs in bounded batches and preserves queued payment", async function () {
    const { vault, tokenSigner, processor, holderA, holderB } = await deployNativeVaultFixture();

    const epochCount = 50;
    const perEpochToken = ethers.parseEther("1");
    const totalPayment = ethers.parseEther("50");

    for (let i = 0; i < epochCount; i++) {
      await vault.connect(tokenSigner).createDividendEpoch(perEpochToken);
    }

    const tx = await vault.connect(processor).notifyDividendPayment(
      ethers.parseEther("50"),
      totalPayment,
      { value: totalPayment }
    );
    const receipt = await tx.wait();

    expect(receipt!.gasUsed).to.be.lt(5_000_000n);
    expect(await vault.lastFinalizedEpoch()).to.equal(20);
    expect(await vault.queuedDividendTokens()).to.equal(ethers.parseEther("30"));
    expect(await vault.queuedDividendPayment()).to.equal(ethers.parseEther("30"));

    await vault.processPendingDividends(20);
    expect(await vault.lastFinalizedEpoch()).to.equal(40);
    expect(await vault.queuedDividendTokens()).to.equal(ethers.parseEther("10"));
    expect(await vault.queuedDividendPayment()).to.equal(ethers.parseEther("10"));

    await vault.processPendingDividends(20);
    expect(await vault.lastFinalizedEpoch()).to.equal(50);
    expect(await vault.queuedDividendTokens()).to.equal(0);
    expect(await vault.queuedDividendPayment()).to.equal(0);
    expect(await vault.pendingDividend(holderA.address)).to.equal(ethers.parseEther("25"));
    expect(await vault.pendingDividend(holderB.address)).to.equal(ethers.parseEther("25"));
  });
});
