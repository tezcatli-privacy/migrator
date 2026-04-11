// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract TezcatliStealthRegistry {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    mapping(uint256 => mapping(address => bytes)) private _metaAddresses;

    event StealthMetaAddressSet(
        address indexed registrant,
        uint256 indexed schemeId,
        bytes stealthMetaAddress
    );

    function registerStealthMetaAddress(
        uint256 schemeId,
        bytes calldata stealthMetaAddress
    ) external {
        require(stealthMetaAddress.length == 66, "TezcatliStealthRegistry: invalid meta-address length");
        _metaAddresses[schemeId][msg.sender] = stealthMetaAddress;
        emit StealthMetaAddressSet(msg.sender, schemeId, stealthMetaAddress);
    }

    function registerOnBehalf(
        address registrant,
        uint256 schemeId,
        bytes calldata stealthMetaAddress,
        bytes calldata signature
    ) external {
        require(stealthMetaAddress.length == 66, "TezcatliStealthRegistry: invalid meta-address length");

        bytes32 digest = keccak256(
            abi.encode(registrant, schemeId, stealthMetaAddress)
        ).toEthSignedMessageHash();

        require(digest.recover(signature) == registrant, "TezcatliStealthRegistry: invalid signature");

        _metaAddresses[schemeId][registrant] = stealthMetaAddress;
        emit StealthMetaAddressSet(registrant, schemeId, stealthMetaAddress);
    }

    function stealthMetaAddressOf(
        address registrant,
        uint256 schemeId
    ) external view returns (bytes memory) {
        return _metaAddresses[schemeId][registrant];
    }
}
