// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./LaunchStorage.sol";
import "../token/OkMemeToken.sol";
import "../interfaces/TaxConfig.sol";

interface ITokenFactory {
    function createToken(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address creator,
        address paymentToken,
        TaxConfig memory taxConfig,
        uint256 autoClaimThreshold,
        uint256 salt
    ) external returns (address);
}

interface IGraduationVenue {
    function seed(
        address token,
        uint256 tokenAmount,
        uint256 paymentAmount,
        address dividendVault,
        uint256 settlementTriggerValue,
        uint256 maxReflowPayment,
        uint256 minLiquidityPaymentToAdd
    ) external payable returns (bytes32 poolId, uint256 positionTokenId);
}

/**
 * @title OkMemeLaunchpad
 * @notice OK.MEME bonding-curve launchpad for native OKB and owner-added ERC20 pools.
 * @dev Tokens graduate into a Uniswap V4 pool seeded by the GraduationVenue at the
 *      bonding-curve closing price. Protocol fees are isolated in the platform vault.
 */
contract OkMemeLaunchpad is LaunchStorage {
    // ============ 重入锁 ============

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    // ============ Token Factory ============

    address public tokenFactory;

    // ============ 白名单 ============

    mapping(address => bool) public whitelist;
    bool public whitelistEnabled = false;

    // ============ Events ============

    event TokenCreate(
        address indexed token, uint256 indexed id, address indexed creator,
        uint8 poolType, TaxConfig taxConfig
    );
    event TokenPurchased(
        address indexed token, address indexed buyer,
        uint256 paymentAmount, uint256 fee, uint256 tokenAmount, uint256 tokenReserve
    );
    event TokenSold(
        address indexed token, address indexed seller,
        uint256 paymentAmount, uint256 fee, uint256 tokenAmount
    );
    event PaymentRefunded(address indexed token, address indexed buyer, uint256 amount);
    event LaunchPending(address indexed token);
    event TokenLaunched(address indexed token, bytes32 poolId, uint256 positionTokenId);
    event LaunchLiquidityAdded(
        address indexed token,
        bytes32 indexed poolId,
        uint256 tokenAmount,
        uint256 paymentAmount,
        uint256 positionTokenId
    );
    event Erc20PoolAdded(uint8 indexed poolType, address indexed paymentToken, uint256 launchTarget);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event LauncherChanged(address indexed oldLauncher, address indexed newLauncher);
    event LaunchExecutorSet(address indexed executor, bool authorized);
    event PendingOwnerSet(address indexed oldPendingOwner, address indexed newPendingOwner);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event PurchaseFeeSet(uint256 oldFee, uint256 newFee);
    event SaleFeeSet(uint256 oldFee, uint256 newFee);
    event MinTxFeeSet(uint256 oldFee, uint256 newFee);
    event PoolLaunchConfigSet(
        uint8 indexed poolType,
        uint256 launchTarget,
        uint256 launchFee,
        uint256 virtualPayment,
        uint256 launchPaymentReserve
    );
    event PoolDividendExemptRecipientSet(uint8 indexed poolType, address indexed account, bool excluded);
    event TokenDividendExemptRecipientSet(address indexed token, address indexed account, bool excluded);

    // ============ Modifiers ============

    modifier onlyOwner() {
        require(msg.sender == owner, "Not Owner");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "Not Operator");
        _;
    }

    modifier onlyActive() {
        require(!pause, "Paused");
        _;
    }

    modifier onlyWhitelisted() {
        require(!whitelistEnabled || whitelist[msg.sender], "Not whitelisted");
        _;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ============ Constructor ============

    constructor() {
        owner = msg.sender;
        whitelist[msg.sender] = true;
        _status = _NOT_ENTERED;
    }

    // ============ Initialization ============

    function initialize(
        address _vault,
        address _venue,
        uint256 _saleFee,
        uint256 _purchaseFee
    ) public {
        require(msg.sender == owner, "Not Owner"); // M-01: 防止抢跑初始化
        require(vault == address(0), "Can only initialize once");
        require(_vault != address(0), "Vault address cannot be zero");
        require(_venue != address(0), "Venue address cannot be zero");

        vault = _vault;
        venue = _venue;
        saleFee = _saleFee;
        purchaseFee = _purchaseFee;
        deadAddress = address(0xdead);
        launcher = msg.sender;
        operator = msg.sender;
        _status = _NOT_ENTERED;

        // 池 0 固定为 native OKB；发行/运营参数由部署脚本按 product 配置显式设置。
        poolCount = 1;
    }

    // ================================================================
    //                     池管理: 追加 ERC20 池
    // ================================================================

    /**
     * @notice 追加一个 ERC20 底池。池编号顺延分配，已创建代币不受影响。
     */
    function addErc20Pool(
        address paymentTokenAddr,
        uint256 launchTarget,
        uint256 settlementTriggerValue,
        uint256 maxReflowPayment,
        uint256 minLiquidityPaymentToAdd,
        uint256 autoClaimThreshold
    ) external onlyOwner returns (uint8 poolType) {
        require(paymentTokenAddr != address(0), "Invalid payment token");
        require(maxReflowPayment >= 2, "Invalid reflow budget");
        require(poolCount < type(uint8).max, "Pool limit reached");
        for (uint8 i = 1; i < poolCount; i++) {
            require(paymentTokenAddresses[i] != paymentTokenAddr, "Pool exists");
        }

        poolType = poolCount;
        poolCount = poolType + 1;

        paymentTokenAddresses[poolType] = paymentTokenAddr;
        _setPoolLaunchTarget(poolType, launchTarget);
        defaultSettlementTriggerValue[poolType] = settlementTriggerValue;
        defaultMaxReflowPayment[poolType] = maxReflowPayment;
        defaultMinLiquidityPaymentToAdd[poolType] = minLiquidityPaymentToAdd;
        defaultAutoClaimThreshold[poolType] = autoClaimThreshold;

        emit Erc20PoolAdded(poolType, paymentTokenAddr, launchTarget);
    }

    // ================================================================
    //                     核心函数: 创建 + 首购
    // ================================================================

    /**
     * @notice 创建代币并可选首次购买
     * @param name 代币名称
     * @param symbol 代币符号
     * @param _salt CREATE2 盐值
     * @param _taxConfig 税费配置
     * @param poolType 池类型: 0 为 native，其他为已配置的 ERC20 池
     * @param paymentAmount ERC20 pool payment; ignored for the native OKB pool
     */
    function createAndInitPurchase(
        string memory name,
        string memory symbol,
        uint256 _salt,
        TaxConfig memory _taxConfig,
        uint8 poolType,
        uint256 paymentAmount
    ) external payable nonReentrant onlyActive onlyWhitelisted returns (address) {
        return _createAndInitPurchaseFor(
            msg.sender,
            msg.sender,
            name,
            symbol,
            _salt,
            _taxConfig,
            poolType,
            paymentAmount,
            msg.value
        );
    }

    /**
     * @notice 供授权原子发射执行器代理创建 + 首购。
     * @dev 支付资金始终从 msg.sender（executor）收取。
     */
    function createAndInitPurchaseFor(
        address creator,
        address buyer,
        string memory name,
        string memory symbol,
        uint256 _salt,
        TaxConfig memory _taxConfig,
        uint8 poolType,
        uint256 paymentAmount
    ) external payable nonReentrant onlyActive returns (address) {
        require(authorizedLaunchExecutors[msg.sender], "Not authorized executor");
        return _createAndInitPurchaseFor(
            creator,
            buyer,
            name,
            symbol,
            _salt,
            _taxConfig,
            poolType,
            paymentAmount,
            msg.value
        );
    }

    function _createAndInitPurchaseFor(
        address creator,
        address buyer,
        string memory name,
        string memory symbol,
        uint256 _salt,
        TaxConfig memory _taxConfig,
        uint8 poolType,
        uint256 paymentAmount,
        uint256 nativePayment
    ) internal returns (address) {
        require(creator != address(0) && buyer != address(0), "Invalid recipient");
        require(poolType < poolCount, "Invalid pool type");

        // 1. 获取池对应的 paymentToken 地址
        address paymentToken = _getPaymentToken(poolType);

        // 2. 通过 Factory 部署 OkMemeToken（CREATE2）
        require(tokenFactory != address(0), "Factory not set");
        PoolLaunchConfig memory launchConfig = _getPoolLaunchConfig(poolType);
        address tokenAddr = ITokenFactory(tokenFactory).createToken(
            name,
            symbol,
            TOKEN_SUPPLY,
            creator,
            paymentToken,
            _taxConfig,
            defaultAutoClaimThreshold[poolType],
            _salt
        );
        tokenAddress[tokenCount] = tokenAddr;
        tokenCount++;
        tokenCreator[tokenAddr] = creator;
        tokenLaunchConfigs[tokenAddr] = launchConfig;
        tokenOpsConfigs[tokenAddr] = TokenOpsConfig({
            settlementTriggerValue: defaultSettlementTriggerValue[poolType],
            maxReflowPayment: defaultMaxReflowPayment[poolType],
            minLiquidityPaymentToAdd: defaultMinLiquidityPaymentToAdd[poolType]
        });

        // 3. 初始化虚拟池
        virtualPools[tokenAddr].paymentReserve = launchConfig.virtualPayment;
        virtualPools[tokenAddr].tokenReserve = TOKEN_SUPPLY + VIRTUAL_TOKEN_RESERVE_AMOUNT;
        virtualPools[tokenAddr].poolType = poolType;
        virtualPools[tokenAddr].paymentToken = paymentToken;
        _applyPoolDividendExemptRecipients(tokenAddr, poolType);

        emit TokenCreate(tokenAddr, tokenCount - 1, creator, poolType, _taxConfig);

        // 4. 如果有初始购买金额
        uint256 initPayment;
        if (poolType == 0) {
            // Native OKB pool uses msg.value.
            initPayment = nativePayment;
        } else {
            // ERC20: 使用 paymentAmount 参数
            if (paymentAmount > 0) {
                initPayment = _collectERC20Payment(paymentToken, msg.sender, paymentAmount);
            }
        }

        if (initPayment > 0) {
            require(initPayment > minTxFee, "Insufficient payment for transaction");
            _executePurchase(tokenAddr, buyer, initPayment, poolType);
        }

        return tokenAddr;
    }

    // ================================================================
    //                     核心函数: 买入
    // ================================================================

    /**
     * @notice Buy from the native OKB pool.
     * @param token 代币地址
     * @param amountMin 最低获得数量（滑点保护）
     */
    function purchaseToken(address token, uint256 amountMin) external payable nonReentrant onlyActive {
        require(getTokenState(token) == 1, "Not On Sale");
        require(virtualPools[token].poolType == 0, "Use purchaseTokenERC20");
        require(msg.value >= minTxFee, "Insufficient payment for transaction");

        uint256 amountOut = _executePurchase(token, msg.sender, msg.value, 0);
        require(amountOut >= amountMin, "Insufficient Output Amount");
    }

    /**
     * @notice Buy from a configured ERC20 payment pool.
     * @param token 代币地址
     * @param paymentAmount 支付金额
     * @param amountMin 最低获得数量（滑点保护）
     */
    function purchaseTokenERC20(address token, uint256 paymentAmount, uint256 amountMin) external nonReentrant onlyActive {
        require(getTokenState(token) == 1, "Not On Sale");
        uint8 pt = virtualPools[token].poolType;
        require(pt > 0, "Use purchaseToken");
        require(paymentAmount >= minTxFee, "Insufficient payment for transaction");

        address paymentToken = virtualPools[token].paymentToken;
        uint256 actualPayment = _collectERC20Payment(paymentToken, msg.sender, paymentAmount);
        require(actualPayment >= minTxFee, "Insufficient payment for transaction");

        uint256 amountOut = _executePurchase(token, msg.sender, actualPayment, pt);
        require(amountOut >= amountMin, "Insufficient Output Amount");
    }

    // ================================================================
    //                     核心函数: 卖出
    // ================================================================

    /**
     * @notice 卖出代币
     * @param token 代币地址
     * @param tokenAmount 卖出数量
     * @param amountMin 最低获得 payment 数量
     */
    function saleToken(address token, uint256 tokenAmount, uint256 amountMin) external nonReentrant onlyActive {
        uint256 state = getTokenState(token);
        require(state == 1 || state == 2, "Not On Sale");

        // 从用户转入 token
        bool success = OkMemeToken(payable(token)).transferFrom(msg.sender, address(this), tokenAmount);
        require(success, "Token transfer failed");

        VirtualPool storage pool = virtualPools[token];
        PoolLaunchConfig memory launchConfig = _getTokenLaunchConfig(token);
        uint256 virtualPayment = launchConfig.virtualPayment;

        uint256 paymentOut = getPaymentAmountBySale(token, tokenAmount);
        uint256 tokenUnused;
        uint256 tokenUsed = tokenAmount;

        // 防止 paymentReserve 跌破虚拟储备 (安全比较防下溢)
        if (paymentOut > pool.paymentReserve || pool.paymentReserve - paymentOut < virtualPayment) {
            paymentOut = pool.paymentReserve - virtualPayment;
            require(paymentOut > 0, "Pool at minimum reserve");
            tokenUsed = getExactPaymentAmountForSale(token, paymentOut);
            tokenUnused = tokenAmount - tokenUsed;
        }

        require(paymentOut >= minTxFee, "Token amount too low for sale");

        // 计算手续费
        uint256 fee = paymentOut * saleFee / BASE_FEE;
        if (fee < minTxFee) {
            fee = minTxFee;
        }
        uint256 paymentReceived = paymentOut - fee;

        // 更新池子
        pool.paymentReserve -= paymentOut;
        pool.tokenReserve += tokenUsed;

        // 发送手续费和收益
        if (pool.poolType == 0) {
            // Native OKB
            (bool s1,) = vault.call{value: fee}("");
            require(s1, "Fee transfer to vault failed");
            require(paymentReceived >= amountMin, "Insufficient Output Amount");
            (bool s2,) = msg.sender.call{value: paymentReceived}("");
            require(s2, "Payment transfer to seller failed");
            emit TokenSold(token, msg.sender, paymentReceived, fee, tokenUsed);
        } else {
            address pt = pool.paymentToken;
            uint256 actualFee = _transferERC20Measured(pt, vault, fee, "Fee transfer failed");
            uint256 actualPaymentReceived = _transferERC20Measured(pt, msg.sender, paymentReceived, "Payment transfer failed");
            require(actualPaymentReceived >= amountMin, "Insufficient Output Amount");
            emit TokenSold(token, msg.sender, actualPaymentReceived, actualFee, tokenUsed);
        }

        // 退还未用 token
        if (tokenUnused > 0) {
            OkMemeToken(payable(token)).transfer(msg.sender, tokenUnused);
        }
    }

    // ================================================================
    //                     核心函数: 毕业发射
    // ================================================================

    /**
     * @notice 毕业发射 — 经 GraduationVenue 将代币接入 Uniswap V4 池
     * @dev launcher 或授权原子发射执行器可调用。
     */
    function launchToDEXOwner(address token) external nonReentrant onlyActive {
        require(getTokenState(token) == 2, "Token not prepared for launch");
        require(
            msg.sender == launcher || authorizedLaunchExecutors[msg.sender],
            "Only launcher"
        );

        VirtualPool storage pool = virtualPools[token];
        PoolLaunchConfig memory launchConfig = _getTokenLaunchConfig(token);
        uint256 launchFeeAmt = launchConfig.launchFee;
        uint256 virtualPayment = launchConfig.virtualPayment;

        // 1. 收取发射费用 → vault
        if (pool.poolType == 0) {
            (bool s1,) = vault.call{value: launchFeeAmt}("");
            require(s1, "Fee transfer to vault failed");
        } else {
            _transferERC20Measured(pool.paymentToken, vault, launchFeeAmt, "Launch fee transfer failed");
        }

        // 2. 计算 DEX 流动性数量
        uint256 paymentLaunched = pool.paymentReserve - launchFeeAmt - virtualPayment;
        uint256 tokenForDex = pool.tokenReserve - VIRTUAL_TOKEN_RESERVE_AMOUNT;

        // 3. 放开 token 转账限制，允许创建 DEX 初始流动性
        OkMemeToken(payable(token)).setTransferMode(0);

        // 4. 经毕业场初始化 V4 池并铸入锁仓全区间流动性
        TokenOpsConfig memory ops = tokenOpsConfigs[token];
        address dividendVault = OkMemeToken(payable(token)).dividendVault();
        require(OkMemeToken(payable(token)).transfer(venue, tokenForDex), "Token transfer failed");

        bytes32 poolId;
        uint256 positionTokenId;
        if (pool.poolType == 0) {
            (poolId, positionTokenId) = IGraduationVenue(venue).seed{value: paymentLaunched}(
                token,
                tokenForDex,
                paymentLaunched,
                dividendVault,
                ops.settlementTriggerValue,
                ops.maxReflowPayment,
                ops.minLiquidityPaymentToAdd
            );
        } else {
            _transferERC20Measured(pool.paymentToken, venue, paymentLaunched, "Payment transfer failed");
            (poolId, positionTokenId) = IGraduationVenue(venue).seed(
                token,
                tokenForDex,
                paymentLaunched,
                dividendVault,
                ops.settlementTriggerValue,
                ops.maxReflowPayment,
                ops.minLiquidityPaymentToAdd
            );
        }

        require(poolId != bytes32(0), "Pool not seeded");
        emit LaunchLiquidityAdded(token, poolId, tokenForDex, paymentLaunched, positionTokenId);

        // 5. 清理虚拟池
        pool.tokenReserve = 0;
        pool.paymentReserve = 0;
        pool.launched = true;

        // 6. 设置毕业状态 + 将所有权永久移交到销毁地址
        OkMemeToken(payable(token)).setGraduated(poolId);
        _applyPoolDividendExemptRecipients(token, pool.poolType);
        OkMemeToken(payable(token)).transferOwnership(deadAddress);

        emit TokenLaunched(token, poolId, positionTokenId);
    }

    // ================================================================
    //                  内部函数: 执行买入
    // ================================================================

    /**
     * @dev Shared purchase logic for native and ERC20 payment pools.
     * @param token 代币地址
     * @param buyer 买家地址
     * @param paymentIn 支付金额（已到合约）
     * @param poolType 池类型
     * @return amountOut 买到的 token 数量
     */
    function _executePurchase(
        address token,
        address buyer,
        uint256 paymentIn,
        uint8 poolType
    ) internal returns (uint256 amountOut) {
        VirtualPool storage pool = virtualPools[token];
        PoolLaunchConfig memory launchConfig = _getTokenLaunchConfig(token);
        uint256 launchPaymentReserve = launchConfig.launchPaymentReserve;

        // 1. 计算手续费
        uint256 fee = paymentIn * purchaseFee / BASE_FEE;
        if (fee < minTxFee) {
            fee = minTxFee;
        }
        uint256 paymentCost = paymentIn - fee;
        uint256 paymentRefund = 0;

        // 2. 毕业阈值钳制：只对实际入池的部分收费，退款部分不收费
        if (pool.paymentReserve + paymentCost > launchPaymentReserve) {
            uint256 usedCost = launchPaymentReserve - pool.paymentReserve;
            uint256 recomputedFee = usedCost * purchaseFee / (BASE_FEE - purchaseFee);
            if (recomputedFee < minTxFee) {
                recomputedFee = minTxFee;
            }
            if (recomputedFee < fee) {
                fee = recomputedFee;
            }
            paymentRefund = paymentIn - usedCost - fee;
            paymentCost = usedCost;
            amountOut = getTokenAmountByPurchase(token, usedCost);
            pool.paymentReserve = launchPaymentReserve;
            emit LaunchPending(token);
        } else {
            amountOut = getTokenAmountByPurchase(token, paymentCost);
            pool.paymentReserve += paymentCost;
        }

        // 4. 更新 token 储备
        pool.tokenReserve -= amountOut;

        // 5. 转出 token 给买家
        OkMemeToken(payable(token)).transfer(buyer, amountOut);

        // 6. 手续费发送到 vault
        if (poolType == 0) {
            (bool s1,) = vault.call{value: fee}("");
            require(s1, "Fee transfer to vault failed");
            // 多余的退回
            if (paymentRefund > 0) {
                (bool s2,) = buyer.call{value: paymentRefund}("");
                require(s2, "Refund failed");
                emit PaymentRefunded(token, buyer, paymentRefund);
            }
        } else {
            address pt = pool.paymentToken;
            uint256 actualFee = _transferERC20Measured(pt, vault, fee, "Fee transfer failed");
            if (paymentRefund > 0) {
                uint256 actualRefund = _transferERC20Measured(pt, buyer, paymentRefund, "Refund transfer failed");
                require(actualRefund > 0, "Refund transfer failed");
                emit PaymentRefunded(token, buyer, actualRefund);
            }
            fee = actualFee;
        }

        emit TokenPurchased(token, buyer, paymentCost, fee, amountOut, pool.tokenReserve);
    }

    function _collectERC20Payment(address paymentToken, address from, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBalance = IERC20(paymentToken).balanceOf(address(this));
        require(IERC20(paymentToken).transferFrom(from, address(this), amount), "Payment transfer failed");
        received = IERC20(paymentToken).balanceOf(address(this)) - beforeBalance;
    }

    function _transferERC20Measured(
        address paymentToken,
        address to,
        uint256 amount,
        string memory errorMessage
    ) internal returns (uint256 received) {
        if (amount == 0) {
            return 0;
        }

        uint256 beforeBalance = IERC20(paymentToken).balanceOf(to);
        require(IERC20(paymentToken).transfer(to, amount), errorMessage);
        received = IERC20(paymentToken).balanceOf(to) - beforeBalance;
    }

    function _applyPoolDividendExemptRecipients(address token, uint8 poolType) internal {
        address[] storage recipients = poolDividendExemptRecipientList[poolType];
        for (uint256 i = 0; i < recipients.length; i++) {
            address account = recipients[i];
            if (poolDividendExemptRecipients[poolType][account]) {
                OkMemeToken(payable(token)).setDividendExcluded(account, true);
            }
        }
    }

    // ================================================================
    //                  内部辅助函数: 池常量查询
    // ================================================================

    function _getPoolLaunchConfig(uint8 poolType) internal view returns (PoolLaunchConfig memory config) {
        require(poolType < poolCount, "Invalid pool type");
        config = poolLaunchConfigs[poolType];
        require(config.launchTarget > 0, "Pool config not set");
    }

    function _getTokenLaunchConfig(address token) internal view returns (PoolLaunchConfig memory config) {
        config = tokenLaunchConfigs[token];
        if (config.launchTarget == 0) {
            config = _getPoolLaunchConfig(virtualPools[token].poolType);
        }
    }

    function _getPaymentToken(uint8 poolType) internal view returns (address) {
        if (poolType == 0) return address(0);
        address pt = paymentTokenAddresses[poolType];
        require(pt != address(0), "Payment token not configured");
        return pt;
    }

    // ============ 池参数管理 ============

    function setPoolDividendExemptRecipient(uint8 poolType, address account, bool excluded) external onlyOwner {
        require(poolType < poolCount, "Invalid pool type");
        require(account != address(0), "Invalid address");

        if (!poolDividendExemptRecipientKnown[poolType][account]) {
            require(
                poolDividendExemptRecipientList[poolType].length < MAX_POOL_DIVIDEND_EXEMPT_RECIPIENTS,
                "Too many recipients"
            );
            poolDividendExemptRecipientKnown[poolType][account] = true;
            poolDividendExemptRecipientList[poolType].push(account);
        }

        poolDividendExemptRecipients[poolType][account] = excluded;
        emit PoolDividendExemptRecipientSet(poolType, account, excluded);
    }

    function poolDividendExemptRecipientCount(uint8 poolType) external view returns (uint256) {
        require(poolType < poolCount, "Invalid pool type");
        return poolDividendExemptRecipientList[poolType].length;
    }

    function setTokenDividendExemptRecipient(address token, address account, bool excluded) external onlyOwner {
        require(tokenCreator[token] != address(0), "Unknown token");
        OkMemeToken(payable(token)).setDividendExcluded(account, excluded);
        emit TokenDividendExemptRecipientSet(token, account, excluded);
    }

    function setPoolLaunchTarget(uint8 poolType, uint256 launchTarget) external onlyOwner {
        require(poolType < poolCount, "Invalid pool type");
        _setPoolLaunchTarget(poolType, launchTarget);
    }

    function _setPoolLaunchTarget(uint8 poolType, uint256 launchTarget) internal {
        require(launchTarget > 0, "Invalid target");

        uint256 launchFeeAmt = launchTarget * LAUNCH_FEE_BPS / BASE_FEE;
        require(launchFeeAmt > 0, "Invalid fee");
        uint256 virtualPayment = 27 * (launchTarget + launchFeeAmt) / 80;
        uint256 launchPaymentReserve = launchTarget + launchFeeAmt + virtualPayment;

        poolLaunchConfigs[poolType] = PoolLaunchConfig({
            launchTarget: launchTarget,
            launchFee: launchFeeAmt,
            virtualPayment: virtualPayment,
            launchPaymentReserve: launchPaymentReserve
        });

        emit PoolLaunchConfigSet(poolType, launchTarget, launchFeeAmt, virtualPayment, launchPaymentReserve);
    }

    function setDefaultSettlementTriggerValue(uint8 poolType, uint256 value) external onlyOwner {
        require(poolType < poolCount, "Invalid pool type");
        defaultSettlementTriggerValue[poolType] = value;
    }

    function setDefaultMaxReflowPayment(uint8 poolType, uint256 value) external onlyOwner {
        require(poolType < poolCount, "Invalid pool type");
        require(value >= 2, "Invalid reflow budget");
        defaultMaxReflowPayment[poolType] = value;
    }

    function setDefaultAutoClaimThreshold(uint8 poolType, uint256 value) external onlyOwner {
        require(poolType < poolCount, "Invalid pool type");
        defaultAutoClaimThreshold[poolType] = value;
    }

    function setDefaultMinLiquidityPaymentToAdd(uint8 poolType, uint256 value) external onlyOwner {
        require(poolType < poolCount, "Invalid pool type");
        defaultMinLiquidityPaymentToAdd[poolType] = value;
    }

    // ================================================================
    //                    View 函数 (Bonding Curve AMM)
    // ================================================================

    function getTokenState(address token) public view returns (uint256) {
        VirtualPool memory pool = virtualPools[token];
        if (pool.launched) return 3;

        PoolLaunchConfig memory launchConfig = _getTokenLaunchConfig(token);
        uint256 launchReserve = launchConfig.launchPaymentReserve;
        uint256 virtualPayment = launchConfig.virtualPayment;

        if (pool.paymentReserve >= launchReserve) return 2;
        if (pool.paymentReserve >= virtualPayment) return 1;
        return 0;
    }

    function getPrice(address token) external view returns (uint256) {
        VirtualPool memory pool = virtualPools[token];
        if (pool.launched) return 0;
        if (pool.tokenReserve > 0) {
            return pool.tokenReserve * 1e6 / pool.paymentReserve;
        }
        return 0;
    }

    /// @notice x*y=k: 给定 paymentAmount 买入，获得多少 Token
    function getTokenAmountByPurchase(address token, uint256 paymentAmount) public view returns (uint256 tokenAmount) {
        VirtualPool memory pool = virtualPools[token];
        tokenAmount = paymentAmount * pool.tokenReserve / (pool.paymentReserve + paymentAmount);
    }

    /// @notice x*y=k: 给定 tokenAmount 需要多少 payment 买入
    function getExactTokenAmountForPurchase(address token, uint256 tokenAmount) public view returns (uint256 paymentAmount) {
        VirtualPool memory pool = virtualPools[token];
        require(tokenAmount < pool.tokenReserve, "Amount exceeds reserve");
        paymentAmount = tokenAmount * pool.paymentReserve / (pool.tokenReserve - tokenAmount) + 1;
    }

    /// @notice x*y=k: 给定 tokenAmount 卖出，获得多少 payment
    function getPaymentAmountBySale(address token, uint256 tokenAmount) public view returns (uint256 paymentAmount) {
        VirtualPool memory pool = virtualPools[token];
        paymentAmount = tokenAmount * pool.paymentReserve / (pool.tokenReserve + tokenAmount);
    }

    /// @notice x*y=k: 给定 paymentAmount 需要卖出多少 Token
    function getExactPaymentAmountForSale(address token, uint256 paymentAmount) public view returns (uint256 tokenAmount) {
        VirtualPool memory pool = virtualPools[token];
        require(paymentAmount < pool.paymentReserve, "Amount exceeds reserve");
        tokenAmount = paymentAmount * pool.tokenReserve / (pool.paymentReserve - paymentAmount) + 1;
    }

    /// @notice 含手续费的买入计算
    function getTokenAmountByPurchaseWithFee(address token, uint256 paymentAmount) public view returns (uint256 tokenAmount, uint256 fee) {
        if (paymentAmount <= minTxFee) return (0, 0);
        fee = paymentAmount * purchaseFee / BASE_FEE;
        if (fee < minTxFee) fee = minTxFee;
        require(paymentAmount >= fee, "Insufficient payment for transaction");
        uint256 paymentUsed = paymentAmount - fee;
        VirtualPool memory pool = virtualPools[token];
        uint256 launchPaymentReserve = _getTokenLaunchConfig(token).launchPaymentReserve;
        if (pool.paymentReserve + paymentUsed > launchPaymentReserve) {
            paymentUsed = launchPaymentReserve - pool.paymentReserve;
            uint256 recomputedFee = paymentUsed * purchaseFee / (BASE_FEE - purchaseFee);
            if (recomputedFee < minTxFee) recomputedFee = minTxFee;
            if (recomputedFee < fee) fee = recomputedFee;
        }
        if (pool.tokenReserve == 0) {
            tokenAmount = paymentUsed * (TOKEN_SUPPLY + VIRTUAL_TOKEN_RESERVE_AMOUNT) / (_getTokenLaunchConfig(token).virtualPayment + paymentUsed);
        } else {
            tokenAmount = paymentUsed * pool.tokenReserve / (pool.paymentReserve + paymentUsed);
        }
    }

    /// @notice 含手续费的精确买入计算
    function getExactTokenAmountForPurchaseWithFee(address token, uint256 tokenAmount) public view returns (uint256 paymentAmount, uint256 fee) {
        VirtualPool memory pool = virtualPools[token];
        require(tokenAmount < pool.tokenReserve, "Amount exceeds reserve");
        paymentAmount = tokenAmount * pool.paymentReserve / (pool.tokenReserve - tokenAmount) + 1;
        fee = paymentAmount * purchaseFee / (BASE_FEE - purchaseFee) + 1;
        if (fee < minTxFee) fee = minTxFee;
        paymentAmount += fee;
    }

    /// @notice 含手续费的卖出计算
    function getPaymentAmountBySaleWithFee(address token, uint256 tokenAmount) public view returns (uint256 paymentAmount, uint256 fee) {
        VirtualPool memory pool = virtualPools[token];
        paymentAmount = tokenAmount * pool.paymentReserve / (pool.tokenReserve + tokenAmount);
        fee = paymentAmount * saleFee / BASE_FEE;
        if (fee < minTxFee) fee = minTxFee;
        require(paymentAmount >= fee, "Insufficient payment for transaction");
        paymentAmount -= fee;
    }

    /// @notice 含手续费的精确卖出计算
    function getExactPaymentAmountForSaleWithFee(address token, uint256 paymentAmount) public view returns (uint256 tokenAmount, uint256 fee) {
        fee = paymentAmount * saleFee / (BASE_FEE - saleFee) + 1;
        if (fee < minTxFee) fee = minTxFee;
        paymentAmount += fee;
        VirtualPool memory pool = virtualPools[token];
        require(paymentAmount < pool.paymentReserve, "Amount exceeds reserve");
        tokenAmount = paymentAmount * pool.tokenReserve / (pool.paymentReserve - paymentAmount) + 1;
    }

    // ================================================================
    //                    Admin functions
    // ================================================================

    function setOperator(address newOp) external onlyOwner {
        emit OperatorChanged(operator, newOp);
        operator = newOp;
    }

    function setLauncher(address newLauncher) external onlyOwner {
        emit LauncherChanged(launcher, newLauncher);
        launcher = newLauncher;
    }

    function setLaunchExecutor(address executor, bool authorized) external onlyOwner {
        require(executor != address(0), "Invalid executor");
        authorizedLaunchExecutors[executor] = authorized;
        emit LaunchExecutorSet(executor, authorized);
    }

    function setTokenFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "Invalid factory");
        tokenFactory = _factory;
    }

    function setVault(address _addr) external onlyOwner {
        require(_addr != address(0), "Vault should not be Zero");
        vault = _addr;
    }

    function setVenue(address _addr) external onlyOwner {
        require(_addr != address(0), "Venue should not be Zero");
        venue = _addr;
    }

    function setPurchaseFee(uint256 _fee) external onlyOperator {
        require(_fee <= 500, "Fee exceeds 5% cap");
        emit PurchaseFeeSet(purchaseFee, _fee);
        purchaseFee = _fee;
    }

    function setSaleFee(uint256 _fee) external onlyOperator {
        require(_fee <= 500, "Fee exceeds 5% cap");
        emit SaleFeeSet(saleFee, _fee);
        saleFee = _fee;
    }

    function setMinTxFee(uint256 newFee) external onlyOperator {
        emit MinTxFeeSet(minTxFee, newFee);
        minTxFee = newFee;
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

    function pausePad() external onlyOperator {
        require(!pause, "Already paused");
        pause = true;
    }

    function rerunPad() external onlyOwner {
        require(pause, "Not paused");
        pause = false;
    }

    function toggleWhitelist(bool status) external onlyOwner {
        whitelistEnabled = status;
    }

    function addToWhitelist(address user) external onlyOwner {
        whitelist[user] = true;
    }

    function removeFromWhitelist(address user) external onlyOwner {
        whitelist[user] = false;
    }

    /// @notice 将已上线代币的所有权移交到销毁地址（保留旧 ABI 名称）
    function renounceTokenOwnership(address token) external nonReentrant {
        require(getTokenState(token) == 3, "Only launched token can renounceOwnership");
        OkMemeToken(payable(token)).transferOwnership(deadAddress);
    }

    // ============ Receive ============

    receive() external payable {}
}
