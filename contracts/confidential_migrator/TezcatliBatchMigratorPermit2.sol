// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITezcatliWrappedTokenBatch {
    function underlyingToken() external view returns (address);
    function shieldTo(address recipient, uint64 amount) external;
}

interface ITezcatliComplianceGateBatch {
    function canShield(address wallet, bytes32 periodTag, uint256 publicAmount) external view returns (bool, uint8);
}

interface ITezcatli4337AccountFactoryBatch {
    function createAccount(address owner, uint256 salt) external returns (address account);
    function predictAccountAddress(address owner, uint256 salt) external view returns (address);
}

interface IAllowanceTransfer {
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitBatch {
        PermitDetails[] details;
        address spender;
        uint256 sigDeadline;
    }

    struct AllowanceTransferDetails {
        address from;
        address to;
        uint160 amount;
        address token;
    }

    function permit(address owner, PermitBatch calldata permitBatch, bytes calldata signature) external;

    function transferFrom(AllowanceTransferDetails[] calldata transferDetails) external;
}

contract TezcatliBatchMigratorPermit2 is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IAllowanceTransfer public immutable permit2;
    ITezcatli4337AccountFactoryBatch public immutable accountFactory;

    mapping(address => address) public wrappedTokenForUnderlying;
    bool public complianceEnabled;
    address public complianceGate;

    event WrappedTokenConfigured(address indexed underlying, address indexed wrappedToken);
    event ComplianceGateUpdated(address indexed complianceGate, bool enabled);
    event BatchPermitMigrationExecuted(
        address indexed owner,
        address indexed confidentialAccount,
        uint256 indexed salt,
        uint256 assetCount
    );
    event MigrationExecuted(
        address indexed owner,
        address indexed token,
        address indexed confidentialToken,
        uint256 amount
    );
    event ComplianceReportRequired(address indexed recipient, bytes32 indexed periodTag, uint8 reasonCode);

    error InvalidAddress();
    error InvalidBatch();
    error PermitSpenderMismatch();
    error UnsupportedToken(address token);
    error WrapperMismatch(address token, address wrappedToken);
    error AmountExceedsUint64(address token, uint256 amount);
    error ComplianceRejected(uint8 reasonCode);

    constructor(address permit2_, address accountFactory_) Ownable(msg.sender) {
        if (permit2_ == address(0) || accountFactory_ == address(0)) revert InvalidAddress();
        permit2 = IAllowanceTransfer(permit2_);
        accountFactory = ITezcatli4337AccountFactoryBatch(accountFactory_);
    }

    function predictAccountAddress(address owner, uint256 salt) external view returns (address) {
        return accountFactory.predictAccountAddress(owner, salt);
    }

    function setWrappedToken(address underlying, address wrappedToken) external onlyOwner {
        _setWrappedToken(underlying, wrappedToken);
    }

    function setWrappedTokens(address[] calldata underlyings, address[] calldata wrappedTokens) external onlyOwner {
        uint256 length = underlyings.length;
        if (length == 0 || length != wrappedTokens.length) revert InvalidBatch();

        for (uint256 i = 0; i < length; i++) {
            _setWrappedToken(underlyings[i], wrappedTokens[i]);
        }
    }

    function setComplianceGate(address gate) external onlyOwner {
        complianceGate = gate;
        emit ComplianceGateUpdated(gate, complianceEnabled);
    }

    function setComplianceEnabled(bool enabled) external onlyOwner {
        complianceEnabled = enabled;
        emit ComplianceGateUpdated(complianceGate, enabled);
    }

    function createAccountAndMigrateBatchWithPermit2(
        address owner,
        uint256 salt,
        IAllowanceTransfer.PermitBatch calldata permitBatch,
        bytes calldata signature
    ) external nonReentrant returns (address account) {
        if (owner == address(0)) revert InvalidAddress();
        if (permitBatch.details.length == 0) revert InvalidBatch();
        if (permitBatch.spender != address(this)) revert PermitSpenderMismatch();

        account = accountFactory.predictAccountAddress(owner, salt);
        if (account.code.length == 0) {
            account = accountFactory.createAccount(owner, salt);
        }

        uint256 length = permitBatch.details.length;
        IAllowanceTransfer.AllowanceTransferDetails[] memory transferDetails =
            new IAllowanceTransfer.AllowanceTransferDetails[](length);

        for (uint256 i = 0; i < length; i++) {
            IAllowanceTransfer.PermitDetails calldata detail = permitBatch.details[i];
            address wrappedTokenAddress = wrappedTokenForUnderlying[detail.token];

            if (wrappedTokenAddress == address(0)) revert UnsupportedToken(detail.token);
            if (detail.amount == 0) revert InvalidBatch();
            if (uint256(detail.amount) > type(uint64).max) {
                revert AmountExceedsUint64(detail.token, detail.amount);
            }

            ITezcatliWrappedTokenBatch wrappedToken = ITezcatliWrappedTokenBatch(wrappedTokenAddress);
            if (wrappedToken.underlyingToken() != detail.token) {
                revert WrapperMismatch(detail.token, wrappedTokenAddress);
            }

            _checkCompliance(account, bytes32(0), uint256(detail.amount));
            transferDetails[i] = IAllowanceTransfer.AllowanceTransferDetails({
                from: owner,
                to: address(this),
                amount: detail.amount,
                token: detail.token
            });
        }

        permit2.permit(owner, permitBatch, signature);
        permit2.transferFrom(transferDetails);

        for (uint256 i = 0; i < length; i++) {
            IAllowanceTransfer.PermitDetails calldata detail = permitBatch.details[i];
            address wrappedTokenAddress = wrappedTokenForUnderlying[detail.token];
            IERC20(detail.token).forceApprove(wrappedTokenAddress, uint256(detail.amount));
            ITezcatliWrappedTokenBatch(wrappedTokenAddress).shieldTo(account, uint64(detail.amount));

            emit MigrationExecuted(owner, detail.token, wrappedTokenAddress, uint256(detail.amount));
        }

        emit BatchPermitMigrationExecuted(owner, account, salt, length);
    }

    function _setWrappedToken(address underlying, address wrappedToken) internal {
        if (underlying == address(0) || wrappedToken == address(0)) revert InvalidAddress();
        wrappedTokenForUnderlying[underlying] = wrappedToken;
        emit WrappedTokenConfigured(underlying, wrappedToken);
    }

    function _checkCompliance(address recipient, bytes32 periodTag, uint256 amount) internal {
        if (!complianceEnabled || complianceGate == address(0)) return;

        (bool canShield, uint8 reasonCode) =
            ITezcatliComplianceGateBatch(complianceGate).canShield(recipient, periodTag, amount);

        if (!canShield) {
            emit ComplianceReportRequired(recipient, periodTag, reasonCode);
            revert ComplianceRejected(reasonCode);
        }
    }
}
