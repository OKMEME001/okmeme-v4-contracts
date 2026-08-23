// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../interfaces/TaxConfig.sol";

/**
 * @title LaunchStorage
 * @notice OkMemeLaunchpad 的存储层 — 常量定义 + 状态变量
 * @dev Pool defaults are snapshotted per token so later configuration changes do not
 *      mutate an existing launch's economics.
 *
 * 池参数 (80/20/0 经济模型):
 *   VIRTUAL_PAYMENT = 27/80 × (TARGET + FEE)
 *   推导: 初始 tokenPool=1.07B, 毕业 tokenPool=0.27B
 *         => 800M × V = 270M × (TARGET+FEE)
 *         => V = 27/80 × (TARGET+FEE)
 *   默认初始进度 = 27/107 ≈ 25.2336%
 */
contract LaunchStorage {
    // ============ Admin ============

    address public owner;
    address public pendingOwner;

    // ============ 全局配置 ============
    uint256 public saleFee;               // 卖出手续费 (BASE_FEE 精度)
    uint256 public purchaseFee;           // 买入手续费 (BASE_FEE 精度)
    uint256 public tokenCount;            // 已创建代币数
    address public vault;                 // 手续费金库
    address public operator;              // 操作员角色
    address public launcher;              // 发射员角色
    address public venue;                 // Uniswap V4 毕业场 (GraduationVenue)
    bool    public pause;                 // 暂停状态
    uint256 public minTxFee;              // 最低交易费(绝对值)
    address public deadAddress;           // 死地址

    // ============ 全局常量 (代币供应分配) ============

    uint256 public constant TOKEN_SUPPLY          = 1_000_000_000e18; // 100% 总供应
    uint256 public constant LAUNCH_THRESHOLD      = 200_000_000e18;   // 20% 用于 DEX 流动性
    uint256 public constant TOTAL_SALE            = 800_000_000e18;   // 80% Bonding Curve 出售
    uint256 public constant VIRTUAL_TOKEN_RESERVE_AMOUNT = 70_000_000e18;
    uint256 public constant BASE_FEE              = 10_000;           // 手续费精度
    uint256 public constant LAUNCH_FEE_BPS        = 500;              // 毕业平台费 5%

    // ============ 池注册 ============

    /// @notice 已配置池数量。池 0 固定为 native OKB，1..poolCount-1 为 Owner 追加的 ERC20 池。
    uint8 public poolCount;

    mapping(uint8 => address) public paymentTokenAddresses; // poolType => ERC20 (pool 0 = address(0))

    // ============ 池发行参数 ============

    struct PoolLaunchConfig {
        uint256 launchTarget;
        uint256 launchFee;
        uint256 virtualPayment;
        uint256 launchPaymentReserve;
    }

    /// @notice 毕业后税务运营参数（创建时快照到 token）
    struct TokenOpsConfig {
        uint256 settlementTriggerValue;
        uint256 maxReflowPayment;
        uint256 minLiquidityPaymentToAdd;
    }

    // ============ 虚拟池 ============

    struct VirtualPool {
        uint256 paymentReserve;  // 池币种储备量
        uint256 tokenReserve;    // Token 储备量
        bool    launched;        // 是否已上 DEX
        uint8   poolType;        // 池编号；0 为 native，其他为 ERC20 池
        address paymentToken;    // address(0) represents native OKB
    }

    mapping(uint256 => address) public tokenAddress;    // tokenIndex => token address
    mapping(address => address) public tokenCreator;    // token => creator
    mapping(address => VirtualPool) public virtualPools; // token => pool
    mapping(uint8 => PoolLaunchConfig) public poolLaunchConfigs; // poolType => current default
    mapping(address => PoolLaunchConfig) public tokenLaunchConfigs; // token => creation-time snapshot
    mapping(address => TokenOpsConfig) public tokenOpsConfigs;      // token => creation-time snapshot

    mapping(uint8 => uint256) public defaultSettlementTriggerValue;
    mapping(uint8 => uint256) public defaultMaxReflowPayment;
    mapping(uint8 => uint256) public defaultMinLiquidityPaymentToAdd;
    mapping(uint8 => uint256) public defaultAutoClaimThreshold;

    // ============ 分红豁免名单 (协议地址不参与持币分红) ============

    uint256 public constant MAX_POOL_DIVIDEND_EXEMPT_RECIPIENTS = 16;
    mapping(uint8 => address[]) public poolDividendExemptRecipientList;
    mapping(uint8 => mapping(address => bool)) public poolDividendExemptRecipients;
    mapping(uint8 => mapping(address => bool)) internal poolDividendExemptRecipientKnown;

    // ============ 原子发射工具 ============

    /// @notice 经 Owner 授权、可代理创建+首购+毕业的原子发射执行器
    mapping(address => bool) public authorizedLaunchExecutors;
}
