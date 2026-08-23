// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IMarketingClaim {
    function claimMarketing(address token, address recipient) external;
}

contract RejectingMarketingWallet {
    function claim(address settler, address token, address recipient) external {
        IMarketingClaim(settler).claimMarketing(token, recipient);
    }

    receive() external payable {
        revert("Reject native");
    }
}
