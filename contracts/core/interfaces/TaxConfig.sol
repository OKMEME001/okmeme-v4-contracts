// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TaxConfig
 * @notice 税费配置结构体 — 全局共享定义
 * @dev 被 IOkMemeToken, OkMemeToken, OkMemeLaunchpad 共同引用
 *
 * 约束:
 *   - sum(marketingFee + holderDividendFee + buybackFee + burnFee) <= 1000 (即 ≤ 10%)
 *   - 费率精度: 0-10000，步长50=0.5%
 *   - LP分红已取消(D-001)，仅保留4类: 营销/持币分红/底池回流/销毁
 */
struct TaxConfig {
    uint16 marketingFee;           // 营销费 (0-1000, 即 0-10%)
    uint16 holderDividendFee;      // 持币分红费 (以池币种发放)
    uint16 buybackFee;             // 底池回流费
    uint16 burnFee;                // 自动销毁费
    address marketingWallet;       // 营销钱包地址
    uint256 minHoldingForDividend; // 最低分红持币量
}
