// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TaxConfig.sol";

/**
 * @title IOkMemeToken
 * @notice OkMemeToken 对外接口 — Launchpad 合约调用
 */
interface IOkMemeToken {
    // ============ 毕业设置 ============

    /// @notice 由 Launchpad 调用，设置毕业状态和 Uniswap V4 PoolId
    function setGraduated(bytes32 poolId) external;

    // ============ 状态查询 ============

    /// @notice 是否已毕业（毕业后 DEX 交易由共享 hook 收税）
    function graduated() external view returns (bool);

    /// @notice 毕业池 PoolId (Uniswap V4)
    function poolId() external view returns (bytes32);

    /// @notice 税费配置
    function taxConfig() external view returns (TaxConfig memory);

    /// @notice Payment asset (address(0) = native OKB)
    function paymentToken() external view returns (address);

    /// @notice 是否为原生币池
    function isNativePool() external view returns (bool);

    /// @notice 转账模式 (0=正常, 1=限制, 2=受控)
    function transferMode() external view returns (uint8);

    /// @notice 分红金库地址
    function dividendVault() external view returns (address);

    // ============ 设置 ============

    /// @notice 设置转账模式（仅 owner/launchpad）
    function setTransferMode(uint8 mode) external;

    /// @notice 设置分红豁免地址（仅 owner/launchpad）
    function setDividendExcluded(address account, bool excluded) external;

    // ============ 分红 ============

    /// @notice 持币者领取分红
    function claimDividend() external;

    /// @notice 查询待领取分红
    function pendingDividend(address holder) external view returns (uint256);
}
