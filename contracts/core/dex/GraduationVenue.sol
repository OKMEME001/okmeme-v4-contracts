// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import "../interfaces/TaxConfig.sol";

interface IVenueToken {
    function paymentToken() external view returns (address);
    function taxConfig() external view returns (TaxConfig memory);
}

interface ITaxHookVenue {
    function registerPool(PoolKey calldata key, address token) external;
}

interface ITaxSettlerVenue {
    function registerToken(
        address token,
        PoolKey calldata key,
        address dividendVault,
        address marketingWallet,
        uint256 settlementTriggerValue,
        uint256 maxReflowPayment,
        uint256 minLiquidityPaymentToAdd
    ) external;
}

interface IPositionLockerVenue {
    function registerPosition(address token, uint256 tokenId, PoolKey calldata key) external;
}

/**
 * @title GraduationVenue
 * @notice Seeds the Uniswap V4 graduation pool for a launched token:
 *         initializes the pool at the bonding-curve closing price, mints the
 *         full-range position through PositionManager into the PositionLocker,
 *         and registers the pool with the shared tax hook and settler.
 *
 * Front-running defense: our PoolKey is predictable, so a third party may
 * initialize the pool first at an arbitrary price. As long as the pool holds
 * zero active liquidity the venue re-prices it with a 1-wei bounded swap to
 * the exact target sqrtPrice; if active liquidity exists at a wrong price the
 * graduation reverts rather than seeding at a manipulated price.
 */
contract GraduationVenue is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    address public immutable taxHook;
    address public immutable settler;
    address public immutable locker;
    address public immutable launchpad;
    address public immutable vault;
    uint24 public immutable poolFee;
    int24 public immutable poolTickSpacing;

    event PoolSeeded(
        address indexed token,
        bytes32 indexed poolId,
        uint256 positionTokenId,
        uint256 tokenAdded,
        uint256 paymentAdded,
        uint256 paymentSurplus
    );
    event PoolRepriced(bytes32 indexed poolId, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96);

    modifier onlyLaunchpad() {
        require(msg.sender == launchpad, "Only launchpad");
        _;
    }

    constructor(
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        address taxHook_,
        address settler_,
        address locker_,
        address launchpad_,
        address vault_,
        uint24 poolFee_,
        int24 poolTickSpacing_
    ) {
        require(address(poolManager_) != address(0), "Invalid manager");
        require(address(positionManager_) != address(0), "Invalid position manager");
        require(address(permit2_) != address(0), "Invalid permit2");
        require(taxHook_ != address(0), "Invalid hook");
        require(settler_ != address(0), "Invalid settler");
        require(locker_ != address(0), "Invalid locker");
        require(launchpad_ != address(0), "Invalid launchpad");
        require(vault_ != address(0), "Invalid vault");
        require(poolTickSpacing_ > 0, "Invalid tick spacing");

        poolManager = poolManager_;
        positionManager = positionManager_;
        permit2 = permit2_;
        taxHook = taxHook_;
        settler = settler_;
        locker = locker_;
        launchpad = launchpad_;
        vault = vault_;
        poolFee = poolFee_;
        poolTickSpacing = poolTickSpacing_;
    }

    /// @notice Predicts the graduation PoolKey for a token.
    function poolKeyFor(address token) public view returns (PoolKey memory key) {
        address payment = IVenueToken(token).paymentToken();
        (Currency currency0, Currency currency1) = _sortCurrencies(token, payment);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: poolFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(taxHook)
        });
    }

    /**
     * @notice Seeds the graduation pool. Token and payment amounts must already
     *         be held by this contract (native payment arrives as msg.value).
     */
    function seed(
        address token,
        uint256 tokenAmount,
        uint256 paymentAmount,
        address dividendVault,
        uint256 settlementTriggerValue,
        uint256 maxReflowPayment,
        uint256 minLiquidityPaymentToAdd
    ) external payable onlyLaunchpad returns (bytes32 poolIdOut, uint256 positionTokenId) {
        require(tokenAmount > 0 && paymentAmount > 0, "Invalid amounts");

        PoolKey memory key = poolKeyFor(token);
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) {
            require(msg.value == paymentAmount, "Invalid native amount");
        } else {
            require(msg.value == 0, "Unexpected native amount");
            require(IERC20(Currency.unwrap(tokenIsCurrency0 ? key.currency1 : key.currency0)).balanceOf(address(this)) >= paymentAmount, "Payment not received");
        }
        require(IERC20(token).balanceOf(address(this)) >= tokenAmount, "Token not received");

        uint256 amount0 = tokenIsCurrency0 ? tokenAmount : paymentAmount;
        uint256 amount1 = tokenIsCurrency0 ? paymentAmount : tokenAmount;
        uint160 targetSqrtPriceX96 = _sqrtPriceX96(amount0, amount1);

        _ensurePoolAtPrice(key, targetSqrtPriceX96);

        // Register with the tax hook and settler before liquidity exists so no
        // untaxed swap can ever occur on the live pool.
        ITaxHookVenue(taxHook).registerPool(key, token);
        TaxConfig memory tax = IVenueToken(token).taxConfig();
        ITaxSettlerVenue(settler).registerToken(
            token,
            key,
            dividendVault,
            tax.marketingWallet,
            settlementTriggerValue,
            maxReflowPayment,
            minLiquidityPaymentToAdd
        );

        positionTokenId = positionManager.nextTokenId();
        _mintFullRange(key, targetSqrtPriceX96, amount0, amount1);
        IPositionLockerVenue(locker).registerPosition(token, positionTokenId, key);

        poolIdOut = PoolId.unwrap(key.toId());

        (uint256 tokenAdded, uint256 paymentAdded, uint256 paymentSurplus) = _sweepLeftovers(
            key,
            token,
            tokenIsCurrency0,
            tokenAmount,
            paymentAmount
        );

        emit PoolSeeded(token, poolIdOut, positionTokenId, tokenAdded, paymentAdded, paymentSurplus);
    }

    // ============ Pool initialization / re-pricing ============

    function _ensurePoolAtPrice(PoolKey memory key, uint160 targetSqrtPriceX96) internal {
        PoolId poolId = key.toId();
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        if (currentSqrtPriceX96 == 0) {
            poolManager.initialize(key, targetSqrtPriceX96);
            return;
        }

        if (currentSqrtPriceX96 == targetSqrtPriceX96) {
            return;
        }

        // Front-run initialization: only re-price when no active liquidity
        // exists, then verify the exact target price was reached.
        require(poolManager.getLiquidity(poolId) == 0, "Pool polluted with liquidity");
        poolManager.unlock(
            abi.encode(RepriceCallbackData({key: key, targetSqrtPriceX96: targetSqrtPriceX96, zeroForOne: currentSqrtPriceX96 > targetSqrtPriceX96}))
        );
        (uint160 repricedSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        require(repricedSqrtPriceX96 == targetSqrtPriceX96, "Reprice failed");
        emit PoolRepriced(PoolId.unwrap(poolId), currentSqrtPriceX96, targetSqrtPriceX96);
    }

    struct RepriceCallbackData {
        PoolKey key;
        uint160 targetSqrtPriceX96;
        bool zeroForOne;
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");
        RepriceCallbackData memory data = abi.decode(rawData, (RepriceCallbackData));

        BalanceDelta delta = poolManager.swap(
            data.key,
            SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: -1,
                sqrtPriceLimitX96: data.targetSqrtPriceX96
            }),
            ""
        );

        _settleDelta(data.key.currency0, delta.amount0());
        _settleDelta(data.key.currency1, delta.amount1());
        return "";
    }

    function _settleDelta(Currency currency, int128 amount) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(currency);
                IERC20(Currency.unwrap(currency)).transfer(address(poolManager), owed);
                poolManager.settle();
            }
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    // ============ Liquidity ============

    function _mintFullRange(
        PoolKey memory key,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1
    ) internal {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        // Trim a hair so PositionManager's round-up settlement never exceeds
        // the exact balances we hold.
        liquidity = liquidity > 10_000 ? liquidity - liquidity / 10_000 : (liquidity > 0 ? liquidity - 1 : 0);
        require(liquidity > 0, "Liquidity mint failed");

        _approveCurrency(key.currency0);
        _approveCurrency(key.currency1);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, uint128(amount0), uint128(amount1), locker, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        params[3] = abi.encode(key.currency1, address(this));

        // Send the full native balance; SWEEP returns whatever is unused.
        uint256 nativeValue = key.currency0.isAddressZero() ? address(this).balance : 0;
        positionManager.modifyLiquidities{value: nativeValue}(abi.encode(actions, params), block.timestamp);
    }

    function _approveCurrency(Currency currency) internal {
        if (currency.isAddressZero()) {
            return;
        }
        address asset = Currency.unwrap(currency);
        (uint160 allowance,,) = permit2.allowance(address(this), asset, address(positionManager));
        if (allowance < type(uint160).max / 2) {
            IERC20(asset).approve(address(permit2), type(uint256).max);
            permit2.approve(asset, address(positionManager), type(uint160).max, type(uint48).max);
        }
    }

    function _sweepLeftovers(
        PoolKey memory key,
        address token,
        bool tokenIsCurrency0,
        uint256 tokenTarget,
        uint256 paymentTarget
    ) internal returns (uint256 tokenAdded, uint256 paymentAdded, uint256 paymentSurplus) {
        Currency paymentCurrency = tokenIsCurrency0 ? key.currency1 : key.currency0;

        uint256 tokenLeftover = IERC20(token).balanceOf(address(this));
        if (tokenLeftover > 0) {
            IERC20(token).transfer(address(0xdead), tokenLeftover);
        }
        tokenAdded = tokenTarget - tokenLeftover;

        uint256 paymentLeftover;
        if (paymentCurrency.isAddressZero()) {
            paymentLeftover = address(this).balance;
            if (paymentLeftover > 0) {
                (bool success,) = payable(vault).call{value: paymentLeftover}("");
                require(success, "Surplus transfer failed");
            }
        } else {
            address paymentAsset = Currency.unwrap(paymentCurrency);
            paymentLeftover = IERC20(paymentAsset).balanceOf(address(this));
            if (paymentLeftover > 0) {
                require(IERC20(paymentAsset).transfer(vault, paymentLeftover), "Surplus transfer failed");
            }
        }
        paymentSurplus = paymentLeftover;
        paymentAdded = paymentTarget - paymentLeftover;
    }

    // ============ Math ============

    function _sortCurrencies(address token, address payment)
        internal
        pure
        returns (Currency currency0, Currency currency1)
    {
        if (payment == address(0) || payment < token) {
            currency0 = Currency.wrap(payment);
            currency1 = Currency.wrap(token);
        } else {
            currency0 = Currency.wrap(token);
            currency1 = Currency.wrap(payment);
        }
    }

    /// @dev sqrtPriceX96 = sqrt(amount1 / amount0) * 2^96.
    function _sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        require(amount0 > 0 && amount1 > 0, "Invalid price inputs");
        uint256 ratioX192 = FullMath.mulDiv(amount1, uint256(1) << 192, amount0);
        uint256 sqrtPrice = Math.sqrt(ratioX192);
        require(
            sqrtPrice >= TickMath.MIN_SQRT_PRICE && sqrtPrice < TickMath.MAX_SQRT_PRICE,
            "Price out of range"
        );
        return uint160(sqrtPrice);
    }

    receive() external payable {}
}
