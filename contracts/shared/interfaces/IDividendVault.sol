// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDividendVault {
    function syncShare(address account, uint256 newBalance) external;
    function createDividendEpoch(uint256 dividendTokenAmount) external returns (uint256);
    function notifyDividendPayment(uint256 processedDividendTokenAmount, uint256 paymentAmount) external payable;
    function processPendingDividends(uint256 maxEpochs) external returns (uint256 consumedToken, uint256 consumedPayment);
    function setExcluded(address account, bool excluded) external;
    function setAutoClaimConfig(
        uint256 threshold,
        uint256 maxCount,
        uint256 gasLimit,
        uint256 perHolderGasLimit
    ) external;
    function pendingDividend(address holder) external view returns (uint256);
    function claimDividend() external returns (uint256);
    function claimDividendFor(address holder) external returns (uint256);
    function processAutoClaims() external returns (uint256 iterations, uint256 claims, uint256 amount);
    function isAutoClaimReady() external view returns (bool);
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
        );
    function currentShare(address account) external view returns (uint256);
    function nextClaimEpoch(address account) external view returns (uint256);
    function currentEligibleShares() external view returns (uint256);
    function currentEpoch() external view returns (uint256);
    function lastFinalizedEpoch() external view returns (uint256);
    function firstPendingEpoch() external view returns (uint256);
    function queuedDividendTokens() external view returns (uint256);
    function queuedDividendPayment() external view returns (uint256);
    function totalDividendPerShare() external view returns (uint256);
    function minHoldingForDividend() external view returns (uint256);
}
