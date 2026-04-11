// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

contract TezcatliSmartAccount is IERC1271 {
    bytes4 internal constant MAGIC_VALUE = IERC1271.isValidSignature.selector;

    address public owner;
    uint256 public executionNonce;

    event OwnerChanged(address indexed previousOwner, address indexed newOwner);
    event Executed(address indexed target, uint256 value, bytes data);
    event BatchExecuted(uint256 count);
    event ExecutedBySig(address indexed relayer, uint256 indexed nonce, address indexed target, uint256 value);
    event BatchExecutedBySig(address indexed relayer, uint256 indexed nonce, uint256 count);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address owner_) {
        require(owner_ != address(0), "Invalid owner");
        owner = owner_;
        emit OwnerChanged(address(0), owner_);
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");

        address previousOwner = owner;
        owner = newOwner;

        emit OwnerChanged(previousOwner, newOwner);
    }

    function execute(address target, uint256 value, bytes calldata data) external onlyOwner returns (bytes memory result) {
        require(target != address(0), "Invalid target");

        (bool success, bytes memory returnData) = target.call{ value: value }(data);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }

        emit Executed(target, value, data);
        return returnData;
    }

    function getExecuteDigest(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                target,
                value,
                keccak256(data),
                nonce,
                deadline
            )
        );
    }

    function getExecuteBatchDigest(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                keccak256(abi.encode(targets, values, datas)),
                nonce,
                deadline
            )
        );
    }

    function executeBySig(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bytes memory result) {
        require(target != address(0), "Invalid target");
        require(block.timestamp <= deadline, "Expired authorization");

        uint256 nonce = executionNonce;
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            getExecuteDigest(target, value, data, nonce, deadline)
        );
        require(SignatureChecker.isValidSignatureNow(owner, digest, signature), "Invalid signature");

        executionNonce = nonce + 1;

        (bool success, bytes memory returnData) = target.call{ value: value }(data);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }

        emit Executed(target, value, data);
        emit ExecutedBySig(msg.sender, nonce, target, value);
        return returnData;
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external onlyOwner {
        uint256 length = targets.length;

        require(length > 0, "Empty batch");
        require(length == values.length && length == datas.length, "Length mismatch");

        for (uint256 i = 0; i < length; i++) {
            require(targets[i] != address(0), "Invalid target");

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

    function executeBatchBySig(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        uint256 deadline,
        bytes calldata signature
    ) external {
        uint256 length = targets.length;
        require(length > 0, "Empty batch");
        require(length == values.length && length == datas.length, "Length mismatch");
        require(block.timestamp <= deadline, "Expired authorization");

        uint256 nonce = executionNonce;
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            getExecuteBatchDigest(targets, values, datas, nonce, deadline)
        );
        require(SignatureChecker.isValidSignatureNow(owner, digest, signature), "Invalid signature");

        executionNonce = nonce + 1;

        for (uint256 i = 0; i < length; i++) {
            require(targets[i] != address(0), "Invalid target");

            (bool success, bytes memory returnData) = targets[i].call{ value: values[i] }(datas[i]);
            if (!success) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }

            emit Executed(targets[i], values[i], datas[i]);
        }

        emit BatchExecuted(length);
        emit BatchExecutedBySig(msg.sender, nonce, length);
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return SignatureChecker.isValidSignatureNow(owner, hash, signature) ? MAGIC_VALUE : bytes4(0xffffffff);
    }

    receive() external payable {}
}
