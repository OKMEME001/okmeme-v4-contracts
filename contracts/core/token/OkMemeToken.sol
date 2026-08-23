// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/TaxConfig.sol";
import "../../shared/interfaces/IDividendVault.sol";

/**
 * @title OkMemeToken
 * @notice OK.MEME launch token. Plain ERC20 balances — post-graduation swap tax
 *         is collected by the shared Uniswap V4 hook in the payment currency,
 *         not via fee-on-transfer. The token keeps dividend share checkpointing
 *         so the epoch-based DividendVault stays accurate on every transfer.
 */
contract OkMemeToken is ERC20, Ownable {
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 32;
    TaxConfig private _taxConfig;

    address public immutable launchpad;
    address public immutable deploymentFactory;
    address public immutable paymentToken;
    bool public immutable isNativePool;

    /// @notice Uniswap V4 PoolId of the graduation pool (zero until graduated).
    bytes32 public poolId;
    bool public graduated;
    /// @notice 0 = free, 1 = only owner/launchpad can send, 2 = transfers must involve owner/launchpad.
    uint8 public transferMode;

    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAX_TOTAL_FEE = 1_000;

    address public dividendVault;

    mapping(address => bool) public isExcludedFromDividend;

    event DividendClaimed(address indexed holder, uint256 amount);
    event Graduated(bytes32 indexed poolId);
    event DividendExclusionUpdated(address indexed account, bool excluded);

    modifier onlyLaunchpadOrOwner() {
        require(msg.sender == launchpad || msg.sender == owner(), "Unauthorized");
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address launchpad_,
        address paymentToken_,
        TaxConfig memory tax_
    ) ERC20(name_, symbol_) Ownable(launchpad_) {
        require(launchpad_ != address(0), "Invalid launchpad");
        require(bytes(name_).length > 0 && bytes(name_).length <= MAX_NAME_BYTES, "Invalid name length");
        require(bytes(symbol_).length > 0 && bytes(symbol_).length <= MAX_SYMBOL_BYTES, "Invalid symbol length");
        require(
            uint256(tax_.marketingFee) + tax_.holderDividendFee + tax_.buybackFee + tax_.burnFee <= MAX_TOTAL_FEE,
            "Total fee exceeds max"
        );
        if (tax_.marketingFee > 0) {
            require(tax_.marketingWallet != address(0), "Invalid marketing wallet");
        }

        launchpad = launchpad_;
        deploymentFactory = msg.sender;
        paymentToken = paymentToken_;
        isNativePool = paymentToken_ == address(0);
        _taxConfig = tax_;
        transferMode = 2;

        _mint(launchpad_, totalSupply_);
    }

    /**
     * @notice Wire the dividend vault and seed the dividend-exclusion set.
     * @param dividendVault_ per-token DividendVault clone
     * @param dividendExcluded protocol addresses that must never earn dividends
     *        (PoolManager, venue, locker, settler, hook, platform vault, ...)
     */
    function initializeModules(address dividendVault_, address[] calldata dividendExcluded) external {
        require(msg.sender == deploymentFactory || msg.sender == owner(), "Unauthorized");
        require(dividendVault == address(0), "Modules initialized");
        require(dividendVault_ != address(0), "Invalid module");

        dividendVault = dividendVault_;

        _setDividendExcluded(address(this), true);
        _setDividendExcluded(launchpad, true);
        _setDividendExcluded(address(0), true);
        _setDividendExcluded(address(0xdead), true);
        _setDividendExcluded(dividendVault_, true);
        if (_taxConfig.marketingWallet != address(0)) {
            _setDividendExcluded(_taxConfig.marketingWallet, true);
        }
        for (uint256 i = 0; i < dividendExcluded.length; i++) {
            if (dividendExcluded[i] != address(0)) {
                _setDividendExcluded(dividendExcluded[i], true);
            }
        }
    }

    function taxConfig() external view returns (TaxConfig memory) {
        return _taxConfig;
    }

    // ============ Dividend views / actions ============

    function totalDividendPerShare() external view returns (uint256) {
        if (dividendVault == address(0)) {
            return 0;
        }
        return IDividendVault(dividendVault).totalDividendPerShare();
    }

    function pendingDividend(address holder) external view returns (uint256) {
        if (dividendVault == address(0)) {
            return 0;
        }
        return IDividendVault(dividendVault).pendingDividend(holder);
    }

    function eligibleSupply() public view returns (uint256) {
        if (dividendVault == address(0)) {
            return 0;
        }
        return IDividendVault(dividendVault).currentEligibleShares();
    }

    function claimDividend() external {
        require(dividendVault != address(0), "Modules not initialized");
        uint256 claimed = IDividendVault(dividendVault).claimDividendFor(msg.sender);
        emit DividendClaimed(msg.sender, claimed);
    }

    // ============ Graduation / admin ============

    function setGraduated(bytes32 poolId_) external {
        require(msg.sender == launchpad, "Only launchpad");
        require(!graduated, "Already graduated");
        require(poolId_ != bytes32(0), "Invalid pool id");
        require(dividendVault != address(0), "Modules not initialized");

        graduated = true;
        poolId = poolId_;
        transferMode = 0;

        emit Graduated(poolId_);
    }

    function setTransferMode(uint8 mode) external onlyLaunchpadOrOwner {
        transferMode = mode;
    }

    function setDividendExcluded(address account, bool excluded) external onlyLaunchpadOrOwner {
        require(account != address(0), "Invalid account");
        _setDividendExcluded(account, excluded);
    }

    function setDividendAutoClaimConfig(
        uint256 threshold,
        uint256 maxCount,
        uint256 gasLimit,
        uint256 perHolderGasLimit
    ) external onlyLaunchpadOrOwner {
        require(dividendVault != address(0), "Modules not initialized");
        IDividendVault(dividendVault).setAutoClaimConfig(threshold, maxCount, gasLimit, perHolderGasLimit);
    }

    function isDividendAutoClaimReady() external view returns (bool) {
        if (dividendVault == address(0)) {
            return false;
        }
        return IDividendVault(dividendVault).isAutoClaimReady();
    }

    function dividendAutoClaimState()
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
        if (dividendVault == address(0)) {
            return (0, 0, false, 0, 0, 0, 0, 0);
        }
        return IDividendVault(dividendVault).autoClaimState();
    }

    // ============ Transfer hook ============

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && to != address(0xdead)) {
            if (transferMode == 1) {
                require(from == owner() || from == launchpad, "Transfer restricted");
            } else if (transferMode == 2) {
                require(
                    from == owner() || from == launchpad || to == owner() || to == launchpad,
                    "Transfer controlled"
                );
            }
        }

        super._update(from, to, amount);
        _syncDividendShare(from);
        _syncDividendShare(to);
    }

    function _syncDividendShare(address account) internal {
        if (account == address(0)) {
            return;
        }
        if (dividendVault == address(0)) {
            return;
        }
        if (isExcludedFromDividend[account]) {
            return;
        }
        IDividendVault(dividendVault).syncShare(account, balanceOf(account));
    }

    function _setDividendExcluded(address account, bool excluded) internal {
        if (isExcludedFromDividend[account] == excluded) {
            return;
        }
        isExcludedFromDividend[account] = excluded;
        if (dividendVault != address(0)) {
            IDividendVault(dividendVault).setExcluded(account, excluded);
        }
        emit DividendExclusionUpdated(account, excluded);
    }
}
