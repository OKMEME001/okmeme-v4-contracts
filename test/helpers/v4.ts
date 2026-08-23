import { ethers, network } from "hardhat";
import { readFileSync } from "fs";
import { resolve } from "path";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// ============================================================
// Shared Uniswap V4 + OK.MEME deployment fixture for tests.
// ============================================================

export const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
export const DEAD_ADDRESS = "0x000000000000000000000000000000000000dEaD";

export const POOL_FEE = 10_000; // 1%
export const TICK_SPACING = 200;

// Hook permission flags (see v4-core Hooks.sol)
const BEFORE_INITIALIZE_FLAG = 1n << 13n;
const BEFORE_ADD_LIQUIDITY_FLAG = 1n << 11n;
const BEFORE_SWAP_FLAG = 1n << 7n;
const AFTER_SWAP_FLAG = 1n << 6n;
const BEFORE_SWAP_RETURNS_DELTA_FLAG = 1n << 3n;
const AFTER_SWAP_RETURNS_DELTA_FLAG = 1n << 2n;
const ALL_HOOK_MASK = (1n << 14n) - 1n;
export const HOOK_FLAGS =
  BEFORE_INITIALIZE_FLAG |
  BEFORE_ADD_LIQUIDITY_FLAG |
  BEFORE_SWAP_FLAG |
  AFTER_SWAP_FLAG |
  BEFORE_SWAP_RETURNS_DELTA_FLAG |
  AFTER_SWAP_RETURNS_DELTA_FLAG;

export const ZERO_TAX = {
  marketingFee: 0,
  holderDividendFee: 0,
  buybackFee: 0,
  burnFee: 0,
  marketingWallet: ethers.ZeroAddress,
  minHoldingForDividend: 0,
};

export interface V4Fixture {
  deployer: HardhatEthersSigner;
  launcher: HardhatEthersSigner;
  operator: HardhatEthersSigner;
  poolManager: any;
  positionManager: any;
  stateView: any;
  quoter: any;
  swapRouter: any;
  permit2: any;
  weth: any;
  hook: any;
  settler: any;
  locker: any;
  venue: any;
  platformVault: any;
  launchpad: any;
  tokenFactory: any;
  wnvdax: any;
}

/** Mines a CREATE2 salt so the hook address encodes the required permission flags. */
export function mineHookSalt(factoryAddress: string, initCodeHash: string): { salt: string; address: string } {
  for (let i = 0; i < 200_000; i++) {
    const salt = ethers.zeroPadValue(ethers.toBeHex(i), 32);
    const address = ethers.getCreate2Address(factoryAddress, salt, initCodeHash);
    if ((BigInt(address) & ALL_HOOK_MASK) === HOOK_FLAGS) {
      return { salt, address };
    }
  }
  throw new Error("Hook salt mining failed");
}

export async function deployV4Fixture(): Promise<V4Fixture> {
  const [deployer, launcher, operator] = await ethers.getSigners();

  // --- Uniswap V4 stack ---
  const weth = await (await ethers.getContractFactory("WETH")).deploy();
  const poolManager = await (await ethers.getContractFactory("PoolManager")).deploy(deployer.address);

  // Canonical Permit2 runtime bytecode captured from X Layer.
  const permit2Fixture = JSON.parse(
    readFileSync(resolve(__dirname, "../fixtures/permit2-runtime.json"), "utf8")
  );
  await network.provider.send("hardhat_setCode", [PERMIT2_ADDRESS, permit2Fixture.runtimeBytecode]);
  const permit2 = await ethers.getContractAt("IAllowanceTransfer", PERMIT2_ADDRESS);

  const positionManager = await (
    await ethers.getContractFactory("PositionManager")
  ).deploy(
    await poolManager.getAddress(),
    PERMIT2_ADDRESS,
    300_000,
    ethers.ZeroAddress,
    await weth.getAddress()
  );
  const stateView = await (await ethers.getContractFactory("StateView")).deploy(await poolManager.getAddress());
  const quoter = await (await ethers.getContractFactory("V4Quoter")).deploy(await poolManager.getAddress());
  const swapRouter = await (await ethers.getContractFactory("PoolSwapTest")).deploy(await poolManager.getAddress());

  // --- Tax hook at a mined address ---
  const create2Factory = await (await ethers.getContractFactory("Create2Factory")).deploy();
  const hookArtifact = await ethers.getContractFactory("OkMemeTaxHook");
  const hookInitCode = ethers.concat([
    hookArtifact.bytecode,
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address"],
      [await poolManager.getAddress(), deployer.address]
    ),
  ]);
  const { salt, address: hookAddress } = mineHookSalt(
    await create2Factory.getAddress(),
    ethers.keccak256(hookInitCode)
  );
  await create2Factory.deploy(salt, hookInitCode);
  const hook = await ethers.getContractAt("OkMemeTaxHook", hookAddress);

  // --- OK.MEME stack ---
  const platformVault = await (
    await ethers.getContractFactory("OkMemeVault")
  ).deploy(deployer.address, operator.address, deployer.address);
  const launchpad = await (await ethers.getContractFactory("OkMemeLaunchpad")).deploy();
  const settler = await (
    await ethers.getContractFactory("TaxSettler")
  ).deploy(await poolManager.getAddress(), deployer.address);
  const locker = await (
    await ethers.getContractFactory("PositionLocker")
  ).deploy(
    await poolManager.getAddress(),
    await positionManager.getAddress(),
    PERMIT2_ADDRESS,
    deployer.address
  );
  const venue = await (
    await ethers.getContractFactory("GraduationVenue")
  ).deploy(
    await poolManager.getAddress(),
    await positionManager.getAddress(),
    PERMIT2_ADDRESS,
    hookAddress,
    await settler.getAddress(),
    await locker.getAddress(),
    await launchpad.getAddress(),
    await platformVault.getAddress(),
    POOL_FEE,
    TICK_SPACING
  );

  await hook.setCoordinates(await venue.getAddress(), await settler.getAddress());
  await settler.setCoordinates(hookAddress, await venue.getAddress(), await locker.getAddress());
  await locker.setCoordinates(await venue.getAddress(), await settler.getAddress());

  const dividendVaultImpl = await (await ethers.getContractFactory("DividendVault")).deploy();
  const tokenFactory = await (
    await ethers.getContractFactory("OkMemeTokenFactory")
  ).deploy(await dividendVaultImpl.getAddress(), await settler.getAddress(), [
    await poolManager.getAddress(),
    await positionManager.getAddress(),
    await venue.getAddress(),
    await locker.getAddress(),
    await settler.getAddress(),
  ]);

  await launchpad.initialize(await platformVault.getAddress(), await venue.getAddress(), 100, 100);
  await launchpad.setTokenFactory(await tokenFactory.getAddress());
  await tokenFactory.setLaunchpad(await launchpad.getAddress());
  await launchpad.setLauncher(launcher.address);

  // Native pool (pool 0) economics.
  await launchpad.setPoolLaunchTarget(0, ethers.parseEther("100"));
  await launchpad.setDefaultSettlementTriggerValue(0, ethers.parseEther("1"));
  await launchpad.setDefaultMaxReflowPayment(0, ethers.parseEther("2"));
  await launchpad.setDefaultMinLiquidityPaymentToAdd(0, 1_000_000_000n); // 1e-9
  await launchpad.setDefaultAutoClaimThreshold(0, ethers.parseEther("1"));

  // ERC20 pool (pool 1).
  const wnvdax = await (await ethers.getContractFactory("MockERC20")).deploy("Wrapped NVDAx", "wNVDAx", 18);
  await launchpad.addErc20Pool(
    await wnvdax.getAddress(),
    ethers.parseEther("80"),
    ethers.parseEther("1"),
    ethers.parseEther("2"),
    1_000_000_000n,
    ethers.parseEther("1")
  );

  return {
    deployer,
    launcher,
    operator,
    poolManager,
    positionManager,
    stateView,
    quoter,
    swapRouter,
    permit2,
    weth,
    hook,
    settler,
    locker,
    venue,
    platformVault,
    launchpad,
    tokenFactory,
    wnvdax,
  };
}

/** Returns the PoolKey as a plain object (ethers Result is read-only and cannot be re-encoded). */
export async function poolKeyFor(fx: V4Fixture, tokenAddress: string) {
  const key = await fx.venue.poolKeyFor(tokenAddress);
  return {
    currency0: key.currency0,
    currency1: key.currency1,
    fee: key.fee,
    tickSpacing: key.tickSpacing,
    hooks: key.hooks,
  };
}

/** Fills a token's bonding curve to graduation-ready state (state 2). */
export async function fillCurveNative(fx: V4Fixture, buyer: HardhatEthersSigner, tokenAddress: string) {
  const config = await fx.launchpad.tokenLaunchConfigs(tokenAddress);
  const pool = await fx.launchpad.virtualPools(tokenAddress);
  const remaining: bigint = BigInt(config.launchPaymentReserve) - BigInt(pool.paymentReserve);
  if (remaining <= 0n) return;
  // Overpay to cover the 1% purchase fee; excess is refunded automatically.
  const paymentIn = (remaining * 10_000n) / 9_900n + ethers.parseEther("1");
  await fx.launchpad.connect(buyer).purchaseToken(tokenAddress, 0, { value: paymentIn });
}

export async function fillCurveERC20(fx: V4Fixture, buyer: HardhatEthersSigner, tokenAddress: string) {
  const config = await fx.launchpad.tokenLaunchConfigs(tokenAddress);
  const pool = await fx.launchpad.virtualPools(tokenAddress);
  const remaining: bigint = BigInt(config.launchPaymentReserve) - BigInt(pool.paymentReserve);
  if (remaining <= 0n) return;
  const paymentIn = (remaining * 10_000n) / 9_900n + ethers.parseEther("1");
  await fx.wnvdax.mint(buyer.address, paymentIn);
  await fx.wnvdax.connect(buyer).approve(await fx.launchpad.getAddress(), paymentIn);
  await fx.launchpad.connect(buyer).purchaseTokenERC20(tokenAddress, paymentIn, 0);
}

/** Creates a token on the given pool and returns its contract handle. */
export async function createToken(
  fx: V4Fixture,
  creator: HardhatEthersSigner,
  poolType: number,
  tax: Record<string, unknown> = ZERO_TAX,
  name = "Test Meme",
  symbol = "MEME"
) {
  const tx = await fx.launchpad
    .connect(creator)
    .createAndInitPurchase(name, symbol, ethers.toBigInt(ethers.randomBytes(32)), tax, poolType, 0);
  await tx.wait();
  const count = await fx.launchpad.tokenCount();
  const tokenAddress = await fx.launchpad.tokenAddress(count - 1n);
  return ethers.getContractAt("OkMemeToken", tokenAddress);
}

/** Graduates a curve-filled token via the launcher role. */
export async function graduate(fx: V4Fixture, tokenAddress: string) {
  await fx.launchpad.connect(fx.launcher).launchToDEXOwner(tokenAddress);
}

const MIN_SQRT_PRICE = 4295128739n;
const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;

/** Executes an exact-input swap through the PoolSwapTest router. */
export async function swapExactIn(
  fx: V4Fixture,
  signer: HardhatEthersSigner,
  key: any,
  zeroForOne: boolean,
  amountIn: bigint,
  nativeIn: boolean,
  hookData = "0x",
) {
  const params = {
    zeroForOne,
    amountSpecified: -amountIn,
    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1n : MAX_SQRT_PRICE - 1n,
  };
  const settings = { takeClaims: false, settleUsingBurn: false };
  return fx.swapRouter
    .connect(signer)
    .swap(key, params, settings, hookData, { value: nativeIn ? amountIn : 0n });
}

export async function approveForRouter(fx: V4Fixture, signer: HardhatEthersSigner, tokenAddress: string) {
  const token = await ethers.getContractAt("MockERC20", tokenAddress);
  await token.connect(signer).approve(await fx.swapRouter.getAddress(), ethers.MaxUint256);
}
