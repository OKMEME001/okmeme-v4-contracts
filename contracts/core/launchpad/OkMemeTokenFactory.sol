// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "../../shared/dividend/DividendVault.sol";
import "../token/OkMemeToken.sol";
import "../interfaces/TaxConfig.sol";

/**
 * @title OkMemeTokenFactory
 * @notice CREATE2 deployer for OkMemeToken instances plus their per-token
 *         DividendVault clone. The shared TaxSettler is registered as the
 *         vault processor; V4 protocol addresses are seeded as dividend-exempt.
 */
contract OkMemeTokenFactory {
    using Clones for address;

    address public launchpad;
    address public owner;
    address private immutable _dividendVaultImplementation;
    address public immutable settler;

    /// @notice Protocol addresses excluded from dividends on every token
    ///         (PoolManager, PositionManager, venue, locker, settler, ...).
    address[] private _dividendExemptAddresses;

    modifier onlyLaunchpad() {
        require(msg.sender == launchpad, "Only launchpad");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(
        address dividendVaultImplementation_,
        address settler_,
        address[] memory dividendExemptAddresses_
    ) {
        require(dividendVaultImplementation_ != address(0), "Invalid dividend impl");
        require(settler_ != address(0), "Invalid settler");
        owner = msg.sender;
        _dividendVaultImplementation = dividendVaultImplementation_;
        settler = settler_;
        for (uint256 i = 0; i < dividendExemptAddresses_.length; i++) {
            require(dividendExemptAddresses_[i] != address(0), "Invalid exempt address");
            _dividendExemptAddresses.push(dividendExemptAddresses_[i]);
        }
    }

    function dividendVaultImplementation() external view returns (address) {
        return _dividendVaultImplementation;
    }

    function dividendExemptAddresses() external view returns (address[] memory) {
        return _dividendExemptAddresses;
    }

    function setLaunchpad(address launchpad_) external onlyOwner {
        require(launchpad_ != address(0), "Invalid address");
        launchpad = launchpad_;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }

    function createToken(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address creator,
        address paymentToken,
        TaxConfig memory taxConfig,
        uint256 autoClaimThreshold,
        uint256 salt
    ) external onlyLaunchpad returns (address tokenAddr) {
        bytes32 creatorBoundSalt = keccak256(abi.encodePacked(creator, salt));
        tokenAddr = address(new OkMemeToken{salt: creatorBoundSalt}(
            name,
            symbol,
            totalSupply,
            msg.sender,
            paymentToken,
            taxConfig
        ));

        address dividendVaultClone = _dividendVaultImplementation.clone();

        DividendVault(payable(dividendVaultClone)).initialize(
            tokenAddr,
            tokenAddr,
            paymentToken,
            paymentToken == address(0),
            taxConfig.minHoldingForDividend,
            autoClaimThreshold,
            settler
        );

        OkMemeToken(payable(tokenAddr)).initializeModules(dividendVaultClone, _dividendExemptAddresses);
    }
}
