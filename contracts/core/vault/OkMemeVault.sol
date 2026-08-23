// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title OkMemeVault
 * @notice OK.MEME protocol-fee vault, isolated from launchpad business logic.
 * @dev 职责单一: 接收、存储、提取资金。不参与任何业务逻辑。
 *
 * 权限模型:
 *   - owner:    最高权限，可紧急提款 + 转移所有权 + 设定 operator
 *   - operator: 日常操作员，可执行常规提款，但接收方只能是 treasury
 *   - treasury: 唯一资金接收方，由 owner 显式轮换
 *
 * 所有权转移采用两步确认机制 (setPendingOwner → acceptOwner)，防止误操作。
 */
contract OkMemeVault {
    // ============ State ============

    address public owner;
    address public pendingOwner;
    address public operator;
    address public treasury;

    // ============ Events ============

    event Received(address indexed from, uint256 amount);
    event WithdrawNative(address indexed to, uint256 amount);
    event WithdrawERC20(address indexed token, address indexed to, uint256 amount);
    event EmergencyWithdraw(address indexed to, uint256 nativeAmount);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    event PendingOwnerSet(address indexed oldPendingOwner, address indexed newPendingOwner);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    // ============ Modifiers ============

    modifier onlyOwner() {
        require(msg.sender == owner, "Not Owner");
        _;
    }

    modifier onlyOperatorOrOwner() {
        require(msg.sender == operator || msg.sender == owner, "Not Authorized");
        _;
    }

    // ============ Constructor ============

    constructor(address initialOwner, address initialOperator, address initialTreasury) {
        require(initialOwner != address(0), "Invalid owner");
        require(initialOperator != address(0), "Invalid operator");
        require(initialTreasury != address(0), "Invalid treasury");
        owner = initialOwner;
        operator = initialOperator;
        treasury = initialTreasury;
    }

    // ============ Receive ============

    /// @notice Receive native OKB fees from the launchpad.
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // ============ 常规提款 (Operator 或 Owner) ============

    /// @notice Withdraw native OKB.
    /// @param to 接收地址
    /// @param amount 提取数量
    function withdrawNative(address payable to, uint256 amount) external onlyOperatorOrOwner {
        require(to == treasury, "Invalid treasury recipient");
        require(amount <= address(this).balance, "Insufficient balance");
        (bool success,) = to.call{value: amount}("");
        require(success, "Transfer failed");
        emit WithdrawNative(to, amount);
    }

    /// @notice Withdraw an ERC20 payment asset.
    /// @param token ERC20 代币地址
    /// @param to 接收地址
    /// @param amount 提取数量
    function withdrawERC20(address token, address to, uint256 amount) external onlyOperatorOrOwner {
        require(to == treasury, "Invalid treasury recipient");
        require(token != address(0), "Invalid token");
        require(IERC20(token).transfer(to, amount), "ERC20 transfer failed");
        emit WithdrawERC20(token, to, amount);
    }

    // ============ 紧急提款 (仅 Owner) ============

    /// @notice 紧急提取所有 native 资金到 treasury
    /// @dev 仅 owner 可调用，用于极端安全事件
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success,) = treasury.call{value: balance}("");
            require(success, "Emergency transfer failed");
        }
        emit EmergencyWithdraw(treasury, balance);
    }

    /// @notice 紧急提取指定 ERC20 的全部余额到 treasury
    /// @param token ERC20 代币地址
    function emergencyWithdrawERC20(address token) external onlyOwner {
        require(token != address(0), "Invalid token");
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            require(IERC20(token).transfer(treasury, balance), "ERC20 emergency transfer failed");
        }
        emit WithdrawERC20(token, treasury, balance);
    }

    // ============ 权限管理 ============

    /// @notice 设定 operator
    function setOperator(address newOperator) external onlyOwner {
        require(newOperator != address(0), "Invalid operator");
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }

    /// @notice Rotate the only permitted fee-withdrawal recipient.
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury");
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice 发起所有权转移 (第一步)
    function setPendingOwner(address newPendingOwner) external onlyOwner {
        emit PendingOwnerSet(pendingOwner, newPendingOwner);
        pendingOwner = newPendingOwner;
    }

    /// @notice 接受所有权转移 (第二步)
    function acceptOwner() external {
        require(msg.sender == pendingOwner, "Not Pending Owner");
        emit OwnerChanged(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
