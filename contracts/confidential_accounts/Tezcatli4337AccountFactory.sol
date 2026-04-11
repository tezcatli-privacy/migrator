// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Tezcatli4337Account.sol";

contract Tezcatli4337AccountFactory {
    address public immutable entryPoint;

    event AccountCreated(address indexed account, address indexed owner, uint256 salt);

    constructor(address entryPoint_) {
        require(entryPoint_ != address(0), "Invalid entry point");
        entryPoint = entryPoint_;
    }

    function createAccount(address owner, uint256 salt) external returns (Tezcatli4337Account account) {
        address predicted = predictAccountAddress(owner, salt);
        if (predicted.code.length > 0) {
            return Tezcatli4337Account(payable(predicted));
        }

        account = new Tezcatli4337Account{ salt: bytes32(salt) }(owner, entryPoint);
        emit AccountCreated(address(account), owner, salt);
    }

    function predictAccountAddress(address owner, uint256 salt) public view returns (address) {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(type(Tezcatli4337Account).creationCode, abi.encode(owner, entryPoint))
        );

        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            bytes32(salt),
            bytecodeHash
        )))));
    }
}
