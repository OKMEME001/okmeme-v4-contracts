// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal CREATE2 deployer used to place the tax hook at a mined
///         address whose low bits encode the required V4 hook permissions.
contract Create2Factory {
    event Deployed(address addr);

    function deploy(bytes32 salt, bytes calldata creationCode) external payable returns (address addr) {
        bytes memory bytecode = creationCode;
        assembly {
            addr := create2(callvalue(), add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "Create2 failed");
        emit Deployed(addr);
    }

    function computeAddress(bytes32 salt, bytes32 creationCodeHash) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, creationCodeHash)))));
    }
}
