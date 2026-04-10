// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "./TezcatliUserOperation.sol";

contract Tezcatli4337Account is IERC1271, ITezcatliAccount {
    bytes4 internal constant MAGIC_VALUE = IERC1271.isValidSignature.selector;

    address public immutable entryPoint;
    address public owner;

    event OwnerChanged(address indexed previousOwner, address indexed newOwner);
    event Executed(address indexed target, uint256 value, bytes data);
    event BatchExecuted(uint256 count);

    error InvalidOwner();
    error InvalidTarget();
    error Unauthorized();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrEntryPoint() {
        if (msg.sender != owner && msg.sender != entryPoint) revert Unauthorized();
        _;
    }

    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert Unauthorized();
        _;
    }

    constructor(address owner_, address entryPoint_) {
        if (owner_ == address(0)) revert InvalidOwner();
        if (entryPoint_ == address(0)) revert InvalidTarget();

        owner = owner_;
        entryPoint = entryPoint_;
        emit OwnerChanged(address(0), owner_);
    }

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidOwner();

        address previousOwner = owner;
        owner = newOwner;

        emit OwnerChanged(previousOwner, newOwner);
    }

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external onlyEntryPoint returns (uint256 validationData) {
        bytes32 signedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        bool isValid = SignatureChecker.isValidSignatureNow(owner, signedHash, userOp.signature);

        if (missingAccountFunds > 0) {
            (bool success, ) = payable(entryPoint).call{ value: missingAccountFunds }("");
            success;
        }

        return isValid ? 0 : 1;
    }

    function execute(address target, uint256 value, bytes calldata data) external onlyOwnerOrEntryPoint returns (bytes memory result) {
        if (target == address(0)) revert InvalidTarget();

        (bool success, bytes memory returnData) = target.call{ value: value }(data);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }

        emit Executed(target, value, data);
        return returnData;
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external onlyOwnerOrEntryPoint {
        uint256 length = targets.length;
        if (length == 0) revert InvalidTarget();
        if (length != values.length || length != datas.length) revert Unauthorized();

        for (uint256 i = 0; i < length; i++) {
            if (targets[i] == address(0)) revert InvalidTarget();

            (bool success, bytes memory returnData) = targets[i].call{ value: values[i] }(datas[i]);
            if (!success) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }

            emit Executed(targets[i], values[i], datas[i]);
        }

        emit BatchExecuted(length);
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return SignatureChecker.isValidSignatureNow(owner, hash, signature) ? MAGIC_VALUE : bytes4(0xffffffff);
    }

    receive() external payable {}
}
