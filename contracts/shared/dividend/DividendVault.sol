// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/**
 * @title DividendVault
 * @notice Epoch-based dividend ledger for graduated tax tokens.
 * @dev Dividend tax is attributed when token tax is collected. Payment received
 *      later from TaxProcessor is allocated into those existing epochs.
 */
contract DividendVault is ReentrancyGuard {
    using Checkpoints for Checkpoints.Trace256;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_EPOCHS_PER_ALLOCATION = 20;
    uint256 public constant DEFAULT_AUTO_CLAIM_THRESHOLD = 20 ether;
    uint256 public constant DEFAULT_AUTO_CLAIM_MAX_COUNT = 20;
    uint256 public constant DEFAULT_AUTO_CLAIM_GAS_LIMIT = 5_000_000;
    uint256 public constant DEFAULT_AUTO_CLAIM_PER_HOLDER_GAS_LIMIT = 200_000;
    uint256 public constant MAX_AUTO_CLAIM_MAX_COUNT = 100;
    uint256 public constant MAX_AUTO_CLAIM_GAS_LIMIT = 5_000_000;
    uint256 public constant MAX_AUTO_CLAIM_PER_HOLDER_GAS_LIMIT = 300_000;
    uint256 private constant MIN_AUTO_CLAIM_PER_HOLDER_GAS_LIMIT = 50_000;
    uint256 private constant AUTO_CLAIM_NATIVE_PAYMENT_GAS = 30_000;
    uint256 private constant AUTO_CLAIM_LOOP_GAS_BUFFER = 60_000;

    address public owner;
    address public token;
    address public paymentToken;
    bool public isNativePool;
    uint256 public minHoldingForDividend;

    address public processor;
    uint256 public currentEpoch;
    uint256 public lastFinalizedEpoch;
    uint256 public firstPendingEpoch = 1;
    uint256 public currentEligibleShares;
    uint256 public totalDividendPerShare;
    uint256 public queuedDividendTokens;
    uint256 public queuedDividendPayment;
    uint256 public accountedDividendPayment;
    uint256 public claimableDividendPayment;
    uint256 public claimedDividendPayment;
    uint256 public pendingDividendDust;
    uint256 public totalDividendPaymentReceived;
    uint256 public totalDividendTokenProcessed;

    uint256 public autoClaimThreshold;
    uint256 public maxAutoClaimCount;
    uint256 public autoClaimGasLimit;
    uint256 public autoClaimPerHolderGasLimit;
    uint256 public nextAutoClaimIndex;

    struct EpochData {
        uint256 snapshotTotalShares;
        uint256 dividendTokenAmount;
        uint256 remainingDividendTokenAmount;
        uint256 paymentAllocated;
        uint256 cumulativeDividendPerShare;
    }

    struct HolderState {
        uint256 currentShare;
        uint256 nextClaimEpoch;
        uint256 unclaimed;
        uint256 claimed;
    }

    mapping(uint256 => EpochData) public epochs;
    mapping(address => bool) public isExcludedFromDividend;
    mapping(address => HolderState) private _holderStates;
    mapping(address => Checkpoints.Trace256) private _shareCheckpoints;
    address[] private _autoClaimHolders;
    mapping(address => uint256) private _autoClaimHolderIndex;
    bool private _initialized;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ProcessorSet(address indexed processor);
    event ExcludedUpdated(address indexed account, bool excluded);
    event ShareSynced(address indexed account, uint256 epoch, uint256 eligibleShare);
    event DividendEpochCreated(uint256 indexed epochId, uint256 snapshotTotalShares, uint256 dividendTokenAmount);
    event DividendPaymentQueued(uint256 tokenAmount, uint256 paymentAmount, uint256 queuedTokens, uint256 queuedPayment);
    event DividendPaymentAllocated(uint256 tokenAmount, uint256 paymentAmount, uint256 remainingTokens, uint256 remainingPayment);
    event EpochFinalized(uint256 indexed epochId, uint256 paymentAllocated, uint256 cumulativeDividendPerShare);
    event DividendClaimed(address indexed holder, uint256 amount, uint256 fromEpoch, uint256 toEpoch);
    event AutoClaimConfigUpdated(uint256 threshold, uint256 maxCount, uint256 gasLimit, uint256 perHolderGasLimit);
    event AutoClaimProcessed(
        address indexed caller,
        uint256 iterations,
        uint256 claims,
        uint256 amount,
        uint256 nextIndex,
        uint256 holderCount
    );

    modifier onlyToken() {
        require(msg.sender == token, "Only token");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyProcessor() {
        require(msg.sender == processor, "Only processor");
        _;
    }

    modifier onlySelf() {
        require(msg.sender == address(this), "Only self");
        _;
    }

    function initialize(
        address initialOwner,
        address token_,
        address paymentToken_,
        bool isNativePool_,
        uint256 minHoldingForDividend_,
        uint256 autoClaimThreshold_,
        address processor_
    ) external {
        require(!_initialized, "Already initialized");
        require(initialOwner != address(0), "Invalid owner");
        require(token_ != address(0), "Invalid token");

        _initialized = true;
        owner = initialOwner;
        token = token_;
        paymentToken = paymentToken_;
        isNativePool = isNativePool_;
        minHoldingForDividend = minHoldingForDividend_;
        processor = processor_;
        autoClaimThreshold = autoClaimThreshold_;
        maxAutoClaimCount = DEFAULT_AUTO_CLAIM_MAX_COUNT;
        autoClaimGasLimit = DEFAULT_AUTO_CLAIM_GAS_LIMIT;
        autoClaimPerHolderGasLimit = DEFAULT_AUTO_CLAIM_PER_HOLDER_GAS_LIMIT;

        emit OwnershipTransferred(address(0), initialOwner);
        emit ProcessorSet(processor_);
        emit AutoClaimConfigUpdated(
            autoClaimThreshold,
            maxAutoClaimCount,
            autoClaimGasLimit,
            autoClaimPerHolderGasLimit
        );
    }

    function setProcessor(address processor_) external onlyOwner {
        require(processor == address(0), "Processor already set");
        require(processor_ != address(0), "Invalid processor");
        processor = processor_;
        emit ProcessorSet(processor_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function currentShare(address account) external view returns (uint256) {
        return _holderStates[account].currentShare;
    }

    function nextClaimEpoch(address account) external view returns (uint256) {
        return _holderStates[account].nextClaimEpoch;
    }

    function claimedDividend(address account) external view returns (uint256) {
        return _holderStates[account].claimed;
    }

    function unclaimedDividend(address account) external view returns (uint256) {
        return pendingDividend(account);
    }

    function autoClaimHolderCount() external view returns (uint256) {
        return _autoClaimHolders.length;
    }

    function autoClaimHolderAt(uint256 index) external view returns (address) {
        return _autoClaimHolders[index];
    }

    function isAutoClaimReady() public view returns (bool) {
        return autoClaimThreshold > 0
            && maxAutoClaimCount > 0
            && _autoClaimHolders.length > 0
            && claimableDividendPayment >= autoClaimThreshold;
    }

    function autoClaimState()
        external
        view
        returns (
            uint256 threshold,
            uint256 claimablePayment,
            bool ready,
            uint256 maxCount,
            uint256 gasLimit,
            uint256 perHolderGasLimit,
            uint256 nextIndex,
            uint256 holderCount
        )
    {
        return (
            autoClaimThreshold,
            claimableDividendPayment,
            isAutoClaimReady(),
            maxAutoClaimCount,
            autoClaimGasLimit,
            autoClaimPerHolderGasLimit,
            nextAutoClaimIndex,
            _autoClaimHolders.length
        );
    }

    function setAutoClaimConfig(
        uint256 threshold,
        uint256 maxCount,
        uint256 gasLimit,
        uint256 perHolderGasLimit
    ) external onlyOwner {
        if (threshold > 0) {
            require(maxCount > 0 && maxCount <= MAX_AUTO_CLAIM_MAX_COUNT, "Invalid count");
            require(gasLimit > 0 && gasLimit <= MAX_AUTO_CLAIM_GAS_LIMIT, "Invalid gas");
            require(
                perHolderGasLimit >= MIN_AUTO_CLAIM_PER_HOLDER_GAS_LIMIT
                    && perHolderGasLimit <= MAX_AUTO_CLAIM_PER_HOLDER_GAS_LIMIT,
                "Invalid holder gas"
            );
            require(gasLimit >= perHolderGasLimit, "Gas too low");
        }

        autoClaimThreshold = threshold;
        maxAutoClaimCount = maxCount;
        autoClaimGasLimit = gasLimit;
        autoClaimPerHolderGasLimit = perHolderGasLimit;

        emit AutoClaimConfigUpdated(threshold, maxCount, gasLimit, perHolderGasLimit);
    }

    function setExcluded(address account, bool excluded) external {
        require(msg.sender == token || msg.sender == owner, "Unauthorized");

        bool previous = isExcludedFromDividend[account];
        if (previous == excluded) {
            return;
        }

        _accrueAccount(account);
        isExcludedFromDividend[account] = excluded;

        HolderState storage holder = _holderStates[account];
        uint256 oldShare = holder.currentShare;
        if (oldShare > 0) {
            currentEligibleShares -= oldShare;
            holder.currentShare = 0;
            _shareCheckpoints[account].push(currentEpoch, 0);
            _syncAutoClaimHolder(account, 0);
            emit ShareSynced(account, currentEpoch, 0);
        }

        if (!excluded) {
            _syncShare(account, IERC20(token).balanceOf(account));
        }

        emit ExcludedUpdated(account, excluded);
    }

    function syncShare(address account, uint256 newBalance) external onlyToken {
        _syncShare(account, newBalance);
    }

    function createDividendEpoch(uint256 dividendTokenAmount) external returns (uint256) {
        require(msg.sender == token || msg.sender == processor, "Unauthorized");
        return _createDividendEpoch(dividendTokenAmount);
    }

    function _createDividendEpoch(uint256 dividendTokenAmount) internal returns (uint256) {
        if (dividendTokenAmount == 0 || currentEligibleShares == 0) {
            return 0;
        }

        currentEpoch += 1;
        epochs[currentEpoch] = EpochData({
            snapshotTotalShares: currentEligibleShares,
            dividendTokenAmount: dividendTokenAmount,
            remainingDividendTokenAmount: dividendTokenAmount,
            paymentAllocated: 0,
            cumulativeDividendPerShare: totalDividendPerShare
        });

        if (firstPendingEpoch == 0 || firstPendingEpoch > currentEpoch) {
            firstPendingEpoch = currentEpoch;
        }

        emit DividendEpochCreated(currentEpoch, currentEligibleShares, dividendTokenAmount);
        return currentEpoch;
    }

    function notifyDividendPayment(
        uint256 processedDividendTokenAmount,
        uint256 paymentAmount
    ) external payable onlyProcessor {
        require(processedDividendTokenAmount > 0, "No dividend token processed");
        require(paymentAmount > 0, "No dividend payment");

        if (isNativePool) {
            require(msg.value == paymentAmount, "Invalid native payment");
        } else {
            require(msg.value == 0, "Unexpected native payment");
        }

        uint256 accountedAfter = accountedDividendPayment + paymentAmount;
        require(_paymentBalance() >= accountedAfter, "Payment not received");

        accountedDividendPayment = accountedAfter;
        totalDividendPaymentReceived += paymentAmount;
        totalDividendTokenProcessed += processedDividendTokenAmount;
        queuedDividendTokens += processedDividendTokenAmount;
        queuedDividendPayment += paymentAmount;

        emit DividendPaymentQueued(
            processedDividendTokenAmount,
            paymentAmount,
            queuedDividendTokens,
            queuedDividendPayment
        );

        _allocatePending(MAX_EPOCHS_PER_ALLOCATION);
        require(queuedDividendTokens == 0 || firstPendingEpoch <= currentEpoch, "No dividend epoch");
    }

    function processPendingDividends(
        uint256 maxEpochs
    ) external returns (uint256 consumedToken, uint256 consumedPayment) {
        uint256 limit = maxEpochs == 0 || maxEpochs > MAX_EPOCHS_PER_ALLOCATION
            ? MAX_EPOCHS_PER_ALLOCATION
            : maxEpochs;
        return _allocatePending(limit);
    }

    function pendingDividend(address holder) public view returns (uint256 amount) {
        HolderState storage state = _holderStates[holder];
        amount = state.unclaimed;

        if (lastFinalizedEpoch == 0) {
            return amount;
        }

        uint256 startEpoch = state.nextClaimEpoch;
        if (startEpoch == 0) {
            startEpoch = _initialClaimEpoch(holder);
        }
        if (startEpoch > lastFinalizedEpoch) {
            return amount;
        }

        amount += _calculateDividend(holder, startEpoch, lastFinalizedEpoch);
    }

    function claimDividend() external nonReentrant returns (uint256) {
        return _claimDividendFor(msg.sender);
    }

    function claimDividendFor(address holder) external onlyToken nonReentrant returns (uint256) {
        return _claimDividendFor(holder);
    }

    function processAutoClaims()
        external
        nonReentrant
        returns (uint256 iterations, uint256 claims, uint256 amount)
    {
        if (!isAutoClaimReady()) {
            return (0, 0, 0);
        }

        uint256 startGas = gasleft();
        uint256 holderCount = _autoClaimHolders.length;
        uint256 index = nextAutoClaimIndex;

        while (
            iterations < maxAutoClaimCount
                && holderCount > 0
                && claimableDividendPayment > 0
                && startGas - gasleft() < autoClaimGasLimit
                && gasleft() > autoClaimPerHolderGasLimit + AUTO_CLAIM_LOOP_GAS_BUFFER
        ) {
            if (index >= holderCount) {
                index = 0;
            }

            address holder = _autoClaimHolders[index];
            iterations += 1;

            if (!_isAutoClaimEligible(holder)) {
                _removeAutoClaimHolder(holder);
                holderCount = _autoClaimHolders.length;
                if (index >= holderCount) {
                    index = 0;
                }
                continue;
            }

            try this.executeAutoClaim{gas: autoClaimPerHolderGasLimit}(holder) returns (
                bool success,
                uint256 claimed
            ) {
                if (success && claimed > 0) {
                    claims += 1;
                    amount += claimed;
                }
            } catch {
                index += 1;
                if (index >= holderCount) {
                    index = 0;
                }
                continue;
            }

            index += 1;
            if (index >= holderCount) {
                index = 0;
            }
        }

        holderCount = _autoClaimHolders.length;
        nextAutoClaimIndex = holderCount == 0 ? 0 : index % holderCount;
        emit AutoClaimProcessed(msg.sender, iterations, claims, amount, nextAutoClaimIndex, holderCount);
    }

    function executeAutoClaim(address holder) external onlySelf returns (bool success, uint256 amount) {
        return _tryAutoClaimDividendFor(holder);
    }

    function shareAtEpoch(address holder, uint256 epochId) external view returns (uint256) {
        return _shareAtEpoch(holder, epochId);
    }

    function _syncShare(address account, uint256 newBalance) internal {
        if (account == address(0) || isExcludedFromDividend[account]) {
            return;
        }

        _accrueAccount(account);

        HolderState storage holder = _holderStates[account];
        uint256 oldShare = holder.currentShare;
        uint256 newShare = _eligibleShare(newBalance);
        if (oldShare == newShare) {
            return;
        }

        holder.currentShare = newShare;
        if (newShare > oldShare) {
            currentEligibleShares += newShare - oldShare;
        } else {
            currentEligibleShares -= oldShare - newShare;
        }

        _shareCheckpoints[account].push(currentEpoch, newShare);
        _syncAutoClaimHolder(account, newShare);
        emit ShareSynced(account, currentEpoch, newShare);
    }

    function _claimDividendFor(address holder) internal returns (uint256 amount) {
        HolderState storage state = _holderStates[holder];
        uint256 fromEpoch = state.nextClaimEpoch == 0 ? _initialClaimEpoch(holder) : state.nextClaimEpoch;
        uint256 toEpoch = lastFinalizedEpoch;

        _accrueAccount(holder);

        amount = _availableClaimAmount(state.unclaimed);
        require(amount > 0, "No dividend");

        state.unclaimed -= amount;
        state.claimed += amount;
        claimedDividendPayment += amount;
        _sendPayment(holder, amount);
        _releaseAccountedPayment(amount);
        emit DividendClaimed(holder, amount, fromEpoch, toEpoch);
    }

    function _tryAutoClaimDividendFor(address holder) internal returns (bool success, uint256 amount) {
        if (!_isAutoClaimEligible(holder)) {
            return (false, 0);
        }

        HolderState storage state = _holderStates[holder];
        uint256 fromEpoch = state.nextClaimEpoch == 0 ? _initialClaimEpoch(holder) : state.nextClaimEpoch;
        uint256 toEpoch = lastFinalizedEpoch;

        _accrueAccount(holder);

        amount = _availableClaimAmount(state.unclaimed);
        if (amount == 0) {
            return (false, 0);
        }

        state.unclaimed -= amount;
        if (!_trySendPayment(holder, amount)) {
            state.unclaimed += amount;
            return (false, 0);
        }

        state.claimed += amount;
        claimedDividendPayment += amount;
        _releaseAccountedPayment(amount);
        emit DividendClaimed(holder, amount, fromEpoch, toEpoch);
        return (true, amount);
    }

    function _allocatePending(
        uint256 maxEpochs
    ) internal returns (uint256 consumedToken, uint256 consumedPayment) {
        if (maxEpochs == 0 || queuedDividendTokens == 0 || queuedDividendPayment == 0) {
            return (0, 0);
        }

        uint256 remainingToken = queuedDividendTokens;
        uint256 remainingPayment = queuedDividendPayment;
        uint256 cursor = firstPendingEpoch;
        uint256 processedEpochs = 0;

        while (remainingToken > 0 && cursor <= currentEpoch && processedEpochs < maxEpochs) {
            EpochData storage epoch = epochs[cursor];
            uint256 epochRemaining = epoch.remainingDividendTokenAmount;

            if (epochRemaining == 0) {
                cursor += 1;
                processedEpochs += 1;
                continue;
            }

            uint256 consumed = epochRemaining < remainingToken ? epochRemaining : remainingToken;
            uint256 paymentShare = consumed == remainingToken
                ? remainingPayment
                : remainingPayment * consumed / remainingToken;

            epoch.remainingDividendTokenAmount = epochRemaining - consumed;
            epoch.paymentAllocated += paymentShare;

            remainingToken -= consumed;
            remainingPayment -= paymentShare;

            if (epoch.remainingDividendTokenAmount == 0) {
                _finalizeEpoch(cursor);
                cursor += 1;
            }

            processedEpochs += 1;
        }

        consumedToken = queuedDividendTokens - remainingToken;
        consumedPayment = queuedDividendPayment - remainingPayment;
        queuedDividendTokens = remainingToken;
        queuedDividendPayment = remainingPayment;
        firstPendingEpoch = cursor;

        if (consumedToken > 0 || consumedPayment > 0) {
            emit DividendPaymentAllocated(consumedToken, consumedPayment, remainingToken, remainingPayment);
        }
    }

    function _finalizeEpoch(uint256 epochId) internal {
        EpochData storage epoch = epochs[epochId];
        uint256 paymentForShares = epoch.paymentAllocated + pendingDividendDust;
        uint256 allocatedPayment = 0;

        if (epoch.snapshotTotalShares > 0 && paymentForShares > 0) {
            uint256 dividendPerShare = paymentForShares * PRECISION / epoch.snapshotTotalShares;
            if (dividendPerShare > 0) {
                allocatedPayment = dividendPerShare * epoch.snapshotTotalShares / PRECISION;
                totalDividendPerShare += dividendPerShare;
                claimableDividendPayment += allocatedPayment;
            }
        }

        pendingDividendDust = paymentForShares - allocatedPayment;
        epoch.cumulativeDividendPerShare = totalDividendPerShare;
        lastFinalizedEpoch = epochId;
        emit EpochFinalized(epochId, allocatedPayment, epoch.cumulativeDividendPerShare);
    }

    function _accrueAccount(address account) internal {
        if (account == address(0)) {
            return;
        }

        HolderState storage holder = _holderStates[account];

        if (lastFinalizedEpoch == 0) {
            if (holder.nextClaimEpoch == 0) {
                holder.nextClaimEpoch = currentEpoch + 1;
            }
            return;
        }

        uint256 startEpoch = holder.nextClaimEpoch;
        if (startEpoch == 0) {
            startEpoch = _initialClaimEpoch(account);
            holder.nextClaimEpoch = startEpoch;
        }

        uint256 endEpoch = lastFinalizedEpoch;
        if (startEpoch > endEpoch) {
            return;
        }

        holder.unclaimed += _calculateDividend(account, startEpoch, endEpoch);
        holder.nextClaimEpoch = endEpoch + 1;
    }

    function _calculateDividend(address account, uint256 startEpoch, uint256 endEpoch) internal view returns (uint256 amount) {
        if (startEpoch > endEpoch) {
            return 0;
        }

        uint256 len = _shareCheckpoints[account].length();
        if (len == 0) {
            return 0;
        }

        uint256 currentStart = startEpoch;
        uint256 currentShareValue = _shareAtEpoch(account, startEpoch);
        uint256 index = _firstCheckpointIndexAtOrAfter(account, startEpoch);

        for (uint256 i = index; i < len; i++) {
            Checkpoints.Checkpoint256 memory checkpoint = _shareCheckpoints[account].at(uint32(i));
            uint256 segmentSwitchEpoch = checkpoint._key + 1;

            if (segmentSwitchEpoch > endEpoch) {
                break;
            }

            uint256 segmentEnd = segmentSwitchEpoch - 1;
            if (currentShareValue > 0 && segmentEnd >= currentStart) {
                amount += currentShareValue
                    * (_cumulativeDividendPerShare(segmentEnd) - _cumulativeDividendPerShare(currentStart - 1))
                    / PRECISION;
            }

            currentShareValue = checkpoint._value;
            currentStart = segmentSwitchEpoch;
        }

        if (currentShareValue > 0 && currentStart <= endEpoch) {
            amount += currentShareValue
                * (_cumulativeDividendPerShare(endEpoch) - _cumulativeDividendPerShare(currentStart - 1))
                / PRECISION;
        }
    }

    function _initialClaimEpoch(address account) internal view returns (uint256 startEpoch) {
        startEpoch = 1;

        uint256 len = _shareCheckpoints[account].length();
        if (len == 0) {
            return startEpoch;
        }

        for (uint256 i = 0; i < len; i++) {
            Checkpoints.Checkpoint256 memory checkpoint = _shareCheckpoints[account].at(uint32(i));
            if (checkpoint._value > 0) {
                startEpoch = checkpoint._key + 1;
                break;
            }
        }
    }

    function _firstCheckpointIndexAtOrAfter(address account, uint256 epoch) internal view returns (uint256) {
        uint256 len = _shareCheckpoints[account].length();
        uint256 low = 0;
        uint256 high = len;

        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (_shareCheckpoints[account].at(uint32(mid))._key < epoch) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        return low;
    }

    function _shareAtEpoch(address holder, uint256 epochId) internal view returns (uint256) {
        if (epochId == 0) {
            return _shareCheckpoints[holder].upperLookup(0);
        }
        return _shareCheckpoints[holder].upperLookup(epochId - 1);
    }

    function _cumulativeDividendPerShare(uint256 epochId) internal view returns (uint256) {
        if (epochId == 0) {
            return 0;
        }
        return epochs[epochId].cumulativeDividendPerShare;
    }

    function _eligibleShare(uint256 balance) internal view returns (uint256) {
        if (balance == 0) {
            return 0;
        }
        if (minHoldingForDividend > 0 && balance < minHoldingForDividend) {
            return 0;
        }
        return balance;
    }

    function _sendPayment(address to, uint256 amount) internal {
        if (isNativePool) {
            (bool success,) = payable(to).call{value: amount}("");
            require(success, "Native transfer failed");
        } else {
            (bool success, bytes memory returndata) = paymentToken.call(
                abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
            );
            require(
                success && (returndata.length == 0 || abi.decode(returndata, (bool))),
                "Token transfer failed"
            );
        }
    }

    function _trySendPayment(address to, uint256 amount) internal returns (bool) {
        if (isNativePool) {
            (bool nativeSuccess,) = payable(to).call{value: amount, gas: AUTO_CLAIM_NATIVE_PAYMENT_GAS}("");
            return nativeSuccess;
        }

        (bool success, bytes memory returndata) = paymentToken.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        return success && (returndata.length == 0 || abi.decode(returndata, (bool)));
    }

    function _releaseAccountedPayment(uint256 amount) internal {
        require(accountedDividendPayment >= amount, "Dividend accounting underflow");
        require(claimableDividendPayment >= amount, "Claimable accounting underflow");
        unchecked {
            accountedDividendPayment -= amount;
            claimableDividendPayment -= amount;
        }
    }

    function _availableClaimAmount(uint256 requested) internal view returns (uint256) {
        uint256 available = accountedDividendPayment;
        if (claimableDividendPayment < available) {
            available = claimableDividendPayment;
        }
        uint256 balance = _paymentBalance();
        if (balance < available) {
            available = balance;
        }
        return requested < available ? requested : available;
    }

    function _paymentBalance() internal view returns (uint256) {
        return isNativePool
            ? address(this).balance
            : IERC20(paymentToken).balanceOf(address(this));
    }

    function _syncAutoClaimHolder(address account, uint256 share) internal {
        if (_isAutoClaimEligibleBalance(account, share)) {
            _addAutoClaimHolder(account);
        } else {
            _removeAutoClaimHolder(account);
            uint256 holderCount = _autoClaimHolders.length;
            if (holderCount == 0) {
                nextAutoClaimIndex = 0;
            } else if (nextAutoClaimIndex >= holderCount) {
                nextAutoClaimIndex = 0;
            }
        }
    }

    function _isAutoClaimEligible(address account) internal view returns (bool) {
        if (account == address(0) || isExcludedFromDividend[account]) {
            return false;
        }
        return _isAutoClaimEligibleBalance(account, _eligibleShare(IERC20(token).balanceOf(account)));
    }

    function _isAutoClaimEligibleBalance(address account, uint256 share) internal view returns (bool) {
        return account != address(0)
            && !isExcludedFromDividend[account]
            && share > 0;
    }

    function _addAutoClaimHolder(address account) internal {
        if (_autoClaimHolderIndex[account] != 0) {
            return;
        }

        _autoClaimHolders.push(account);
        _autoClaimHolderIndex[account] = _autoClaimHolders.length;
    }

    function _removeAutoClaimHolder(address account) internal {
        uint256 indexPlusOne = _autoClaimHolderIndex[account];
        if (indexPlusOne == 0) {
            return;
        }

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _autoClaimHolders.length - 1;

        if (index != lastIndex) {
            address lastAccount = _autoClaimHolders[lastIndex];
            _autoClaimHolders[index] = lastAccount;
            _autoClaimHolderIndex[lastAccount] = indexPlusOne;
        }

        _autoClaimHolders.pop();
        delete _autoClaimHolderIndex[account];
    }

    receive() external payable {}
}
