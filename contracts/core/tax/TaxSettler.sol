// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import "../../shared/interfaces/IDividendVault.sol";
import {IPositionLocker} from "../dex/IPositionLocker.sol";

/**
 * @title TaxSettler
 * @notice Shared payment-currency tax ledger and settlement engine for all
 *         graduated OK.MEME tokens.
 *
 * The V4 tax hook forwards the marketing / dividend / buyback legs of every
 * taxed swap here, already denominated in the pool's payment currency
 * (native OKB or a configured ERC20). Per token the settler:
 *   - accumulates the three buckets;
 *   - fixes dividend entitlement at tax collection, then on the sell path (or
 *     a permissionless poke) pays marketing, funds the queued dividend epochs,
 *     and drives auto-claims once the settlement trigger is reached;
 *   - reflows a bounded buyback batch on the next real sell by reusing V4's
 *     active unlock, while keeping the permissionless entrypoint as fallback.
 *
 * The caller chooses no financial parameters: the contract derives the batch
 * and price limit from chain state in both execution modes.
 */
contract TaxSettler is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    /// @dev 300 ticks is about a 3.05% maximum pool-price move per reflow.
    int24 public constant MAX_REFLOW_TICK_MOVE = 300;
    /// @dev Prevents callers from composing many individually bounded reflows
    ///      into one effectively unbounded execution window.
    uint256 public constant REFLOW_COOLDOWN = 60 seconds;

    IPoolManager public immutable poolManager;

    address public owner;
    address public pendingOwner;
    address public hook;
    address public venue;
    address public locker;

    uint256 private _status;

    struct TokenTaxState {
        bool registered;
        bool paymentIsCurrency0;
        address dividendVault;
        address marketingWallet;
        uint256 settlementTriggerValue;
        uint256 maxReflowPayment;
        uint256 minLiquidityPaymentToAdd;
        uint256 marketingBucket;
        uint256 marketingClaimable;
        uint256 dividendBucket;
        uint256 liquidityBucket;
        uint256 liquidityTokenReserve;
        uint256 lastReflowAt;
        PoolKey poolKey;
    }

    mapping(address => TokenTaxState) internal _tokenStates;

    event CoordinatesSet(address indexed hook, address indexed venue, address indexed locker);
    event TokenRegistered(
        address indexed token,
        address indexed dividendVault,
        uint256 settlementTriggerValue,
        uint256 maxReflowPayment
    );
    event TaxRecorded(
        address indexed token,
        uint256 marketingAmount,
        uint256 dividendAmount,
        uint256 liquidityAmount
    );
    event SettlementExecuted(
        address indexed token,
        uint256 marketingPayment,
        uint256 dividendPayment
    );
    event MarketingPaymentDeferred(address indexed token, address indexed wallet, uint256 amount);
    event MarketingPaymentClaimed(address indexed token, address indexed wallet, address indexed recipient, uint256 amount);
    event DividendPendingAllocationProcessed(
        address indexed token,
        uint256 consumedToken,
        uint256 consumedPayment,
        uint256 remainingToken,
        uint256 remainingPayment
    );
    event DividendAutoClaimTriggered(address indexed token, uint256 iterations, uint256 claims, uint256 amount);
    event LiquidityReflowExecuted(
        address indexed token,
        address indexed caller,
        bool duringActiveSwap,
        uint256 budget,
        uint256 paymentSwapped,
        uint256 tokenAcquired,
        uint128 liquidityAdded,
        uint256 tokenUsed,
        uint256 paymentUsed,
        uint256 tokenFeesAccrued,
        uint256 paymentFeesAccrued,
        uint256 paymentRecovered,
        uint256 remainingTokenReserve,
        uint256 remainingPaymentBucket
    );
    event PendingOwnerSet(address indexed oldPendingOwner, address indexed newPendingOwner);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not Owner");
        _;
    }

    modifier onlyHook() {
        require(msg.sender == hook, "Only hook");
        _;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor(IPoolManager poolManager_, address owner_) {
        require(address(poolManager_) != address(0), "Invalid manager");
        require(owner_ != address(0), "Invalid owner");
        poolManager = poolManager_;
        owner = owner_;
        _status = _NOT_ENTERED;
    }

    // ============ Wiring ============

    function setCoordinates(address hook_, address venue_, address locker_) external onlyOwner {
        require(hook == address(0) && venue == address(0) && locker == address(0), "Coordinates set");
        require(hook_ != address(0) && venue_ != address(0) && locker_ != address(0), "Invalid coordinates");
        hook = hook_;
        venue = venue_;
        locker = locker_;
        emit CoordinatesSet(hook_, venue_, locker_);
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

    /// @notice Registers a graduated token. Only callable by the graduation venue.
    function registerToken(
        address token,
        PoolKey calldata key,
        address dividendVault_,
        address marketingWallet_,
        uint256 settlementTriggerValue_,
        uint256 maxReflowPayment_,
        uint256 minLiquidityPaymentToAdd_
    ) external {
        require(msg.sender == venue, "Only venue");
        require(token != address(0), "Invalid token");
        require(dividendVault_ != address(0), "Invalid vault");
        require(maxReflowPayment_ >= 2, "Invalid reflow budget");

        TokenTaxState storage state = _tokenStates[token];
        require(!state.registered, "Token registered");

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        require(tokenIsCurrency0 || Currency.unwrap(key.currency1) == token, "Token not in pool");

        state.registered = true;
        state.paymentIsCurrency0 = !tokenIsCurrency0;
        state.dividendVault = dividendVault_;
        state.marketingWallet = marketingWallet_;
        state.settlementTriggerValue = settlementTriggerValue_;
        state.maxReflowPayment = maxReflowPayment_;
        state.minLiquidityPaymentToAdd = minLiquidityPaymentToAdd_;
        state.poolKey = key;

        emit TokenRegistered(token, dividendVault_, settlementTriggerValue_, maxReflowPayment_);
    }

    // ============ Hook entrypoints ============

    /// @notice Records payment-currency tax that the hook atomically transfers
    ///         here via PoolManager.take in the same swap.
    function recordTax(
        address token,
        uint256 marketingAmount,
        uint256 dividendAmount,
        uint256 liquidityAmount
    ) external onlyHook returns (uint256 recordedDividendAmount) {
        TokenTaxState storage state = _tokenStates[token];
        require(state.registered, "Token not registered");

        state.marketingBucket += marketingAmount;
        state.liquidityBucket += liquidityAmount;

        // Preserve the V2 product semantics: entitlement is fixed when tax is
        // collected, before the swap's token transfer changes holder balances.
        if (dividendAmount > 0) {
            IDividendVault vault = IDividendVault(state.dividendVault);
            if (vault.currentEligibleShares() > 0) {
                uint256 epochId = vault.createDividendEpoch(dividendAmount);
                if (epochId != 0) {
                    recordedDividendAmount = dividendAmount;
                    state.dividendBucket += dividendAmount;
                }
            }
        }

        emit TaxRecorded(token, marketingAmount, recordedDividendAmount, liquidityAmount);
    }

    /// @notice Sell-path trigger: settle + auto-claim when thresholds are met.
    ///         Never performs pool operations (safe inside hook callbacks).
    function onSellRecorded(address token) external onlyHook nonReentrant {
        _settleIfReady(token);
        _processAutoClaims(token);
    }

    /// @notice Executes a ready reflow during the PoolManager unlock that is
    ///         already active for a user sell. This is the primary liveness
    ///         path and is callable only by the registered tax hook.
    function reflowDuringSwap(address token) external onlyHook nonReentrant {
        require(poolManager.isUnlocked(), "Pool manager locked");
        if (!isReflowReady(token)) {
            return;
        }
        _reflow(token, true);
    }

    // ============ Permissionless settlement ============

    /// @notice Settles marketing/dividend buckets and drives auto-claims.
    ///         Reflow is deliberately isolated behind {reflow}.
    function distribute(address token) external nonReentrant {
        TokenTaxState storage state = _tokenStates[token];
        require(state.registered, "Token not registered");
        require(isDistributionReady(token), "Nothing to distribute");

        // notifyDividendPayment already allocates one bounded epoch batch when
        // a new settlement is funded. Otherwise advance one existing batch.
        // This keeps every permissionless call bounded to the vault's limit.
        bool settled = _settleIfReady(token);
        if (!settled) {
            _processPendingDividendAllocation(token);
        }
        _processAutoClaims(token);
    }

    /// @notice Executes one permissionless, bounded liquidity reflow.
    ///         The caller supplies no quote or price parameters; the contract
    ///         derives a hard tick limit from the pool state at execution.
    function reflow(address token) external nonReentrant {
        require(!poolManager.isUnlocked(), "Pool manager unlocked");
        require(isReflowReady(token), "Liquidity reflow not ready");
        _reflow(token, false);
    }

    /// @notice Retries a marketing payment that could not be pushed during
    ///         settlement. The configured wallet controls the final recipient.
    function claimMarketing(address token, address recipient) external nonReentrant {
        TokenTaxState storage state = _tokenStates[token];
        require(state.registered, "Token not registered");
        require(msg.sender == state.marketingWallet, "Only marketing wallet");
        require(recipient != address(0), "Invalid recipient");
        uint256 amount = state.marketingClaimable;
        require(amount > 0, "Nothing to claim");
        state.marketingClaimable = 0;
        _sendPayment(_paymentCurrency(state), recipient, amount);
        emit MarketingPaymentClaimed(token, msg.sender, recipient, amount);
    }

    // ============ Views ============

    function tokenState(address token)
        external
        view
        returns (
            bool registered,
            uint256 marketingBucket,
            uint256 dividendBucket,
            uint256 liquidityBucket,
            uint256 settlementTriggerValue,
            uint256 minLiquidityPaymentToAdd
        )
    {
        TokenTaxState storage state = _tokenStates[token];
        return (
            state.registered,
            state.marketingBucket,
            state.dividendBucket,
            state.liquidityBucket,
            state.settlementTriggerValue,
            state.minLiquidityPaymentToAdd
        );
    }

    function poolKeyOf(address token) external view returns (PoolKey memory) {
        require(_tokenStates[token].registered, "Token not registered");
        return _tokenStates[token].poolKey;
    }

    function marketingClaimable(address token) external view returns (uint256) {
        return _tokenStates[token].marketingClaimable;
    }

    function reflowState(address token)
        external
        view
        returns (
            uint256 paymentBucket,
            uint256 tokenReserve,
            uint256 maxReflowPayment,
            uint256 lastReflowAt
        )
    {
        TokenTaxState storage state = _tokenStates[token];
        return (state.liquidityBucket, state.liquidityTokenReserve, state.maxReflowPayment, state.lastReflowAt);
    }

    function isSettlementReady(address token) public view returns (bool) {
        TokenTaxState storage state = _tokenStates[token];
        if (!state.registered) {
            return false;
        }
        uint256 pending = state.marketingBucket + state.dividendBucket;
        return pending > 0 && pending >= state.settlementTriggerValue;
    }

    function hasPendingDividendAllocation(address token) public view returns (bool) {
        TokenTaxState storage state = _tokenStates[token];
        if (!state.registered) {
            return false;
        }
        IDividendVault vault = IDividendVault(state.dividendVault);
        return vault.queuedDividendTokens() > 0 && vault.queuedDividendPayment() > 0;
    }

    function isDistributionReady(address token) public view returns (bool) {
        TokenTaxState storage state = _tokenStates[token];
        if (!state.registered) {
            return false;
        }
        return isSettlementReady(token)
            || hasPendingDividendAllocation(token)
            || IDividendVault(state.dividendVault).isAutoClaimReady();
    }

    function isReflowReady(address token) public view returns (bool) {
        TokenTaxState storage state = _tokenStates[token];
        if (!state.registered) {
            return false;
        }
        uint256 minAdd = state.minLiquidityPaymentToAdd;
        uint256 floor = minAdd * 2 > 2 ? minAdd * 2 : 2;
        return state.liquidityBucket >= floor
            && block.timestamp >= state.lastReflowAt + REFLOW_COOLDOWN;
    }

    // ============ Internal settlement ============

    function _paymentCurrency(TokenTaxState storage state) internal view returns (Currency) {
        return state.paymentIsCurrency0 ? state.poolKey.currency0 : state.poolKey.currency1;
    }

    function _tokenCurrency(TokenTaxState storage state) internal view returns (Currency) {
        return state.paymentIsCurrency0 ? state.poolKey.currency1 : state.poolKey.currency0;
    }

    function _settleIfReady(address token) internal returns (bool settled) {
        if (!isSettlementReady(token)) {
            return false;
        }

        TokenTaxState storage state = _tokenStates[token];
        Currency payment = _paymentCurrency(state);

        uint256 marketingPayment = state.marketingBucket;
        uint256 marketingPaid = 0;
        if (marketingPayment > 0) {
            state.marketingBucket = 0;
            if (_trySendPayment(payment, state.marketingWallet, marketingPayment)) {
                marketingPaid = marketingPayment;
            } else {
                state.marketingClaimable += marketingPayment;
                emit MarketingPaymentDeferred(token, state.marketingWallet, marketingPayment);
            }
        }

        uint256 dividendPayment = state.dividendBucket;
        if (dividendPayment > 0) {
            IDividendVault vault = IDividendVault(state.dividendVault);
            state.dividendBucket = 0;
            if (payment.isAddressZero()) {
                vault.notifyDividendPayment{value: dividendPayment}(dividendPayment, dividendPayment);
            } else {
                IERC20(Currency.unwrap(payment)).safeTransfer(state.dividendVault, dividendPayment);
                vault.notifyDividendPayment(dividendPayment, dividendPayment);
            }
        }

        emit SettlementExecuted(token, marketingPaid, dividendPayment);
        return true;
    }

    function _processPendingDividendAllocation(address token) internal {
        TokenTaxState storage state = _tokenStates[token];
        IDividendVault vault = IDividendVault(state.dividendVault);
        if (vault.queuedDividendTokens() == 0 || vault.queuedDividendPayment() == 0) {
            return;
        }

        (uint256 consumedToken, uint256 consumedPayment) = vault.processPendingDividends(0);
        if (consumedToken > 0 || consumedPayment > 0) {
            emit DividendPendingAllocationProcessed(
                token,
                consumedToken,
                consumedPayment,
                vault.queuedDividendTokens(),
                vault.queuedDividendPayment()
            );
        }
    }

    function _processAutoClaims(address token) internal {
        TokenTaxState storage state = _tokenStates[token];
        IDividendVault vault = IDividendVault(state.dividendVault);
        if (!vault.isAutoClaimReady()) {
            return;
        }

        try vault.processAutoClaims() returns (uint256 iterations, uint256 claims, uint256 amount) {
            if (iterations > 0 || claims > 0 || amount > 0) {
                emit DividendAutoClaimTriggered(token, iterations, claims, amount);
            }
        } catch {
            // Auto-claim failures must never block settlement.
        }
    }

    // ============ Reflow ============

    struct ReflowCallbackData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
    }

    function _reflow(address token, bool duringActiveSwap) internal {
        TokenTaxState storage state = _tokenStates[token];
        uint256 budget = state.liquidityBucket < state.maxReflowPayment
            ? state.liquidityBucket
            : state.maxReflowPayment;
        uint256 swapIn = budget / 2;
        state.liquidityBucket -= budget;
        state.lastReflowAt = block.timestamp;

        // Swap half of the payment budget into the token (payment -> token).
        bool zeroForOne = state.paymentIsCurrency0;
        (, int24 currentTick,,) = poolManager.getSlot0(state.poolKey.toId());
        int256 limitTickValue = int256(currentTick)
            + (zeroForOne ? -int256(MAX_REFLOW_TICK_MOVE) : int256(MAX_REFLOW_TICK_MOVE));
        if (limitTickValue <= int256(TickMath.MIN_TICK)) {
            limitTickValue = int256(TickMath.MIN_TICK) + 1;
        } else if (limitTickValue >= int256(TickMath.MAX_TICK)) {
            limitTickValue = int256(TickMath.MAX_TICK) - 1;
        }
        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(int24(limitTickValue));
        ReflowCallbackData memory callbackData = ReflowCallbackData({
            key: state.poolKey,
            zeroForOne: zeroForOne,
            amountIn: swapIn,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        bytes memory result = duringActiveSwap
            ? _swapAndSettle(callbackData)
            : poolManager.unlock(abi.encode(callbackData));
        (uint256 paymentSwapped, uint256 tokenAcquired) = abi.decode(result, (uint256, uint256));
        require(paymentSwapped <= swapIn, "Invalid input delta");
        require(paymentSwapped > 0 && tokenAcquired > 0, "Empty reflow execution");
        uint256 paymentRecovered = swapIn - paymentSwapped;
        state.liquidityBucket += paymentRecovered;

        uint256 paymentForAdd = budget - swapIn;
        Currency payment = _paymentCurrency(state);
        Currency tokenCurrency = _tokenCurrency(state);
        uint256 tokenForAdd = state.liquidityTokenReserve + tokenAcquired;
        state.liquidityTokenReserve = 0;

        IPositionLocker.LiquidityIncreaseResult memory addResult;
        if (tokenForAdd > 0 && paymentForAdd > 0) {
            // PositionManager nets the new principal against accrued LP fees.
            // The locker reports the two components separately through its
            // official position-subscriber callback. Actual returned balances
            // remain the custody source of truth for the two reserve ledgers.
            uint256 paymentBalBefore = _balanceOf(payment) - paymentForAdd;
            uint256 tokenBalBefore = _balanceOf(tokenCurrency);
            require(tokenBalBefore >= tokenForAdd, "Token reserve underfunded");
            uint256 tokenBaseline = tokenBalBefore - tokenForAdd;

            IERC20(Currency.unwrap(tokenCurrency)).safeTransfer(locker, tokenForAdd);
            if (payment.isAddressZero()) {
                if (duringActiveSwap) {
                    addResult = IPositionLocker(locker).increaseLiquidityDuringSwap{value: paymentForAdd}(
                        token,
                        tokenForAdd,
                        paymentForAdd
                    );
                } else {
                    addResult = IPositionLocker(locker).increaseLiquidity{value: paymentForAdd}(
                        token,
                        tokenForAdd,
                        paymentForAdd
                    );
                }
            } else {
                IERC20(Currency.unwrap(payment)).safeTransfer(locker, paymentForAdd);
                if (duringActiveSwap) {
                    addResult = IPositionLocker(locker).increaseLiquidityDuringSwap(token, tokenForAdd, paymentForAdd);
                } else {
                    addResult = IPositionLocker(locker).increaseLiquidity(token, tokenForAdd, paymentForAdd);
                }
            }

            // Both sides remain protocol-owned liquidity inventory. Payment
            // residuals return to the payment bucket; token residuals are
            // carried into the next add. No reflow asset is ever reclassified
            // as burn.
            uint256 paymentBalAfter = _balanceOf(payment);
            require(paymentBalAfter >= paymentBalBefore, "Invalid payment settlement");
            uint256 recoveredAfterAdd = paymentBalAfter - paymentBalBefore;
            paymentRecovered += recoveredAfterAdd;
            state.liquidityBucket += recoveredAfterAdd;
            uint256 tokenBalAfter = _balanceOf(tokenCurrency);
            require(tokenBalAfter >= tokenBaseline, "Invalid token settlement");
            state.liquidityTokenReserve = tokenBalAfter - tokenBaseline;
        } else {
            // Nothing usable on one side; restore all inventory exactly.
            paymentRecovered += paymentForAdd;
            state.liquidityBucket += paymentForAdd;
            state.liquidityTokenReserve = tokenForAdd;
        }

        emit LiquidityReflowExecuted(
            token,
            msg.sender,
            duringActiveSwap,
            budget,
            paymentSwapped,
            tokenAcquired,
            addResult.liquidityAdded,
            addResult.tokenUsed,
            addResult.paymentUsed,
            addResult.tokenFeesAccrued,
            addResult.paymentFeesAccrued,
            paymentRecovered,
            state.liquidityTokenReserve,
            state.liquidityBucket
        );
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");
        return _swapAndSettle(abi.decode(rawData, (ReflowCallbackData)));
    }

    function _swapAndSettle(ReflowCallbackData memory data) internal returns (bytes memory) {
        BalanceDelta delta = poolManager.swap(
            data.key,
            SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: -int256(data.amountIn),
                sqrtPriceLimitX96: data.sqrtPriceLimitX96
            }),
            ""
        );

        Currency inputCurrency = data.zeroForOne ? data.key.currency0 : data.key.currency1;
        Currency outputCurrency = data.zeroForOne ? data.key.currency1 : data.key.currency0;
        int128 inputDelta = data.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = data.zeroForOne ? delta.amount1() : delta.amount0();

        uint256 amountInUsed = inputDelta < 0 ? uint256(uint128(-inputDelta)) : 0;
        if (amountInUsed > 0) {
            uint256 owed = amountInUsed;
            if (inputCurrency.isAddressZero()) {
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(inputCurrency);
                IERC20(Currency.unwrap(inputCurrency)).safeTransfer(address(poolManager), owed);
                poolManager.settle();
            }
        }

        uint256 amountOut = outputDelta > 0 ? uint256(uint128(outputDelta)) : 0;
        if (amountOut > 0) {
            poolManager.take(outputCurrency, address(this), amountOut);
        }

        return abi.encode(amountInUsed, amountOut);
    }

    function _balanceOf(Currency currency) internal view returns (uint256) {
        if (currency.isAddressZero()) {
            return address(this).balance;
        }
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    function _sendPayment(Currency currency, address to, uint256 amount) internal {
        if (currency.isAddressZero()) {
            (bool success,) = payable(to).call{value: amount}("");
            require(success, "Native transfer failed");
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        }
    }

    function _trySendPayment(Currency currency, address to, uint256 amount) internal returns (bool) {
        if (currency.isAddressZero()) {
            (bool success,) = payable(to).call{value: amount}("");
            return success;
        }
        return IERC20(Currency.unwrap(currency)).trySafeTransfer(to, amount);
    }

    receive() external payable {}
}
