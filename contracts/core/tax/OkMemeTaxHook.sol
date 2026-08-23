// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import "../interfaces/TaxConfig.sol";

interface IHookToken {
    function taxConfig() external view returns (TaxConfig memory);
}

interface ITaxSettlerHook {
    function recordTax(
        address token,
        uint256 marketingAmount,
        uint256 dividendAmount,
        uint256 liquidityAmount
    ) external returns (uint256 recordedDividendAmount);

    function onSellRecorded(address token) external;

    function isReflowReady(address token) external view returns (bool);

    function reflowDuringSwap(address token) external;
}

/**
 * @title OkMemeTaxHook
 * @notice Shared Uniswap V4 hook that collects the per-token swap tax for every
 *         graduated OK.MEME pool.
 *
 * Tax model (per swap, exact-input only):
 *   - marketing / dividend / buyback legs are charged in the PAYMENT currency
 *     and forwarded to the shared TaxSettler.
 *   - the burn leg is charged in the TOKEN currency and sent to 0xdead.
 *
 * Charging point:
 *   - a leg whose currency is the swap's SPECIFIED currency (the exact input)
 *     is taken in beforeSwap via a positive specified BeforeSwapDelta;
 *   - a leg whose currency is the UNSPECIFIED currency (the output) is taken
 *     in afterSwap via a positive unspecified return delta.
 *
 * Exact-output swaps are rejected: with hook-taken fees on both legs the
 * requested exact output cannot be honored without ambiguous semantics, and
 * every first-party trading path uses exact input.
 */
contract OkMemeTaxHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint256 public constant FEE_DENOMINATOR = 10_000;

    struct PoolTaxInfo {
        address token;
        bool tokenIsCurrency0;
        uint16 marketingFee;
        uint16 dividendFee;
        uint16 buybackFee;
        uint16 burnFee;
    }

    address public owner;
    address public pendingOwner;
    address public venue;
    address public settler;

    mapping(PoolId => PoolTaxInfo) public poolTaxInfo;
    mapping(address => bool) public isSwapExempt;
    mapping(PoolId => uint256) private _pendingBuyPaymentTax;

    event PoolRegistered(PoolId indexed poolId, address indexed token, bool tokenIsCurrency0);
    event SwapExemptUpdated(address indexed account, bool exempt);
    event SwapTaxCollected(
        PoolId indexed poolId,
        address indexed token,
        bool isSell,
        uint256 paymentTaxAmount,
        uint256 burnAmount
    );
    event SettlementTriggerDeferred(address indexed token, uint256 gasAvailable);
    event SettlementTriggerFailed(address indexed token, bytes reason);
    event LiquidityReflowTriggerDeferred(address indexed token, uint256 gasAvailable);
    event LiquidityReflowTriggerFailed(address indexed token, bytes reason);
    event CoordinatesSet(address indexed venue, address indexed settler);
    event PendingOwnerSet(address indexed oldPendingOwner, address indexed newPendingOwner);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    error ExactOutputNotSupported();
    error PostSellGasTooLow(uint256 available, uint256 required);

    /// @notice Versioned opt-in used by first-party sells. It is an execution
    ///         policy marker, not authentication: any router may opt into the
    ///         same bounded post-sell behavior.
    bytes4 public constant POST_SELL_HOOK_DATA = bytes4(keccak256("OK_MEME_POST_SELL_V1"));

    /// @dev Settlement can drive the DividendVault's bounded 5M-gas auto-claim
    ///      batch. Reflow is independently capped, while the final reserve
    ///      covers EIP-150 call overhead, events and the outer router unwind.
    uint256 public constant SETTLEMENT_GAS_LIMIT = 5_500_000;
    uint256 public constant AUTO_REFLOW_GAS_LIMIT = 1_200_000;
    uint256 public constant POST_SELL_CALL_OVERHEAD_GAS_RESERVE = 100_000;
    uint256 public constant POST_SELL_FINALIZE_GAS_RESERVE = 250_000;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not Owner");
        _;
    }

    constructor(IPoolManager manager_, address owner_) BaseHook(manager_) {
        require(owner_ != address(0), "Invalid owner");
        owner = owner_;
    }

    // ============ Wiring ============

    function setCoordinates(address venue_, address settler_) external onlyOwner {
        require(venue == address(0) && settler == address(0), "Coordinates set");
        require(venue_ != address(0) && settler_ != address(0), "Invalid coordinates");
        venue = venue_;
        settler = settler_;
        isSwapExempt[venue_] = true;
        isSwapExempt[settler_] = true;
        emit CoordinatesSet(venue_, settler_);
    }

    function setSwapExempt(address account, bool exempt) external onlyOwner {
        require(account != address(0), "Invalid account");
        isSwapExempt[account] = exempt;
        emit SwapExemptUpdated(account, exempt);
    }

    function setPendingOwner(address newPendingOwner) external onlyOwner {
        emit PendingOwnerSet(pendingOwner, newPendingOwner);
        pendingOwner = newPendingOwner;
    }

    function acceptOwner() external {
        require(msg.sender == pendingOwner, "Not Pending Owner");
        emit OwnerChanged(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Registers a graduated pool. Only callable by the graduation venue.
    function registerPool(PoolKey calldata key, address token) external {
        require(msg.sender == venue, "Only venue");
        require(token != address(0), "Invalid token");

        PoolId poolId = key.toId();
        require(poolTaxInfo[poolId].token == address(0), "Pool registered");

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        require(
            tokenIsCurrency0 || Currency.unwrap(key.currency1) == token,
            "Token not in pool"
        );

        TaxConfig memory tax = IHookToken(token).taxConfig();
        poolTaxInfo[poolId] = PoolTaxInfo({
            token: token,
            tokenIsCurrency0: tokenIsCurrency0,
            marketingFee: tax.marketingFee,
            dividendFee: tax.holderDividendFee,
            buybackFee: tax.buybackFee,
            burnFee: tax.burnFee
        });

        emit PoolRegistered(poolId, token, tokenIsCurrency0);
    }

    // ============ Hook permissions ============

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev A graduation PoolKey is predictable, so initialization must remain
    ///      exclusive to the venue until the canonical pool exists.
    function _beforeInitialize(
        address sender,
        PoolKey calldata,
        uint160
    ) internal view override returns (bytes4) {
        require(sender == venue, "Only venue can initialize");
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Graduation registers the pool immediately before minting the locked
    ///      position. Rejecting liquidity for unregistered keys prevents a third
    ///      party from pre-seeding a predictable graduation pool.
    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        require(poolTaxInfo[key.toId()].token != address(0), "Pool not registered");
        return BaseHook.beforeAddLiquidity.selector;
    }

    // ============ Swap callbacks ============

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolTaxInfo memory info = poolTaxInfo[key.toId()];
        if (info.token == address(0) || isSwapExempt[sender]) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        if (params.amountSpecified >= 0) {
            revert ExactOutputNotSupported();
        }

        // Exact input: the specified currency is the input side.
        bool inputIsCurrency0 = params.zeroForOne;
        bool inputIsToken = inputIsCurrency0 == info.tokenIsCurrency0;
        uint256 amountIn = uint256(-params.amountSpecified);

        uint256 feeAmount;
        if (inputIsToken) {
            // Sell: burn leg charged on the token input.
            feeAmount = amountIn * info.burnFee / FEE_DENOMINATOR;
            if (feeAmount > 0) {
                Currency tokenCurrency = inputIsCurrency0 ? key.currency0 : key.currency1;
                poolManager.take(tokenCurrency, address(0xdead), feeAmount);
            }
        } else {
            // Buy: payment legs charged on the payment input.
            uint256 marketingAmount = amountIn * info.marketingFee / FEE_DENOMINATOR;
            uint256 dividendAmount = amountIn * info.dividendFee / FEE_DENOMINATOR;
            uint256 liquidityAmount = amountIn * info.buybackFee / FEE_DENOMINATOR;
            uint256 recordedDividend = ITaxSettlerHook(settler).recordTax(
                info.token,
                marketingAmount,
                dividendAmount,
                liquidityAmount
            );
            feeAmount = marketingAmount + recordedDividend + liquidityAmount;
            if (feeAmount > 0) {
                Currency paymentCurrency = inputIsCurrency0 ? key.currency0 : key.currency1;
                poolManager.take(paymentCurrency, settler, feeAmount);
            }
            _pendingBuyPaymentTax[key.toId()] = feeAmount;
        }

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(feeAmount.toInt128(), 0), 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolTaxInfo memory info = poolTaxInfo[poolId];
        if (info.token == address(0) || isSwapExempt[sender]) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // Exact input (enforced in beforeSwap): the unspecified currency is the output side.
        bool outputIsCurrency0 = !params.zeroForOne;
        bool outputIsToken = outputIsCurrency0 == info.tokenIsCurrency0;
        int128 outputDelta = outputIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 amountOut = outputDelta > 0 ? uint256(uint128(outputDelta)) : 0;

        uint256 feeAmount;
        uint256 paymentTax;
        uint256 burnAmount;
        if (outputIsToken) {
            // Buy: burn leg charged on the token output.
            burnAmount = amountOut * info.burnFee / FEE_DENOMINATOR;
            feeAmount = burnAmount;
            if (feeAmount > 0) {
                Currency tokenCurrency = outputIsCurrency0 ? key.currency0 : key.currency1;
                poolManager.take(tokenCurrency, address(0xdead), feeAmount);
            }
            paymentTax = _pendingBuyPaymentTax[poolId];
            delete _pendingBuyPaymentTax[poolId];
            emit SwapTaxCollected(poolId, info.token, false, paymentTax, burnAmount);
        } else {
            // Sell: payment legs charged on the payment output.
            uint256 marketingAmount = amountOut * info.marketingFee / FEE_DENOMINATOR;
            uint256 dividendAmount = amountOut * info.dividendFee / FEE_DENOMINATOR;
            uint256 liquidityAmount = amountOut * info.buybackFee / FEE_DENOMINATOR;
            uint256 recordedDividend = ITaxSettlerHook(settler).recordTax(
                info.token,
                marketingAmount,
                dividendAmount,
                liquidityAmount
            );
            paymentTax = marketingAmount + recordedDividend + liquidityAmount;
            feeAmount = paymentTax;
            if (feeAmount > 0) {
                Currency paymentCurrency = outputIsCurrency0 ? key.currency0 : key.currency1;
                poolManager.take(paymentCurrency, settler, feeAmount);
            }
            burnAmount = uint256(-params.amountSpecified) * info.burnFee / FEE_DENOMINATOR;
            emit SwapTaxCollected(poolId, info.token, true, paymentTax, burnAmount);

            bool hasSettlementWork = info.marketingFee > 0 || info.dividendFee > 0;
            bool hasReflowWork = info.buybackFee > 0;
            bool committedPostSell = _isCommittedPostSell(hookData);

            bool reflowReady;
            if (hasReflowWork) {
                try ITaxSettlerHook(settler).isReflowReady(info.token) returns (bool ready) {
                    reflowReady = ready;
                } catch (bytes memory reason) {
                    emit LiquidityReflowTriggerFailed(info.token, reason);
                }
            }

            // A committed sell must carry enough gas even when neither task is
            // currently ready. This prevents estimate-time state from selecting
            // a cheaper path that becomes underfunded before the tx is mined.
            // Check after the readiness probe so its cost cannot eat the budget.
            if (committedPostSell) {
                uint256 requiredGas = POST_SELL_CALL_OVERHEAD_GAS_RESERVE
                    + POST_SELL_FINALIZE_GAS_RESERVE;
                if (hasSettlementWork) requiredGas += SETTLEMENT_GAS_LIMIT;
                if (hasReflowWork) requiredGas += AUTO_REFLOW_GAS_LIMIT;
                uint256 gasAvailable = gasleft();
                if (gasAvailable <= requiredGas) {
                    revert PostSellGasTooLow(gasAvailable, requiredGas);
                }
            }

            // Sell path drives settlement / auto-claim, mirroring the V2-era
            // fee-on-transfer trigger. Bound the external call so even an OOG
            // failure leaves enough gas to finish the user swap.
            if (hasSettlementWork) {
                uint256 tailReserve = POST_SELL_FINALIZE_GAS_RESERVE
                    + POST_SELL_CALL_OVERHEAD_GAS_RESERVE
                    + (reflowReady ? AUTO_REFLOW_GAS_LIMIT : 0);
                uint256 gasAvailable = gasleft();
                if (gasAvailable <= tailReserve) {
                    emit SettlementTriggerDeferred(info.token, gasAvailable);
                } else {
                    uint256 settlementGas = gasAvailable - tailReserve;
                    if (settlementGas > SETTLEMENT_GAS_LIMIT) {
                        settlementGas = SETTLEMENT_GAS_LIMIT;
                    }
                    try ITaxSettlerHook(settler).onSellRecorded{gas: settlementGas}(info.token) {
                    } catch (bytes memory reason) {
                        emit SettlementTriggerFailed(info.token, reason);
                    }
                }
            }

            // V4 already has PoolManager unlocked while this callback runs.
            // Reuse that unlock for a bounded reflow instead of relying on an
            // off-chain worker. Keep it isolated so no reflow failure can roll
            // back the user's sell or the tax already recorded above.
            if (reflowReady) {
                uint256 gasAvailable = gasleft();
                if (gasAvailable <= AUTO_REFLOW_GAS_LIMIT + POST_SELL_FINALIZE_GAS_RESERVE) {
                    emit LiquidityReflowTriggerDeferred(info.token, gasAvailable);
                } else {
                    try ITaxSettlerHook(settler).reflowDuringSwap{gas: AUTO_REFLOW_GAS_LIMIT}(info.token) {
                    } catch (bytes memory reason) {
                        emit LiquidityReflowTriggerFailed(info.token, reason);
                    }
                }
            }
        }

        return (BaseHook.afterSwap.selector, feeAmount.toInt128());
    }

    function _isCommittedPostSell(bytes calldata hookData) internal pure returns (bool) {
        return hookData.length == 4 && bytes4(hookData) == POST_SELL_HOOK_DATA;
    }
}
