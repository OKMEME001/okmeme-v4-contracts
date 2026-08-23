// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPositionLocker {
    struct LiquidityIncreaseResult {
        uint128 liquidityAdded;
        uint256 tokenUsed;
        uint256 paymentUsed;
        uint256 tokenFeesAccrued;
        uint256 paymentFeesAccrued;
    }

    function increaseLiquidity(address token, uint256 tokenAmount, uint256 paymentAmount)
        external
        payable
        returns (LiquidityIncreaseResult memory result);

    function increaseLiquidityDuringSwap(address token, uint256 tokenAmount, uint256 paymentAmount)
        external
        payable
        returns (LiquidityIncreaseResult memory result);
}
