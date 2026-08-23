import { expect } from "chai";
import { ethers } from "hardhat";
import {
  deployV4Fixture,
  createToken,
  fillCurveNative,
  fillCurveERC20,
  graduate,
  swapExactIn,
  poolKeyFor,
  V4Fixture,
  ZERO_TAX,
  DEAD_ADDRESS,
} from "./helpers/v4";

// ============================================================
// V4Graduation.test.ts — 毕业进入 Uniswap V4 池
//   - native / ERC20 池毕业闭环
//   - 开盘价与曲线收盘价一致
//   - 头寸锁入 locker，池注册 hook/settler
//   - 抢跑 initialize 防御
//   - 可追加 ERC20 池
// ============================================================

describe("V4 Graduation", function () {
  let fx: V4Fixture;
  let user: any;
  let user2: any;

  beforeEach(async function () {
    fx = await deployV4Fixture();
    const signers = await ethers.getSigners();
    user = signers[3];
    user2 = signers[4];
  });

  function expectedSqrtPrice(amount0: bigint, amount1: bigint): bigint {
    // sqrt(amount1 * 2^192 / amount0)
    const ratio = (amount1 << 192n) / amount0;
    let x = ratio;
    let y = (x + 1n) / 2n;
    while (y < x) {
      x = y;
      y = (x + ratio / x) / 2n;
    }
    return x;
  }

  describe("Native OKB pool graduation", function () {
    it("graduates into a V4 pool at the curve closing price with a locked full-range position", async function () {
      const token = await createToken(fx, user, 0);
      const tokenAddress = await token.getAddress();
      const launchConfig = await fx.launchpad.tokenLaunchConfigs(tokenAddress);
      expect(launchConfig.launchTarget).to.equal(ethers.parseEther("100"));
      expect(launchConfig.launchFee).to.equal(ethers.parseEther("5"));

      await fillCurveNative(fx, user, tokenAddress);
      expect(await fx.launchpad.getTokenState(tokenAddress)).to.equal(2);

      const vaultBalanceBefore = await ethers.provider.getBalance(await fx.platformVault.getAddress());
      await graduate(fx, tokenAddress);

      // Token state
      expect(await fx.launchpad.getTokenState(tokenAddress)).to.equal(3);
      expect(await token.graduated()).to.equal(true);
      expect(await token.transferMode()).to.equal(0);
      const poolId = await token.poolId();
      expect(poolId).to.not.equal(ethers.ZeroHash);

      // Position locked in the locker
      const [positionTokenId, exists] = await fx.locker.positionOf(tokenAddress);
      expect(exists).to.equal(true);
      expect(await fx.positionManager.ownerOf(positionTokenId)).to.equal(await fx.locker.getAddress());
      expect(await fx.positionManager.subscriber(positionTokenId)).to.equal(await fx.locker.getAddress());
      expect(await fx.positionManager.getPositionLiquidity(positionTokenId)).to.be.gt(0n);

      // Pool priced at the bonding-curve closing price:
      // 200M tokens vs 100 OKB (native = currency0)
      const tokenForDex = ethers.parseEther("200000000");
      const paymentLaunched = ethers.parseEther("100");
      const [sqrtPriceX96] = await fx.stateView.getSlot0(poolId);
      const expected = expectedSqrtPrice(paymentLaunched, tokenForDex);
      const diff = sqrtPriceX96 > expected ? sqrtPriceX96 - expected : expected - sqrtPriceX96;
      expect(diff).to.be.lte(expected / 1_000_000n); // ≤ 0.0001%

      // Registered with hook and settler
      const info = await fx.hook.poolTaxInfo(poolId);
      expect(info.token).to.equal(tokenAddress);
      const state = await fx.settler.tokenState(tokenAddress);
      expect(state.registered).to.equal(true);
      const reflowState = await fx.settler.reflowState(tokenAddress);
      expect(reflowState.maxReflowPayment).to.equal(ethers.parseEther("2"));

      // Platform vault received the 5% launch fee (plus any dust surplus)
      const vaultBalanceAfter = await ethers.provider.getBalance(await fx.platformVault.getAddress());
      expect(vaultBalanceAfter - vaultBalanceBefore).to.be.gte(ethers.parseEther("5"));

      // PoolManager holds the seeded tokens and must not earn dividends
      expect(await token.isExcludedFromDividend(await fx.poolManager.getAddress())).to.equal(true);
      expect(await token.balanceOf(await fx.poolManager.getAddress())).to.be.gt(0n);

      // Explorer-facing ownership is permanently assigned to the canonical burn address.
      expect(await token.owner()).to.equal(DEAD_ADDRESS);
    });

    it("supports post-graduation buy and sell through the pool", async function () {
      const token = await createToken(fx, user, 0);
      const tokenAddress = await token.getAddress();
      await fillCurveNative(fx, user, tokenAddress);
      await graduate(fx, tokenAddress);

      const key = await poolKeyFor(fx, tokenAddress);

      // Buy: native (currency0) -> token (currency1)
      const balanceBefore = await token.balanceOf(user2.address);
      await swapExactIn(fx, user2, key, true, ethers.parseEther("1"), true);
      const bought = (await token.balanceOf(user2.address)) - balanceBefore;
      expect(bought).to.be.gt(0n);

      // Sell: token -> native
      await token.connect(user2).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      const nativeBefore = await ethers.provider.getBalance(user2.address);
      await swapExactIn(fx, user2, key, false, bought / 2n, false);
      const nativeAfter = await ethers.provider.getBalance(user2.address);
      expect(nativeAfter).to.be.gt(nativeBefore - ethers.parseEther("0.01")); // received > gas cost
    });

    it("only the launcher or an authorized executor can graduate", async function () {
      const token = await createToken(fx, user, 0);
      const tokenAddress = await token.getAddress();
      await fillCurveNative(fx, user, tokenAddress);

      await expect(fx.launchpad.connect(user).launchToDEXOwner(tokenAddress)).to.be.revertedWith("Only launcher");
    });
  });

  describe("ERC20 pool graduation", function () {
    it("graduates an ERC20-paid token and prices the pool correctly", async function () {
      const token = await createToken(fx, user, 1);
      const tokenAddress = await token.getAddress();
      const launchConfig = await fx.launchpad.tokenLaunchConfigs(tokenAddress);
      expect(launchConfig.launchTarget).to.equal(ethers.parseEther("80"));
      expect(launchConfig.launchFee).to.equal(ethers.parseEther("4"));

      await fillCurveERC20(fx, user, tokenAddress);
      expect(await fx.launchpad.getTokenState(tokenAddress)).to.equal(2);

      await graduate(fx, tokenAddress);
      expect(await token.graduated()).to.equal(true);

      const poolId = await token.poolId();
      const key = await poolKeyFor(fx, tokenAddress);
      const wnvdaxAddress = await fx.wnvdax.getAddress();

      // Currency ordering is by address
      const [c0, c1] =
        wnvdaxAddress.toLowerCase() < tokenAddress.toLowerCase()
          ? [wnvdaxAddress, tokenAddress]
          : [tokenAddress, wnvdaxAddress];
      expect(key.currency0.toLowerCase()).to.equal(c0.toLowerCase());
      expect(key.currency1.toLowerCase()).to.equal(c1.toLowerCase());

      // Price check: 200M tokens vs 80 wNVDAx
      const tokenForDex = ethers.parseEther("200000000");
      const paymentLaunched = ethers.parseEther("80");
      const amount0 = key.currency0.toLowerCase() === tokenAddress.toLowerCase() ? tokenForDex : paymentLaunched;
      const amount1 = key.currency0.toLowerCase() === tokenAddress.toLowerCase() ? paymentLaunched : tokenForDex;
      const [sqrtPriceX96] = await fx.stateView.getSlot0(poolId);
      const expected = expectedSqrtPrice(amount0, amount1);
      const diff = sqrtPriceX96 > expected ? sqrtPriceX96 - expected : expected - sqrtPriceX96;
      expect(diff).to.be.lte(expected / 1_000_000n);

      // Position locked
      const [positionTokenId, exists] = await fx.locker.positionOf(tokenAddress);
      expect(exists).to.equal(true);
      expect(await fx.positionManager.ownerOf(positionTokenId)).to.equal(await fx.locker.getAddress());
    });
  });

  describe("Front-run initialization defense", function () {
    it("rejects attacker initialization and lets the venue create the canonical pool", async function () {
      const token = await createToken(fx, user, 0);
      const tokenAddress = await token.getAddress();
      await fillCurveNative(fx, user, tokenAddress);

      const key = await poolKeyFor(fx, tokenAddress);
      const wrongSqrtPrice = 2n ** 96n; // price = 1, far from the real target
      await expect(fx.poolManager.connect(user2).initialize(key, wrongSqrtPrice)).to.be.reverted;

      await graduate(fx, tokenAddress);

      const poolId = await token.poolId();
      const [sqrtPriceX96] = await fx.stateView.getSlot0(poolId);
      const expected = expectedSqrtPrice(ethers.parseEther("100"), ethers.parseEther("200000000"));
      const diff = sqrtPriceX96 > expected ? sqrtPriceX96 - expected : expected - sqrtPriceX96;
      expect(diff).to.be.lte(expected / 1_000_000n);

      const [, exists] = await fx.locker.positionOf(tokenAddress);
      expect(exists).to.equal(true);
    });

    it("rejects attacker initialization even when the proposed price is correct", async function () {
      const token = await createToken(fx, user, 0);
      const tokenAddress = await token.getAddress();
      await fillCurveNative(fx, user, tokenAddress);

      const key = await poolKeyFor(fx, tokenAddress);
      const target = expectedSqrtPrice(ethers.parseEther("100"), ethers.parseEther("200000000"));
      await expect(fx.poolManager.connect(user2).initialize(key, target)).to.be.reverted;

      await graduate(fx, tokenAddress);
      expect(await token.graduated()).to.equal(true);
    });
  });

  describe("Addable ERC20 pools", function () {
    it("assigns sequential pool ids and rejects non-owner additions", async function () {
      expect(await fx.launchpad.poolCount()).to.equal(2);

      const newPayment = await (await ethers.getContractFactory("MockERC20")).deploy("Wrapped SPCXx", "wSPCXx", 18);
      await expect(
        fx.launchpad
          .connect(user)
          .addErc20Pool(await newPayment.getAddress(), ethers.parseEther("120"), ethers.parseEther("1"), ethers.parseEther("2"), 1_000_000_000n, ethers.parseEther("1"))
      ).to.be.revertedWith("Not Owner");

      await fx.launchpad.addErc20Pool(
        await newPayment.getAddress(),
        ethers.parseEther("120"),
        ethers.parseEther("1"),
        ethers.parseEther("2"),
        1_000_000_000n,
        ethers.parseEther("1")
      );
      expect(await fx.launchpad.poolCount()).to.equal(3);
      expect(await fx.launchpad.paymentTokenAddresses(2)).to.equal(await newPayment.getAddress());

      // Duplicate payment token rejected
      await expect(
        fx.launchpad.addErc20Pool(await newPayment.getAddress(), 1n, 1n, 2n, 1n, 1n)
      ).to.be.revertedWith("Pool exists");
    });

    it("rejects creation on an unconfigured pool type", async function () {
      await expect(
        fx.launchpad.connect(user).createAndInitPurchase("X", "X", 1, ZERO_TAX, 5, 0)
      ).to.be.revertedWith("Invalid pool type");
    });

    it("keeps existing tokens on their creation-time snapshot when pool config changes", async function () {
      const token = await createToken(fx, user, 0);
      const tokenAddress = await token.getAddress();
      const configBefore = await fx.launchpad.tokenLaunchConfigs(tokenAddress);

      await fx.launchpad.setPoolLaunchTarget(0, ethers.parseEther("500"));

      const configAfter = await fx.launchpad.tokenLaunchConfigs(tokenAddress);
      expect(configAfter.launchTarget).to.equal(configBefore.launchTarget);

      // New pool config applies only to newly created tokens.
      const token2 = await createToken(fx, user, 0);
      const config2 = await fx.launchpad.tokenLaunchConfigs(await token2.getAddress());
      expect(config2.launchTarget).to.equal(ethers.parseEther("500"));
    });

    it("a token created on a later-added pool completes the full lifecycle", async function () {
      const newPayment = await (await ethers.getContractFactory("MockERC20")).deploy("Wrapped TSLAx", "wTSLAx", 18);
      await fx.launchpad.addErc20Pool(
        await newPayment.getAddress(),
        ethers.parseEther("50"),
        ethers.parseEther("1"),
        ethers.parseEther("2"),
        1_000_000_000n,
        ethers.parseEther("1")
      );

      const tx = await fx.launchpad
        .connect(user)
        .createAndInitPurchase("Late Pool", "LATE", 42, ZERO_TAX, 2, 0);
      await tx.wait();
      const count = await fx.launchpad.tokenCount();
      const tokenAddress = await fx.launchpad.tokenAddress(count - 1n);
      const token = await ethers.getContractAt("OkMemeToken", tokenAddress);
      expect(await token.paymentToken()).to.equal(await newPayment.getAddress());

      // Fill and graduate on the new pool
      const config = await fx.launchpad.tokenLaunchConfigs(tokenAddress);
      const pool = await fx.launchpad.virtualPools(tokenAddress);
      const remaining: bigint = BigInt(config.launchPaymentReserve) - BigInt(pool.paymentReserve);
      const paymentIn = (remaining * 10_000n) / 9_900n + ethers.parseEther("1");
      await newPayment.mint(user.address, paymentIn);
      await newPayment.connect(user).approve(await fx.launchpad.getAddress(), paymentIn);
      await fx.launchpad.connect(user).purchaseTokenERC20(tokenAddress, paymentIn, 0);

      await graduate(fx, tokenAddress);
      expect(await token.graduated()).to.equal(true);
    });
  });
});
