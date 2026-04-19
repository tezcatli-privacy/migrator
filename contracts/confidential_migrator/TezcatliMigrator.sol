// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface ITezcatliWrappedToken {
    function underlyingToken() external view returns (address);
    function shieldTo(address recipient, uint64 amount) external;
}

interface ITezcatliDustSwap {
    function settlementToken() external view returns (address);
    function swapToSettlement(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);
}

interface ITezcatliComplianceGate {
    function canShield(address wallet, bytes32 periodTag, uint256 publicAmount) external view returns (bool, uint8);
}

contract TezcatliMigrator is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    struct SweepAuthorization {
        address stealthAddress;
        address recipient;
        address token;
        address confidentialToken;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    struct DustSwapAuthorization {
        address stealthAddress;
        address recipient;
        address dustToken;
        address confidentialToken;
        address dustSwap;
        uint256 dustAmount;
        uint256 minSettlementAmount;
        uint256 nonce;
        uint256 deadline;
    }

    mapping(address => uint256) public nonces;
    bool public complianceEnabled;
    address public complianceGate;

    event MigrationExecuted(
        address indexed stealthAddress,
        address indexed token,
        address indexed confidentialToken,
        uint256 amount
    );

    event BatchMigrationExecuted(uint256 count);
    event DustSwapMigrationExecuted(
        address indexed stealthAddress,
        address indexed dustToken,
        address indexed confidentialToken,
        uint256 dustAmount,
        uint256 settlementAmount
    );
    event ComplianceGateUpdated(address indexed complianceGate, bool enabled);
    event ComplianceReportRequired(address indexed recipient, bytes32 indexed periodTag, uint8 reasonCode);

    error ComplianceRejected(uint8 reasonCode);

    constructor() Ownable(msg.sender) {}

    function getSweepDigest(
        SweepAuthorization calldata authorization
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                authorization.stealthAddress,
                authorization.recipient,
                authorization.token,
                authorization.confidentialToken,
                authorization.amount,
                authorization.nonce,
                authorization.deadline
            )
        );
    }

    function getDustSwapDigest(
        DustSwapAuthorization calldata authorization
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                authorization.stealthAddress,
                authorization.recipient,
                authorization.dustToken,
                authorization.confidentialToken,
                authorization.dustSwap,
                authorization.dustAmount,
                authorization.minSettlementAmount,
                authorization.nonce,
                authorization.deadline
            )
        );
    }

    function sweepAndMigrate(
        SweepAuthorization calldata authorization,
        bytes calldata signature
    ) external nonReentrant {
        _sweepAndMigrate(authorization, signature);
    }

    function sweepAndMigrateBatch(
        SweepAuthorization[] calldata authorizations,
        bytes[] calldata signatures
    ) external nonReentrant {
        uint256 length = authorizations.length;

        require(length > 0, "Empty batch");
        require(length == signatures.length, "Length mismatch");

        for (uint256 i = 0; i < length; i++) {
            _sweepAndMigrate(authorizations[i], signatures[i]);
        }

        emit BatchMigrationExecuted(length);
    }

    function sweepSwapAndMigrate(
        DustSwapAuthorization calldata authorization,
        bytes calldata signature
    ) external nonReentrant {
        _sweepSwapAndMigrate(authorization, signature);
    }

    function setComplianceGate(address gate) external onlyOwner {
        complianceGate = gate;
        emit ComplianceGateUpdated(gate, complianceEnabled);
    }

    function setComplianceEnabled(bool enabled) external onlyOwner {
        complianceEnabled = enabled;
        emit ComplianceGateUpdated(complianceGate, enabled);
    }

    function _sweepAndMigrate(
        SweepAuthorization calldata authorization,
        bytes calldata signature
    ) internal {
        require(authorization.stealthAddress != address(0), "Invalid stealth address");
        require(authorization.recipient != address(0), "Invalid recipient");
        require(authorization.token != address(0), "Invalid token");
        require(authorization.confidentialToken != address(0), "Invalid confidential token");
        require(authorization.amount > 0, "Zero amount");
        require(authorization.amount <= type(uint64).max, "Amount exceeds uint64");
        require(block.timestamp <= authorization.deadline, "Expired authorization");
        require(authorization.nonce == nonces[authorization.stealthAddress], "Invalid nonce");

        bytes32 digest = getSweepDigest(authorization).toEthSignedMessageHash();
        require(digest.recover(signature) == authorization.stealthAddress, "Invalid signature");

        nonces[authorization.stealthAddress] += 1;

        ITezcatliWrappedToken wrappedToken = ITezcatliWrappedToken(authorization.confidentialToken);
        IERC20 underlying = IERC20(wrappedToken.underlyingToken());

        require(address(underlying) == authorization.token, "Wrapper mismatch");
        _checkCompliance(authorization.recipient, bytes32(0), authorization.amount);

        underlying.safeTransferFrom(
            authorization.stealthAddress,
            address(this),
            authorization.amount
        );

        underlying.forceApprove(authorization.confidentialToken, authorization.amount);
        wrappedToken.shieldTo(authorization.recipient, uint64(authorization.amount));

        emit MigrationExecuted(
            authorization.stealthAddress,
            authorization.token,
            authorization.confidentialToken,
            authorization.amount
        );
    }

    function _sweepSwapAndMigrate(
        DustSwapAuthorization calldata authorization,
        bytes calldata signature
    ) internal {
        require(authorization.stealthAddress != address(0), "Invalid stealth address");
        require(authorization.recipient != address(0), "Invalid recipient");
        require(authorization.dustToken != address(0), "Invalid dust token");
        require(authorization.confidentialToken != address(0), "Invalid confidential token");
        require(authorization.dustSwap != address(0), "Invalid dust swap");
        require(authorization.dustAmount > 0, "Zero amount");
        require(authorization.minSettlementAmount > 0, "Zero min settlement");
        require(block.timestamp <= authorization.deadline, "Expired authorization");
        require(authorization.nonce == nonces[authorization.stealthAddress], "Invalid nonce");

        bytes32 digest = getDustSwapDigest(authorization).toEthSignedMessageHash();
        require(digest.recover(signature) == authorization.stealthAddress, "Invalid signature");

        nonces[authorization.stealthAddress] += 1;

        ITezcatliWrappedToken wrappedToken = ITezcatliWrappedToken(authorization.confidentialToken);
        ITezcatliDustSwap dustSwap = ITezcatliDustSwap(authorization.dustSwap);
        IERC20 dustToken = IERC20(authorization.dustToken);
        IERC20 settlementToken = IERC20(dustSwap.settlementToken());

        require(address(settlementToken) == wrappedToken.underlyingToken(), "Wrapper mismatch");

        dustToken.safeTransferFrom(
            authorization.stealthAddress,
            address(this),
            authorization.dustAmount
        );

        dustToken.forceApprove(authorization.dustSwap, authorization.dustAmount);

        uint256 settlementAmount = dustSwap.swapToSettlement(
            authorization.dustToken,
            authorization.dustAmount,
            authorization.minSettlementAmount,
            address(this)
        );

        require(settlementAmount > 0, "Zero settlement amount");
        require(settlementAmount <= type(uint64).max, "Settlement exceeds uint64");
        _checkCompliance(authorization.recipient, bytes32(0), settlementAmount);

        settlementToken.forceApprove(authorization.confidentialToken, settlementAmount);
        wrappedToken.shieldTo(authorization.recipient, uint64(settlementAmount));

        emit DustSwapMigrationExecuted(
            authorization.stealthAddress,
            authorization.dustToken,
            authorization.confidentialToken,
            authorization.dustAmount,
            settlementAmount
        );
    }

    function _checkCompliance(address recipient, bytes32 periodTag, uint256 amount) internal {
        if (!complianceEnabled || complianceGate == address(0)) return;
        (bool allowed, uint8 reasonCode) = ITezcatliComplianceGate(complianceGate).canShield(recipient, periodTag, amount);
        if (!allowed && reasonCode != 7) {
            revert ComplianceRejected(reasonCode);
        }
        if (reasonCode == 7) {
            emit ComplianceReportRequired(recipient, periodTag, reasonCode);
        }
    }
}
