// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IReentrantDividendVault {
    function claimDividend() external returns (uint256);
    function processAutoClaims() external returns (uint256 iterations, uint256 claims, uint256 amount);
}

contract ReentrantDividendRecipient {
    enum Mode {
        None,
        ClaimDividend,
        ProcessAutoClaims
    }

    IReentrantDividendVault public immutable vault;
    Mode public mode;
    bool public attempted;
    bool public reentered;
    bool public blocked;

    constructor(address vault_) {
        vault = IReentrantDividendVault(vault_);
    }

    function setMode(Mode mode_) external {
        mode = mode_;
        attempted = false;
        reentered = false;
        blocked = false;
    }

    function claimFromVault() external returns (uint256) {
        return vault.claimDividend();
    }

    receive() external payable {
        if (attempted || mode == Mode.None) {
            return;
        }

        attempted = true;
        if (mode == Mode.ClaimDividend) {
            try vault.claimDividend() returns (uint256) {
                reentered = true;
            } catch {
                blocked = true;
            }
        } else if (mode == Mode.ProcessAutoClaims) {
            try vault.processAutoClaims() returns (uint256, uint256, uint256) {
                reentered = true;
            } catch {
                blocked = true;
            }
        }
    }
}
