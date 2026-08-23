// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionLocker} from "./IPositionLocker.sol";

/**
 * @title PositionLocker
 * @notice Terminal holder of graduation LP position NFTs (the V4 equivalent of
 *         minting V2 LP to 0xdead). Positions can never be decreased, collected
 *         to a third party, or transferred out. The only mutation allowed is a
 *         settler-driven liquidity increase (buyback reflow), which deepens the
 *         locked position; pool fees keep compounding inside the position.
 */
contract PositionLocker is IPositionLocker, ISubscriber {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;

    address public owner;
    address public venue;
    address public settler;

    struct LockedPosition {
        uint256 tokenId;
        bool exists;
        PoolKey poolKey;
    }

    mapping(address => LockedPosition) internal _positions;
    mapping(uint256 => address) public tokenByPositionId;

    uint256 private _activeTokenId;
    BalanceDelta private _activeFeesAccrued;
    bool private _activeFeeNotification;

    event CoordinatesSet(address indexed venue, address indexed settler);
    event PositionLocked(address indexed token, uint256 indexed tokenId);
    event LiquidityIncreased(
        address indexed token,
        uint256 indexed tokenId,
        uint128 liquidityAdded,
        uint256 tokenUsed,
        uint256 paymentUsed,
        uint256 tokenFeesAccrued,
        uint256 paymentFeesAccrued,
        uint256 tokenReturned,
        uint256 paymentReturned
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not Owner");
        _;
    }

    constructor(IPoolManager poolManager_, IPositionManager positionManager_, IAllowanceTransfer permit2_, address owner_) {
        require(address(poolManager_) != address(0), "Invalid manager");
        require(address(positionManager_) != address(0), "Invalid position manager");
        require(address(permit2_) != address(0), "Invalid permit2");
        require(owner_ != address(0), "Invalid owner");
        poolManager = poolManager_;
        positionManager = positionManager_;
        permit2 = permit2_;
        owner = owner_;
    }

    function setCoordinates(address venue_, address settler_) external onlyOwner {
        require(venue == address(0) && settler == address(0), "Coordinates set");
        require(venue_ != address(0) && settler_ != address(0), "Invalid coordinates");
        venue = venue_;
        settler = settler_;
        emit CoordinatesSet(venue_, settler_);
    }

    /// @notice Registers the freshly minted graduation position for a token.
    function registerPosition(address token, uint256 tokenId, PoolKey calldata key) external {
        require(msg.sender == venue, "Only venue");
        require(!_positions[token].exists, "Position registered");

        _positions[token] = LockedPosition({tokenId: tokenId, exists: true, poolKey: key});
        tokenByPositionId[tokenId] = token;
        // PositionManager exposes accrued fees separately only through its
        // subscriber callback. Subscribing the terminal locker lets every
        // later increase distinguish principal consumption from LP fees.
        positionManager.subscribe(tokenId, address(this), abi.encode(token));
        emit PositionLocked(token, tokenId);
    }

    function positionOf(address token) external view returns (uint256 tokenId, bool exists) {
        LockedPosition storage position = _positions[token];
        return (position.tokenId, position.exists);
    }

    /**
     * @notice Adds token + payment amounts (already transferred to this
     *         contract by the settler) into the locked full-range position.
     *         Leftover balances are returned to the settler.
     */
    function increaseLiquidity(
        address token,
        uint256 tokenAmount,
        uint256 paymentAmount
    ) external payable returns (LiquidityIncreaseResult memory result) {
        require(msg.sender == settler, "Only settler");
        require(!poolManager.isUnlocked(), "Pool manager unlocked");
        return _increaseLiquidity(token, tokenAmount, paymentAmount, false);
    }

    /// @notice Adds liquidity while a user swap already has PoolManager
    ///         unlocked. PositionManager exposes a dedicated entrypoint for
    ///         this callback-safe execution mode.
    function increaseLiquidityDuringSwap(
        address token,
        uint256 tokenAmount,
        uint256 paymentAmount
    ) external payable returns (LiquidityIncreaseResult memory result) {
        require(msg.sender == settler, "Only settler");
        require(poolManager.isUnlocked(), "Pool manager locked");
        return _increaseLiquidity(token, tokenAmount, paymentAmount, true);
    }

    function _increaseLiquidity(
        address token,
        uint256 tokenAmount,
        uint256 paymentAmount,
        bool duringActiveSwap
    ) internal returns (LiquidityIncreaseResult memory result) {
        LockedPosition storage position = _positions[token];
        require(position.exists, "Unknown position");

        PoolKey memory key = position.poolKey;
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        Currency paymentCurrency = tokenIsCurrency0 ? key.currency1 : key.currency0;
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance >= tokenAmount, "Token amount missing");
        uint256 tokenBalanceBaseline = tokenBalance - tokenAmount;
        uint256 paymentBalanceBaseline;
        if (paymentCurrency.isAddressZero()) {
            require(msg.value == paymentAmount, "Invalid native payment");
            paymentBalanceBaseline = address(this).balance - paymentAmount;
        } else {
            require(msg.value == 0, "Unexpected native payment");
            uint256 paymentBalance = IERC20(Currency.unwrap(paymentCurrency)).balanceOf(address(this));
            require(paymentBalance >= paymentAmount, "Payment amount missing");
            paymentBalanceBaseline = paymentBalance - paymentAmount;
        }
        uint256 amount0 = tokenIsCurrency0 ? tokenAmount : paymentAmount;
        uint256 amount1 = tokenIsCurrency0 ? paymentAmount : tokenAmount;

        uint128 liquidity = _liquidityForAmounts(key, amount0, amount1);
        // Trim a hair so PositionManager's round-up settlement never exceeds
        // the exact balances we hold.
        liquidity = liquidity > 10_000 ? liquidity - liquidity / 10_000 : (liquidity > 0 ? liquidity - 1 : 0);
        if (liquidity == 0) {
            (uint256 tokenReturned, uint256 paymentReturned) = _refundAboveBaselines(
                paymentCurrency,
                token,
                tokenBalanceBaseline,
                paymentBalanceBaseline
            );
            emit LiquidityIncreased(token, position.tokenId, 0, 0, 0, 0, 0, tokenReturned, paymentReturned);
            return result;
        }

        _ensureApprovals(key);

        // INCREASE_LIQUIDITY nets principal against fees accrued inside the
        // position. CLOSE_CURRENCY returns both unused principal and fee
        // credits; the subscriber callback records the fee component exactly.
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(position.tokenId, liquidity, uint128(amount0), uint128(amount1), bytes(""));
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        params[3] = abi.encode(key.currency0, address(this));

        uint128 liquidityBefore = positionManager.getPositionLiquidity(position.tokenId);
        require(_activeTokenId == 0, "Liquidity operation active");
        _activeTokenId = position.tokenId;
        _activeFeesAccrued = BalanceDelta.wrap(0);
        _activeFeeNotification = false;

        // Only this operation's native payment is exposed to PositionManager.
        // Unsolicited balances cannot alter its accounting or be swept out.
        uint256 nativeValue = paymentCurrency.isAddressZero() ? paymentAmount : 0;
        if (duringActiveSwap) {
            positionManager.modifyLiquiditiesWithoutUnlock{value: nativeValue}(actions, params);
        } else {
            positionManager.modifyLiquidities{value: nativeValue}(
                abi.encode(actions, params),
                block.timestamp
            );
        }

        require(_activeFeeNotification, "Missing fee accounting");
        BalanceDelta feesAccrued = _activeFeesAccrued;
        _activeTokenId = 0;
        _activeFeesAccrued = BalanceDelta.wrap(0);
        _activeFeeNotification = false;

        int128 fee0 = feesAccrued.amount0();
        int128 fee1 = feesAccrued.amount1();
        require(fee0 >= 0 && fee1 >= 0, "Invalid accrued fees");
        result.tokenFeesAccrued = uint256(uint128(tokenIsCurrency0 ? fee0 : fee1));
        result.paymentFeesAccrued = uint256(uint128(tokenIsCurrency0 ? fee1 : fee0));

        // Refund only the balance created by this operation. Assets sent
        // directly to the terminal locker before the call stay outside the
        // reflow ledger and cannot spoof leftovers or DoS exact accounting.
        (uint256 tokenLeft, uint256 paymentLeft) = _refundAboveBaselines(
            paymentCurrency,
            token,
            tokenBalanceBaseline,
            paymentBalanceBaseline
        );

        require(tokenLeft <= tokenAmount + result.tokenFeesAccrued, "Invalid token return");
        require(paymentLeft <= paymentAmount + result.paymentFeesAccrued, "Invalid payment return");
        result.tokenUsed = tokenAmount + result.tokenFeesAccrued - tokenLeft;
        result.paymentUsed = paymentAmount + result.paymentFeesAccrued - paymentLeft;

        uint128 liquidityAfter = positionManager.getPositionLiquidity(position.tokenId);
        require(liquidityAfter > liquidityBefore, "Liquidity not increased");
        result.liquidityAdded = liquidityAfter - liquidityBefore;

        emit LiquidityIncreased(
            token,
            position.tokenId,
            result.liquidityAdded,
            result.tokenUsed,
            result.paymentUsed,
            result.tokenFeesAccrued,
            result.paymentFeesAccrued,
            tokenLeft,
            paymentLeft
        );
    }

    // ============ PositionManager subscriber ============

    function notifySubscribe(uint256 tokenId, bytes memory data) external view {
        require(msg.sender == address(positionManager), "Only position manager");
        address token = abi.decode(data, (address));
        require(tokenByPositionId[tokenId] == token && _positions[token].tokenId == tokenId, "Invalid subscription");
    }

    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued) external {
        require(msg.sender == address(positionManager), "Only position manager");
        require(tokenId == _activeTokenId && liquidityChange > 0, "Unexpected liquidity notification");
        require(!_activeFeeNotification, "Duplicate fee notification");
        _activeFeesAccrued = feesAccrued;
        _activeFeeNotification = true;
    }

    function notifyUnsubscribe(uint256) external view {
        require(msg.sender == address(positionManager), "Only position manager");
        revert("Position locked");
    }

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external view {
        require(msg.sender == address(positionManager), "Only position manager");
        revert("Position locked");
    }

    function _liquidityForAmounts(
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    function _ensureApprovals(PoolKey memory key) internal {
        _approveCurrency(key.currency0);
        _approveCurrency(key.currency1);
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

    /// @dev Returns only operation-attributable residual balances. Pre-existing
    ///      unsolicited balances remain locked and cannot contaminate ledgers.
    function _refundAboveBaselines(
        Currency paymentCurrency,
        address token,
        uint256 tokenBalanceBaseline,
        uint256 paymentBalanceBaseline
    ) internal returns (uint256 tokenLeft, uint256 paymentLeft) {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance >= tokenBalanceBaseline, "Invalid token baseline");
        tokenLeft = tokenBalance - tokenBalanceBaseline;
        if (tokenLeft > 0) {
            IERC20(token).transfer(settler, tokenLeft);
        }

        if (paymentCurrency.isAddressZero()) {
            require(address(this).balance >= paymentBalanceBaseline, "Invalid payment baseline");
            paymentLeft = address(this).balance - paymentBalanceBaseline;
            if (paymentLeft > 0) {
                (bool success,) = payable(settler).call{value: paymentLeft}("");
                require(success, "Refund failed");
            }
        } else {
            address paymentAsset = Currency.unwrap(paymentCurrency);
            uint256 paymentBalance = IERC20(paymentAsset).balanceOf(address(this));
            require(paymentBalance >= paymentBalanceBaseline, "Invalid payment baseline");
            paymentLeft = paymentBalance - paymentBalanceBaseline;
            if (paymentLeft > 0) {
                IERC20(paymentAsset).transfer(settler, paymentLeft);
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
