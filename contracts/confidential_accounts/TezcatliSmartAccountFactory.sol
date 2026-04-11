// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./TezcatliSmartAccount.sol";

contract TezcatliSmartAccountFactory {
    event AccountCreated(address indexed account, address indexed owner, uint256 salt);

    function createAccount(address owner, uint256 salt) external returns (TezcatliSmartAccount account) {
        address predicted = predictAccountAddress(owner, salt);
        if (predicted.code.length > 0) {
            return TezcatliSmartAccount(payable(predicted));
        }

        account = new TezcatliSmartAccount{ salt: bytes32(salt) }(owner);
        emit AccountCreated(address(account), owner, salt);
    }

    function predictAccountAddress(address owner, uint256 salt) public view returns (address) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(type(TezcatliSmartAccount).creationCode, abi.encode(owner))
        );

        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            bytes32(salt),
            bytecodeHash
        )))));
    }
}
