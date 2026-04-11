// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./TezcatliConfidentialVault.sol";

contract TezcatliConfidentialVaultFactory is Ownable {
    mapping(address => address) public vaultByAsset;
    address[] private _vaults;

    event VaultCreated(address indexed asset, address indexed vault, address indexed owner);

    error InvalidAsset();
    error VaultAlreadyExists();

    constructor(address owner_) Ownable(owner_) {}

    function createVault(address asset, address vaultOwner) external onlyOwner returns (address vault) {
        if (asset == address(0)) revert InvalidAsset();
        if (vaultByAsset[asset] != address(0)) revert VaultAlreadyExists();

        TezcatliConfidentialVault deployed = new TezcatliConfidentialVault(asset, vaultOwner);
        vault = address(deployed);

        vaultByAsset[asset] = vault;
        _vaults.push(vault);

        emit VaultCreated(asset, vault, vaultOwner);
    }

    function allVaults() external view returns (address[] memory) {
        return _vaults;
    }
}
