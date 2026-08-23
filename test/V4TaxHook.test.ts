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
  DEAD_ADDRESS,
} from "./helpers/v4";

// ============================================================
// V4TaxHook.test.ts — 共享税务 hook 与 TaxSettler
//   - 买入：payment 三腿入 settler，token 输出烧毁腿
//   - 卖出：token 输入烧毁腿，payment 输出三腿 + 结算触发
//   - exact-output 拒绝 / 免税名单 / 零税代币
//   - 分红 epoch 与手动领取
//   - 买回桶回流加深锁仓头寸
// ============================================================

describe("V4 Tax Hook & Settler", function () {
  const TAX = {
    marketingFee: 100, // 1%
    holderDividendFee: 200, // 2%
    buybackFee: 100, // 1%
    burnFee: 100, // 1%
    marketingWallet: "", // filled in beforeEach
    minHoldingForDividend: ethers.parseEther("1000"),
  };

  let fx: V4Fixture;
  let user: any;
  let trader: any;
  let marketing: any;

  beforeEach(async function () {
    fx = await deployV4Fixture();
    const signers = await ethers.getSigners();
    user = signers[3];
    trader = signers[4];
    marketing = signers[5];
    TAX.marketingWallet = marketing.address;
  });

  async function setupGraduatedTaxedToken(poolType = 0, tax = TAX) {
    const token = await createToken(fx, user, poolType, tax, "Taxed Meme", "TAXED");
    const tokenAddress = await token.getAddress();
    if (poolType === 0) {
      await fillCurveNative(fx, user, tokenAddress);
    } else {
      await fillCurveERC20(fx, user, tokenAddress);
    }
    await graduate(fx, tokenAddress);
    const key = await poolKeyFor(fx, tokenAddress);
    return { token, tokenAddress, key };
  }

  async function reflow(tokenAddress: string, caller = trader) {
    return fx.settler.connect(caller).reflow(tokenAddress);
  }

  describe("Buy path (payment in, token out)", function () {
    it("collects the payment legs into settler buckets and burns the token leg", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();

      const amountIn = ethers.parseEther("10");
      const settlerBalBefore = await ethers.provider.getBalance(await fx.settler.getAddress());
      const deadBefore = await token.balanceOf(DEAD_ADDRESS); // graduation dust already burned
      await swapExactIn(fx, trader, key, true, amountIn, true);

      // Buckets: 1% marketing + 2% dividend + 1% buyback of the input
      const state = await fx.settler.tokenState(tokenAddress);
      expect(state.marketingBucket).to.equal(amountIn / 100n);
      expect(state.dividendBucket).to.equal((amountIn * 2n) / 100n);
      expect(state.liquidityBucket).to.equal(amountIn / 100n);

      // Settler actually holds the native payment
      const settlerBalAfter = await ethers.provider.getBalance(await fx.settler.getAddress());
      expect(settlerBalAfter - settlerBalBefore).to.equal((amountIn * 4n) / 100n);

      // Burn leg: dead receives 1% of the gross token output (trader keeps 99%)
      const burned = (await token.balanceOf(DEAD_ADDRESS)) - deadBefore;
      const traderBalance = await token.balanceOf(trader.address);
      expect(burned).to.be.gt(0n);
      expect(burned).to.be.closeTo(traderBalance / 99n, ethers.parseEther("1"));
    });

    it("does not tax an exempt sender", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();

      const exemptRouter = await (
        await ethers.getContractFactory("PoolSwapTest")
      ).deploy(await fx.poolManager.getAddress());
      await fx.hook.setSwapExempt(await exemptRouter.getAddress(), true);

      const deadBefore = await token.balanceOf(DEAD_ADDRESS);
      const params = {
        zeroForOne: true,
        amountSpecified: -ethers.parseEther("1"),
        sqrtPriceLimitX96: 4295128740n,
      };
      await exemptRouter
        .connect(trader)
        .swap(key, params, { takeClaims: false, settleUsingBurn: false }, "0x", {
          value: ethers.parseEther("1"),
        });

      const state = await fx.settler.tokenState(tokenAddress);
      expect(state.marketingBucket).to.equal(0n);
      expect(await token.balanceOf(DEAD_ADDRESS)).to.equal(deadBefore);
    });

    it("leaves a zero-tax token completely untaxed", async function () {
      const token = await createToken(fx, user, 0);
      const tokenAddress = await token.getAddress();
      await fillCurveNative(fx, user, tokenAddress);
      await graduate(fx, tokenAddress);
      const key = await poolKeyFor(fx, tokenAddress);

      const deadBefore = await token.balanceOf(DEAD_ADDRESS); // graduation dust
      await swapExactIn(fx, trader, key, true, ethers.parseEther("5"), true);

      const state = await fx.settler.tokenState(tokenAddress);
      expect(state.marketingBucket).to.equal(0n);
      expect(state.dividendBucket).to.equal(0n);
      expect(state.liquidityBucket).to.equal(0n);
      expect(await token.balanceOf(DEAD_ADDRESS)).to.equal(deadBefore);
    });

    it("does not charge the dividend leg when no holder is eligible", async function () {
      const noEligibleTax = {
        ...TAX,
        minHoldingForDividend: ethers.parseEther("2000000000"),
      };
      const token = await createToken(fx, user, 0, noEligibleTax, "No Eligible", "NONE");
      const tokenAddress = await token.getAddress();
      await fillCurveNative(fx, user, tokenAddress);
      await graduate(fx, tokenAddress);
      const key = await poolKeyFor(fx, tokenAddress);
      const before = await ethers.provider.getBalance(await fx.settler.getAddress());

      const amountIn = ethers.parseEther("10");
      await swapExactIn(fx, trader, key, true, amountIn, true);
      const state = await fx.settler.tokenState(tokenAddress);

      expect(state.dividendBucket).to.equal(0n);
      expect((await ethers.provider.getBalance(await fx.settler.getAddress())) - before).to.equal(amountIn * 2n / 100n);
    });
  });

  describe("Sell path (token in, payment out)", function () {
    it("burns the token input leg and collects payment legs from the output", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();

      // Trader acquires tokens first (small buy keeps buckets under the trigger)
      await swapExactIn(fx, trader, key, true, ethers.parseEther("5"), true);
      const holdings = await token.balanceOf(trader.address);
      const deadBefore = await token.balanceOf(DEAD_ADDRESS);
      const stateBefore = await fx.settler.tokenState(tokenAddress);

      const sellAmount = holdings / 2n;
      await token.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      const sellReceipt = await (await swapExactIn(fx, trader, key, false, sellAmount, false)).wait();

      // 1% of the token input burned
      const deadAfter = await token.balanceOf(DEAD_ADDRESS);
      const taxEvent = sellReceipt!.logs
        .map((log: any) => {
          try { return fx.hook.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "SwapTaxCollected");
      expect(taxEvent!.args.burnAmount).to.equal(sellAmount / 100n);
      // Reflow inventory is never burn inventory. The only dead-address delta
      // in this sell is the independently configured burn leg.
      expect(deadAfter - deadBefore).to.equal(sellAmount / 100n);

      // Marketing/dividend legs remain in their buckets below the settlement
      // trigger. The buyback leg is collected too, then immediately consumed
      // by the sell-triggered reflow covered by its event/accounting tests.
      const stateAfter = await fx.settler.tokenState(tokenAddress);
      expect(stateAfter.marketingBucket).to.be.gt(stateBefore.marketingBucket);
      expect(stateAfter.dividendBucket).to.be.gt(stateBefore.dividendBucket);
      const reflowEvent = sellReceipt!.logs
        .map((log: any) => {
          try { return fx.settler.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "LiquidityReflowExecuted");
      expect(reflowEvent).to.not.equal(undefined);
      const marketingDelta: bigint = BigInt(stateAfter.marketingBucket) - BigInt(stateBefore.marketingBucket);
      const dividendDelta: bigint = BigInt(stateAfter.dividendBucket) - BigInt(stateBefore.dividendBucket);
      expect(dividendDelta).to.be.closeTo(marketingDelta * 2n, 2n);
    });

    it("settles marketing and dividends once the trigger is reached on a sell", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();

      // Big buy pushes marketing+dividend buckets past the 1 OKB trigger
      await swapExactIn(fx, trader, key, true, ethers.parseEther("40"), true);
      const stateBefore = await fx.settler.tokenState(tokenAddress);
      expect(stateBefore.marketingBucket + stateBefore.dividendBucket).to.be.gte(ethers.parseEther("1"));

      const marketingBalBefore = await ethers.provider.getBalance(marketing.address);
      const dividendVaultAddress = await token.dividendVault();
      const vaultBalBefore = await ethers.provider.getBalance(dividendVaultAddress);

      // Any taxed sell triggers settlement
      await token.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      const sellReceipt = await (await swapExactIn(
        fx,
        trader,
        key,
        false,
        ethers.parseEther("1000"),
        false,
      )).wait();

      const parsedSettlerLogs = sellReceipt!.logs.map((log: any) => {
        try { return fx.settler.interface.parseLog(log); } catch { return null; }
      });
      const recorded = parsedSettlerLogs.find((event: any) => event?.name === "TaxRecorded");
      const settled = parsedSettlerLogs.find((event: any) => event?.name === "SettlementExecuted");
      expect(recorded).to.not.equal(undefined);
      expect(settled).to.not.equal(undefined);
      const expectedMarketing = stateBefore.marketingBucket + recorded!.args.marketingAmount;
      const expectedDividend = stateBefore.dividendBucket + recorded!.args.dividendAmount;
      expect(settled!.args.marketingPayment).to.equal(expectedMarketing);
      expect(settled!.args.dividendPayment).to.equal(expectedDividend);

      const stateAfter = await fx.settler.tokenState(tokenAddress);
      expect(stateAfter.marketingBucket).to.equal(0n);
      expect(stateAfter.dividendBucket).to.equal(0n);

      // Marketing wallet paid in native OKB
      const marketingBalAfter = await ethers.provider.getBalance(marketing.address);
      expect(marketingBalAfter - marketingBalBefore).to.equal(expectedMarketing);

      // Dividend vault funded
      const vaultBalAfter = await ethers.provider.getBalance(dividendVaultAddress);
      const dividendVault = await ethers.getContractAt("DividendVault", dividendVaultAddress);
      const dividendClaims = sellReceipt!.logs
        .filter((log: any) => log.address.toLowerCase() === dividendVaultAddress.toLowerCase())
        .map((log: any) => {
          try { return dividendVault.interface.parseLog(log); } catch { return null; }
        })
        .filter((event: any) => event?.name === "DividendClaimed")
        .reduce((sum: bigint, event: any) => sum + BigInt(event!.args.amount), 0n);
      expect(vaultBalAfter + dividendClaims - vaultBalBefore).to.equal(expectedDividend);
    });

    it("lets an eligible holder claim dividends after settlement", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();

      await swapExactIn(fx, trader, key, true, ethers.parseEther("40"), true);
      await token.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      await swapExactIn(fx, trader, key, false, ethers.parseEther("1000"), false);

      const vault = await ethers.getContractAt("DividendVault", await token.dividendVault());

      // The curve buyer (user) holds 800M tokens and is dividend-eligible
      const pendingUser = await vault.pendingDividend(user.address);
      expect(pendingUser).to.be.gt(0n);

      const balBefore = await ethers.provider.getBalance(user.address);
      const tx = await vault.connect(user).claimDividend();
      const receipt = await tx.wait();
      const gas = receipt!.gasUsed * receipt!.gasPrice;
      const balAfter = await ethers.provider.getBalance(user.address);
      expect(balAfter + gas - balBefore).to.equal(pendingUser);
      expect(await vault.pendingDividend(user.address)).to.equal(0n);
    });

    it("locks dividend entitlement before the taxed buy changes balances", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();
      const vault = await ethers.getContractAt("DividendVault", await token.dividendVault());

      await swapExactIn(fx, trader, key, true, ethers.parseEther("40"), true);
      expect(await vault.currentEpoch()).to.be.gt(0n);
      await fx.settler.distribute(tokenAddress);

      expect(await vault.pendingDividend(user.address)).to.be.gt(0n);
      expect(await vault.pendingDividend(trader.address)).to.equal(0n);
    });

    it("continues dividend settlement when a native marketing wallet rejects payment", async function () {
      const rejecting = await (await ethers.getContractFactory("RejectingMarketingWallet")).deploy();
      const rejectingTax = { ...TAX, marketingWallet: await rejecting.getAddress() };
      const token = await createToken(fx, user, 0, rejectingTax, "Reject Wallet", "RJCT");
      const tokenAddress = await token.getAddress();
      await fillCurveNative(fx, user, tokenAddress);
      await graduate(fx, tokenAddress);
      const key = await poolKeyFor(fx, tokenAddress);
      const vaultAddress = await token.dividendVault();

      await swapExactIn(fx, trader, key, true, ethers.parseEther("40"), true);
      await fx.settler.distribute(tokenAddress);

      const deferred = await fx.settler.marketingClaimable(tokenAddress);
      expect(deferred).to.be.gt(0n);
      expect(await ethers.provider.getBalance(vaultAddress)).to.be.gt(0n);

      const before = await ethers.provider.getBalance(marketing.address);
      await rejecting.claim(await fx.settler.getAddress(), tokenAddress, marketing.address);
      expect(await fx.settler.marketingClaimable(tokenAddress)).to.equal(0n);
      expect((await ethers.provider.getBalance(marketing.address)) - before).to.equal(deferred);
    });

    it("drains more than twenty funded dividend epochs through bounded distribute calls", async function () {
      const { token, tokenAddress } = await setupGraduatedTaxedToken();
      const vault = await ethers.getContractAt("DividendVault", await token.dividendVault());
      const hookAddress = await fx.hook.getAddress();
      const hookSigner = await ethers.getImpersonatedSigner(hookAddress);
      const epochAmount = ethers.parseEther("1");
      const epochCount = 50;

      await ethers.provider.send("hardhat_setBalance", [hookAddress, ethers.toBeHex(ethers.parseEther("1"))]);
      for (let i = 0; i < epochCount; i++) {
        await fx.settler.connect(hookSigner).recordTax(tokenAddress, 0, epochAmount, 0);
      }
      await user.sendTransaction({
        to: await fx.settler.getAddress(),
        value: epochAmount * BigInt(epochCount),
      });

      expect(await fx.settler.isDistributionReady(tokenAddress)).to.equal(true);
      await fx.settler.distribute(tokenAddress);
      expect(await vault.lastFinalizedEpoch()).to.equal(20);
      expect(await vault.queuedDividendTokens()).to.equal(ethers.parseEther("30"));

      await expect(fx.settler.distribute(tokenAddress))
        .to.emit(fx.settler, "DividendPendingAllocationProcessed");
      expect(await vault.lastFinalizedEpoch()).to.equal(40);
      expect(await vault.queuedDividendTokens()).to.equal(ethers.parseEther("10"));

      await fx.settler.distribute(tokenAddress);
      expect(await vault.lastFinalizedEpoch()).to.equal(50);
      expect(await vault.queuedDividendTokens()).to.equal(0);
      expect(await vault.queuedDividendPayment()).to.equal(0);
      expect(
        (await vault.pendingDividend(user.address)) + (await vault.claimedDividend(user.address))
      ).to.equal(ethers.parseEther("50"));
    });
  });

  describe("Exact-output rejection", function () {
    it("reverts exact-output swaps on taxed pools", async function () {
      const { key } = await setupGraduatedTaxedToken();

      const params = {
        zeroForOne: true,
        amountSpecified: ethers.parseEther("1000"), // positive = exact output
        sqrtPriceLimitX96: 4295128740n,
      };
      // The PoolManager wraps hook reverts, so assert the generic failure.
      await expect(
        fx.swapRouter
          .connect(trader)
          .swap(key, params, { takeClaims: false, settleUsingBurn: false }, "0x", {
            value: ethers.parseEther("10"),
          })
      ).to.be.reverted;
    });
  });

  describe("ERC20 payment pool taxation", function () {
    it("collects taxes in the ERC20 payment currency and settles to the marketing wallet", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken(1);
      const wnvdaxAddress = await fx.wnvdax.getAddress();
      const tokenIsCurrency0 = key.currency0.toLowerCase() === tokenAddress.toLowerCase();

      // Buy: wNVDAx in, token out
      const amountIn = ethers.parseEther("40");
      await fx.wnvdax.mint(trader.address, amountIn);
      await fx.wnvdax.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      await swapExactIn(fx, trader, key, !tokenIsCurrency0, amountIn, false);

      const state = await fx.settler.tokenState(tokenAddress);
      expect(state.marketingBucket).to.equal(amountIn / 100n);
      expect(state.dividendBucket).to.equal((amountIn * 2n) / 100n);
      expect(await fx.wnvdax.balanceOf(await fx.settler.getAddress())).to.be.gte((amountIn * 4n) / 100n);

      // Sell triggers settlement in wNVDAx
      await token.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      await swapExactIn(fx, trader, key, tokenIsCurrency0, ethers.parseEther("1000"), false);

      const stateAfter = await fx.settler.tokenState(tokenAddress);
      expect(stateAfter.marketingBucket).to.equal(0n);
      expect(await fx.wnvdax.balanceOf(marketing.address)).to.be.gte(amountIn / 100n);
    });
  });

  describe("Buyback liquidity reflow", function () {
    it("exposes the same versioned post-sell marker used by first-party encoders", async function () {
      expect(await fx.hook.POST_SELL_HOOK_DATA()).to.equal(
        ethers.id("OK_MEME_POST_SELL_V1").slice(0, 10)
      );
    });

    it("rejects an underfunded committed sell instead of silently deferring it", async function () {
      const { token, key } = await setupGraduatedTaxedToken();
      await swapExactIn(fx, trader, key, true, ethers.parseEther("1"), true);
      await token.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);

      const params = {
        zeroForOne: false,
        amountSpecified: -((await token.balanceOf(trader.address)) / 100n),
        sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341n,
      };
      const hookErrorInterface = new ethers.Contract(
        await fx.poolManager.getAddress(),
        ["error WrappedError(address target, bytes4 selector, bytes reason, bytes details)"],
        ethers.provider,
      );
      await expect(
        fx.swapRouter.connect(trader).swap(
          key,
          params,
          { takeClaims: false, settleUsingBurn: false },
          await fx.hook.POST_SELL_HOOK_DATA(),
          { gasLimit: 1_000_000n },
        )
      ).to.be.revertedWithCustomError(hookErrorInterface, "WrappedError");
    });

    it("keeps a committed estimate sufficient when reflow readiness changes before mining", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();
      await swapExactIn(fx, trader, key, true, ethers.parseEther("40"), true);
      await reflow(tokenAddress);
      expect(await fx.settler.isReflowReady(tokenAddress)).to.equal(false);

      await token.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      const params = {
        zeroForOne: false,
        amountSpecified: -((await token.balanceOf(trader.address)) / 100n),
        sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341n,
      };
      const marker = await fx.hook.POST_SELL_HOOK_DATA();
      const estimatedGas = await fx.swapRouter.connect(trader).swap.estimateGas(
        key,
        params,
        { takeClaims: false, settleUsingBurn: false },
        marker,
      );
      expect(estimatedGas).to.be.gt(
        await fx.hook.SETTLEMENT_GAS_LIMIT()
          + await fx.hook.AUTO_REFLOW_GAS_LIMIT()
          + await fx.hook.POST_SELL_CALL_OVERHEAD_GAS_RESERVE()
          + await fx.hook.POST_SELL_FINALIZE_GAS_RESERVE()
      );

      await ethers.provider.send("evm_increaseTime", [Number(await fx.settler.REFLOW_COOLDOWN())]);
      await ethers.provider.send("evm_mine", []);
      expect(await fx.settler.isReflowReady(tokenAddress)).to.equal(true);

      const receipt = await (
        await fx.swapRouter.connect(trader).swap(
          key,
          params,
          { takeClaims: false, settleUsingBurn: false },
          marker,
          { gasLimit: estimatedGas },
        )
      ).wait();
      const executed = receipt!.logs
        .map((log: any) => {
          try { return fx.settler.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "LiquidityReflowExecuted");
      expect(executed).to.not.equal(undefined);
      expect(executed!.args.duringActiveSwap).to.equal(true);
      expect(executed!.args.caller).to.equal(await fx.hook.getAddress());
      expect(executed!.args.remainingPaymentBucket).to.equal(
        (await fx.settler.tokenState(tokenAddress)).liquidityBucket
      );
    });

    it("does not reserve the unrelated 5M settlement budget for a reflow-only token", async function () {
      const reflowOnlyTax = {
        ...TAX,
        marketingFee: 0,
        holderDividendFee: 0,
        buybackFee: 200,
      };
      const { token, key } = await setupGraduatedTaxedToken(0, reflowOnlyTax);
      await swapExactIn(fx, trader, key, true, ethers.parseEther("1"), true);
      await token.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      const params = {
        zeroForOne: false,
        amountSpecified: -((await token.balanceOf(trader.address)) / 100n),
        sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341n,
      };
      const estimate = await fx.swapRouter.connect(trader).swap.estimateGas(
        key,
        params,
        { takeClaims: false, settleUsingBurn: false },
        await fx.hook.POST_SELL_HOOK_DATA(),
      );

      expect(estimate).to.be.gt(
        await fx.hook.AUTO_REFLOW_GAS_LIMIT()
          + await fx.hook.POST_SELL_CALL_OVERHEAD_GAS_RESERVE()
          + await fx.hook.POST_SELL_FINALIZE_GAS_RESERVE()
      );
      expect(estimate).to.be.lt(await fx.hook.SETTLEMENT_GAS_LIMIT());
    });

    it("reflows a ready native bucket atomically on the next real sell", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();
      await swapExactIn(fx, trader, key, true, ethers.parseEther("40"), true);

      const [positionTokenId] = await fx.locker.positionOf(tokenAddress);
      const liquidityBefore = await fx.positionManager.getPositionLiquidity(positionTokenId);
      await token.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      const sellAmount = (await token.balanceOf(trader.address)) / 100n;

      const receipt = await (await swapExactIn(fx, trader, key, false, sellAmount, false)).wait();
      const reflowEvents = receipt!.logs
        .map((log: any) => {
          try { return fx.settler.interface.parseLog(log); } catch { return null; }
        })
        .filter((event: any) => event?.name === "LiquidityReflowExecuted");

      expect(reflowEvents).to.have.length(1);
      expect(reflowEvents[0].args.paymentSwapped).to.be.gt(0n);
      expect(reflowEvents[0].args.tokenAcquired).to.be.gt(0n);
      expect(await fx.positionManager.getPositionLiquidity(positionTokenId)).to.be.gt(liquidityBefore);
      expect(await fx.settler.isReflowReady(tokenAddress)).to.equal(false);
    });

    it("uses the same sell-triggered path for an ERC20 payment pool", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken(1);
      const tokenIsCurrency0 = key.currency0.toLowerCase() === tokenAddress.toLowerCase();
      const amountIn = ethers.parseEther("40");
      await fx.wnvdax.mint(trader.address, amountIn);
      await fx.wnvdax.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      await swapExactIn(fx, trader, key, !tokenIsCurrency0, amountIn, false);

      const [positionTokenId] = await fx.locker.positionOf(tokenAddress);
      const liquidityBefore = await fx.positionManager.getPositionLiquidity(positionTokenId);
      await token.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      const sellAmount = (await token.balanceOf(trader.address)) / 100n;
      const receipt = await (
        await swapExactIn(fx, trader, key, tokenIsCurrency0, sellAmount, false)
      ).wait();

      const reflowEvent = receipt!.logs
        .map((log: any) => {
          try { return fx.settler.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "LiquidityReflowExecuted");
      expect(reflowEvent).to.not.equal(undefined);
      expect(await fx.positionManager.getPositionLiquidity(positionTokenId)).to.be.gt(liquidityBefore);
      expect(await fx.settler.isReflowReady(tokenAddress)).to.equal(false);
    });

    it("does not block the sell or consume bucket state when automatic reflow fails", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();
      await swapExactIn(fx, trader, key, true, ethers.parseEther("1"), true);

      const hookAddress = await fx.hook.getAddress();
      const hookSigner = await ethers.getImpersonatedSigner(hookAddress);
      await ethers.provider.send("hardhat_setBalance", [hookAddress, ethers.toBeHex(ethers.parseEther("1"))]);
      const artificialBucket = ethers.parseEther("100");
      await fx.settler.connect(hookSigner).recordTax(tokenAddress, 0, 0, artificialBucket);
      // Deliberately break custody after recording so the nested payment
      // settlement reverts. The hook must isolate that entire subcall.
      await ethers.provider.send("hardhat_setBalance", [await fx.settler.getAddress(), "0x0"]);

      await token.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      const traderTokensBefore = await token.balanceOf(trader.address);
      const sellAmount = traderTokensBefore / 100n;
      const receipt = await (await swapExactIn(fx, trader, key, false, sellAmount, false)).wait();

      const failed = receipt!.logs
        .map((log: any) => {
          try { return fx.hook.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "LiquidityReflowTriggerFailed");
      const executed = receipt!.logs
        .map((log: any) => {
          try { return fx.settler.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "LiquidityReflowExecuted");

      expect(failed).to.not.equal(undefined);
      expect(executed).to.equal(undefined);
      expect(await token.balanceOf(trader.address)).to.be.lt(traderTokensBefore);
      expect((await fx.settler.tokenState(tokenAddress)).liquidityBucket).to.be.gte(artificialBucket);
      expect(await fx.settler.isReflowReady(tokenAddress)).to.equal(true);
    });

    it("defers automatic reflow without blocking a deliberately low-gas sell", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();
      await swapExactIn(fx, trader, key, true, ethers.parseEther("1"), true);
      await token.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);

      const params = {
        zeroForOne: false,
        amountSpecified: -((await token.balanceOf(trader.address)) / 100n),
        sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341n,
      };
      const receipt = await (
        await fx.swapRouter.connect(trader).swap(
          key,
          params,
          { takeClaims: false, settleUsingBurn: false },
          "0x",
          { gasLimit: 1_000_000n },
        )
      ).wait();
      const deferred = receipt!.logs
        .map((log: any) => {
          try { return fx.hook.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "LiquidityReflowTriggerDeferred");
      const settlementDeferred = receipt!.logs
        .map((log: any) => {
          try { return fx.hook.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "SettlementTriggerDeferred");

      expect(deferred).to.not.equal(undefined);
      expect(settlementDeferred).to.not.equal(undefined);
      expect(await fx.settler.isReflowReady(tokenAddress)).to.equal(true);
    });

    it("swaps half the buyback bucket into tokens and deepens the locked position", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();

      // Accumulate a meaningful buyback bucket
      await swapExactIn(fx, trader, key, true, ethers.parseEther("40"), true);
      const stateBefore = await fx.settler.tokenState(tokenAddress);
      expect(stateBefore.liquidityBucket).to.be.gte(ethers.parseEther("0.4"));

      const [positionTokenId] = await fx.locker.positionOf(tokenAddress);
      const liquidityBefore = await fx.positionManager.getPositionLiquidity(positionTokenId);
      const deadBeforeReflow = await token.balanceOf(DEAD_ADDRESS);

      await expect(reflow(tokenAddress)).to.emit(fx.settler, "LiquidityReflowExecuted");

      const liquidityAfter = await fx.positionManager.getPositionLiquidity(positionTokenId);
      expect(liquidityAfter).to.be.gt(liquidityBefore);
      expect(await token.balanceOf(DEAD_ADDRESS)).to.equal(
        deadBeforeReflow,
        "liquidity reflow must never create an implicit token burn",
      );

      // CLOSE_CURRENCY realizes both sides of accrued LP fees. Payment fees
      // recycle into the payment bucket and token fees into token reserve.
      const stateAfter = await fx.settler.tokenState(tokenAddress);
      expect(stateAfter.liquidityBucket).to.be.lt(stateBefore.liquidityBucket);

      // A second bounded execution reflows the recycled fees as well.
      await ethers.provider.send("evm_increaseTime", [Number(await fx.settler.REFLOW_COOLDOWN())]);
      await ethers.provider.send("evm_mine", []);
      await expect(reflow(tokenAddress)).to.emit(fx.settler, "LiquidityReflowExecuted");
      const liquidityFinal = await fx.positionManager.getPositionLiquidity(positionTokenId);
      expect(liquidityFinal).to.be.gt(liquidityAfter);
    });

    it("reconciles payment, token reserve, LP fees and liquidity with exact integer math", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();
      await swapExactIn(fx, trader, key, true, ethers.parseEther("40"), true);

      // Direct donations to the terminal locker are not part of the reflow
      // ledger. They must neither be swept nor make exact accounting revert.
      const lockerAddress = await fx.locker.getAddress();
      const tokenDonation = ethers.parseEther("1");
      const nativeDonation = ethers.parseEther("0.001");
      await token.connect(trader).transfer(lockerAddress, tokenDonation);
      await user.sendTransaction({ to: lockerAddress, value: nativeDonation });

      const stateBefore = await fx.settler.tokenState(tokenAddress);
      const reflowBefore = await fx.settler.reflowState(tokenAddress);
      const settlerPaymentBefore = await ethers.provider.getBalance(await fx.settler.getAddress());
      const deadBefore = await token.balanceOf(DEAD_ADDRESS);
      const [positionTokenId] = await fx.locker.positionOf(tokenAddress);
      const liquidityBefore = await fx.positionManager.getPositionLiquidity(positionTokenId);

      const receipt = await (await reflow(tokenAddress)).wait();
      const executed = receipt!.logs
        .map((log: any) => {
          try { return fx.settler.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "LiquidityReflowExecuted");
      expect(executed).to.not.equal(undefined);

      const expectedBudget = reflowBefore.paymentBucket < reflowBefore.maxReflowPayment
        ? reflowBefore.paymentBucket
        : reflowBefore.maxReflowPayment;
      expect(executed!.args.budget).to.equal(expectedBudget);
      expect(executed!.args.remainingPaymentBucket).to.equal(
        reflowBefore.paymentBucket - expectedBudget + executed!.args.paymentRecovered,
      );
      expect(executed!.args.remainingTokenReserve).to.equal(
        reflowBefore.tokenReserve
          + executed!.args.tokenAcquired
          + executed!.args.tokenFeesAccrued
          - executed!.args.tokenUsed,
      );
      expect(executed!.args.tokenFeesAccrued + executed!.args.paymentFeesAccrued).to.be.gt(
        0n,
        "the test must exercise PositionManager fee realization, not only clean principal",
      );

      const stateAfter = await fx.settler.tokenState(tokenAddress);
      const reflowAfter = await fx.settler.reflowState(tokenAddress);
      expect(stateAfter.liquidityBucket).to.equal(executed!.args.remainingPaymentBucket);
      expect(reflowAfter.tokenReserve).to.equal(executed!.args.remainingTokenReserve);
      expect(await token.balanceOf(await fx.settler.getAddress())).to.equal(reflowAfter.tokenReserve);
      expect(await ethers.provider.getBalance(await fx.settler.getAddress())).to.equal(
        settlerPaymentBefore - expectedBudget + executed!.args.paymentRecovered,
      );
      expect(await token.balanceOf(DEAD_ADDRESS)).to.equal(deadBefore);
      expect(await token.balanceOf(lockerAddress)).to.equal(tokenDonation);
      expect(await ethers.provider.getBalance(lockerAddress)).to.equal(nativeDonation);

      const liquidityAfter = await fx.positionManager.getPositionLiquidity(positionTokenId);
      expect(liquidityAfter - liquidityBefore).to.equal(executed!.args.liquidityAdded);
      expect(executed!.args.tokenUsed).to.be.gt(0n);
      expect(executed!.args.paymentUsed).to.be.gt(0n);
    });

    it("uses an explicit per-token maximum budget without changing the readiness threshold", async function () {
      const maxBudget = ethers.parseEther("0.1");
      await fx.launchpad.setDefaultMaxReflowPayment(0, maxBudget);
      const { tokenAddress, key } = await setupGraduatedTaxedToken();
      await swapExactIn(fx, trader, key, true, ethers.parseEther("40"), true);

      const before = await fx.settler.reflowState(tokenAddress);
      expect(before.paymentBucket).to.be.gt(maxBudget);
      expect(before.maxReflowPayment).to.equal(maxBudget);

      const receipt = await (await reflow(tokenAddress)).wait();
      const executed = receipt!.logs
        .map((log: any) => {
          try { return fx.settler.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "LiquidityReflowExecuted");
      expect(executed!.args.budget).to.equal(maxBudget);
      expect(executed!.args.remainingPaymentBucket).to.equal(
        before.paymentBucket - maxBudget + executed!.args.paymentRecovered,
      );
    });

    it("distribute reverts when there is nothing to do", async function () {
      const { tokenAddress } = await setupGraduatedTaxedToken();
      await expect(fx.settler.distribute(tokenAddress)).to.be.revertedWith("Nothing to distribute");
    });

    it("allows any caller while keeping all financial parameters inside the contract", async function () {
      const { tokenAddress, key } = await setupGraduatedTaxedToken();
      await expect(fx.settler.connect(trader).reflow(tokenAddress))
        .to.be.revertedWith("Liquidity reflow not ready");
      await swapExactIn(fx, trader, key, true, ethers.parseEther("40"), true);

      await expect(reflow(tokenAddress, trader)).to.emit(fx.settler, "LiquidityReflowExecuted");
    });

    it("prevents callers from composing repeated bounded reflows inside the cooldown", async function () {
      const { tokenAddress, key } = await setupGraduatedTaxedToken();
      await swapExactIn(fx, trader, key, true, ethers.parseEther("80"), true);
      await reflow(tokenAddress, trader);

      await expect(reflow(tokenAddress, user)).to.be.revertedWith("Liquidity reflow not ready");
      expect(await fx.settler.isReflowReady(tokenAddress)).to.equal(false);
      await ethers.provider.send("evm_increaseTime", [Number(await fx.settler.REFLOW_COOLDOWN())]);
      await ethers.provider.send("evm_mine", []);
      expect(await fx.settler.isReflowReady(tokenAddress)).to.equal(true);
    });

    it("bounds pool movement from the execution-time tick and accounts realized input", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken();
      await swapExactIn(fx, trader, key, true, ethers.parseEther("40"), true);
      const before = await fx.settler.tokenState(tokenAddress);
      const [, tickBefore] = await fx.stateView.getSlot0(await token.poolId());

      const receipt = await (await reflow(tokenAddress)).wait();
      const parsed = receipt!.logs
        .map((log: any) => {
          try { return fx.settler.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "LiquidityReflowExecuted");

      expect(parsed).to.not.equal(undefined);
      expect(parsed!.args.paymentSwapped).to.be.gt(0n);
      expect(parsed!.args.paymentSwapped).to.be.lte(before.liquidityBucket / 2n);
      const [, tickAfter] = await fx.stateView.getSlot0(await token.poolId());
      const tickMove = tickAfter >= tickBefore ? tickAfter - tickBefore : tickBefore - tickAfter;
      expect(tickAfter).to.be.lte(tickBefore);
      expect(tickMove).to.be.lte(await fx.settler.MAX_REFLOW_TICK_MOVE());
    });

    it("restores unused payment when a large permissionless reflow reaches the hard tick limit", async function () {
      await fx.launchpad.setDefaultSettlementTriggerValue(0, ethers.parseEther("1000"));
      await fx.launchpad.setDefaultMaxReflowPayment(0, ethers.parseEther("1000"));
      const { token, tokenAddress } = await setupGraduatedTaxedToken();
      const hookAddress = await fx.hook.getAddress();
      const hookSigner = await ethers.getImpersonatedSigner(hookAddress);
      const bucket = ethers.parseEther("300");
      await ethers.provider.send("hardhat_setBalance", [hookAddress, ethers.toBeHex(ethers.parseEther("1"))]);
      await fx.settler.connect(hookSigner).recordTax(tokenAddress, 0, 0, bucket);
      await user.sendTransaction({ to: await fx.settler.getAddress(), value: bucket });
      const before = await fx.settler.tokenState(tokenAddress);
      const [, tickBefore] = await fx.stateView.getSlot0(await token.poolId());

      const receipt = await (await reflow(tokenAddress, user)).wait();
      const parsed = receipt!.logs
        .map((log: any) => {
          try { return fx.settler.interface.parseLog(log); } catch { return null; }
        })
        .find((event: any) => event?.name === "LiquidityReflowExecuted");
      const after = await fx.settler.tokenState(tokenAddress);
      const [, tickAfter] = await fx.stateView.getSlot0(await token.poolId());

      expect(parsed!.args.paymentSwapped).to.be.lt(before.liquidityBucket / 2n);
      expect(after.liquidityBucket).to.be.gt(0n);
      expect(tickBefore - tickAfter).to.be.lte(await fx.settler.MAX_REFLOW_TICK_MOVE());
    });

    it("uses the same permissionless bounded path for an ERC20 payment pool", async function () {
      const { token, tokenAddress, key } = await setupGraduatedTaxedToken(1);
      const tokenIsCurrency0 = key.currency0.toLowerCase() === tokenAddress.toLowerCase();
      const amountIn = ethers.parseEther("40");
      await fx.wnvdax.mint(trader.address, amountIn);
      await fx.wnvdax.connect(trader).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
      await swapExactIn(fx, trader, key, !tokenIsCurrency0, amountIn, false);
      const [, tickBefore] = await fx.stateView.getSlot0(await token.poolId());

      await expect(reflow(tokenAddress, user)).to.emit(fx.settler, "LiquidityReflowExecuted");
      const [, tickAfter] = await fx.stateView.getSlot0(await token.poolId());
      const tickMove = tickAfter >= tickBefore ? tickAfter - tickBefore : tickBefore - tickAfter;
      if (tokenIsCurrency0) {
        expect(tickAfter).to.be.gte(tickBefore);
      } else {
        expect(tickAfter).to.be.lte(tickBefore);
      }
      expect(tickMove).to.be.lte(await fx.settler.MAX_REFLOW_TICK_MOVE());
    });
  });

  describe("Access control", function () {
    it("exempts the system reflow sender from recursively taxing its own swap", async function () {
      expect(await fx.hook.isSwapExempt(await fx.settler.getAddress())).to.equal(true);
    });

    it("rejects unauthorized recordTax / registerPool / registerToken", async function () {
      const { tokenAddress, key } = await setupGraduatedTaxedToken();

      await expect(fx.settler.connect(trader).recordTax(tokenAddress, 1, 1, 1)).to.be.revertedWith("Only hook");
      await expect(fx.hook.connect(trader).registerPool(key, tokenAddress)).to.be.revertedWith("Only venue");
      await expect(
        fx.settler
          .connect(trader)
          .registerToken(tokenAddress, key, trader.address, trader.address, 1, 2, 1)
      ).to.be.revertedWith("Only venue");
      await expect(fx.hook.connect(trader).setSwapExempt(trader.address, true)).to.be.revertedWith("Not Owner");
      await expect(fx.settler.connect(trader).reflowDuringSwap(tokenAddress)).to.be.revertedWith("Only hook");
    });

    it("rejects the hook-only same-unlock entrypoint while PoolManager is locked", async function () {
      const { tokenAddress } = await setupGraduatedTaxedToken();
      const hookAddress = await fx.hook.getAddress();
      await ethers.provider.send("hardhat_setBalance", [hookAddress, ethers.toBeHex(ethers.parseEther("1"))]);
      const hookSigner = await ethers.getImpersonatedSigner(hookAddress);
      await expect(fx.settler.connect(hookSigner).reflowDuringSwap(tokenAddress))
        .to.be.revertedWith("Pool manager locked");
    });
  });
});
