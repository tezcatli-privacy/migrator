// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./TezcatliUserOperation.sol";

contract TezcatliEntryPointMock is ITezcatliEntryPoint {
    mapping(address => mapping(uint192 => uint256)) private _nonces;
    mapping(address => uint256) private _deposits;

    error FailedOp(uint256 opIndex, string reason);

    function depositTo(address account) external payable {
        _deposits[account] += msg.value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _deposits[account];
    }

    function withdrawTo(address payable withdrawAddress, uint256 amount) external {
        _deposits[msg.sender] -= amount;
        (bool success, ) = withdrawAddress.call{ value: amount }("");
        require(success, "Withdraw failed");
    }

    function getNonce(address sender, uint192 key) external view returns (uint256) {
        return _nonces[sender][key];
    }

    function getUserOpHash(PackedUserOperation calldata userOp) public view returns (bytes32) {
        bytes32 innerHash = keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                keccak256(userOp.paymasterAndData)
            )
        );
        return keccak256(abi.encode(innerHash, address(this), block.chainid));
    }

    function handleOps(PackedUserOperation[] calldata ops, address payable) external {
        for (uint256 i = 0; i < ops.length; i++) {
            _handleOp(i, ops[i]);
        }
    }

    function _handleOp(uint256 opIndex, PackedUserOperation calldata op) internal {
        uint192 key = uint192(op.nonce >> 64);
        uint64 seq = uint64(op.nonce);
        if (seq != uint64(_nonces[op.sender][key])) {
            revert FailedOp(opIndex, "AA25 invalid account nonce");
        }

        if (op.initCode.length > 0 && op.sender.code.length == 0) {
            if (op.initCode.length < 20) revert FailedOp(opIndex, "AA13 initCode failed");

            address factory = address(bytes20(op.initCode[:20]));
            bytes memory initCallData = op.initCode[20:];
            (bool success, ) = factory.call(initCallData);
            if (!success) {
                revert FailedOp(opIndex, "AA13 initCode failed");
            }
            if (op.sender.code.length == 0) {
                revert FailedOp(opIndex, "AA15 initCode must create sender");
            }
        }

        bytes32 userOpHash = getUserOpHash(op);
        uint256 validationData = ITezcatliAccount(op.sender).validateUserOp(op, userOpHash, 0);
        if (validationData != 0) {
            revert FailedOp(opIndex, "AA24 signature error");
        }

        bytes memory paymasterContext;
        address paymaster;
        bool hasPaymaster = op.paymasterAndData.length >= 20;
        if (hasPaymaster) {
            paymaster = address(bytes20(op.paymasterAndData[:20]));
            (paymasterContext, validationData) = ITezcatliPaymaster(paymaster).validatePaymasterUserOp(
                op,
                userOpHash,
                0
            );
            if (validationData != 0) {
                revert FailedOp(opIndex, "AA34 paymaster validation failed");
            }
        }

        if (op.callData.length > 0) {
            (bool success, bytes memory result) = op.sender.call(op.callData);
            if (!success) {
                if (result.length > 0) {
                    assembly {
                        revert(add(result, 32), mload(result))
                    }
                }
                revert FailedOp(opIndex, "AA23 execution reverted");
            }
        }

        if (hasPaymaster) {
            ITezcatliPaymaster(paymaster).postOp(ITezcatliPaymaster.PostOpMode.opSucceeded, paymasterContext, 0, 0);
        }

        _nonces[op.sender][key] = _nonces[op.sender][key] + 1;
    }

    receive() external payable {}
}
