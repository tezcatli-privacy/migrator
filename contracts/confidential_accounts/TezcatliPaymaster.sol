// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./TezcatliUserOperation.sol";

interface IComplianceGate {
    function canShield(address wallet, bytes32 periodTag, uint256 publicAmount) external view returns (bool, uint8);
}

contract TezcatliPaymaster is ITezcatliPaymaster, Ownable {
    bytes4 private constant EXECUTE_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes)"));
    uint256 private constant MAX_FEE_BPS = 1000;
    uint256 private constant PAYMASTER_DATA_OFFSET = 20;
    uint256 private constant PAYMASTER_PERIOD_TAG_OFFSET = PAYMASTER_DATA_OFFSET + 32;

    IERC20 public feeToken;
    address public treasury;
    address public approvedFactory;
    uint256 public feeRateBps;
    uint256 public maxFeeCap;
    uint256 public approvedTargetsCount;
    bool public whitelistEnabled;
    bool public complianceEnabled;
    address public complianceGate;

    mapping(address => bool) public approvedTargets;
    mapping(address => bool) public whitelisted;

    address public immutable entryPoint;

    event FeeCollected(address indexed account, uint256 amount);
    event FeeConfigUpdated(uint256 feeRateBps, uint256 maxFeeCap);
    event TreasuryUpdated(address indexed treasury);
    event FeeTokenUpdated(address indexed token);
    event FactoryUpdated(address indexed factory);
    event TargetApproved(address indexed target, bool approved);
    event WhitelistUpdated(address indexed account, bool status);
    event WhitelistEnabledUpdated(bool enabled);
    event ComplianceGateUpdated(address indexed complianceGate, bool enabled);
    event ComplianceReportRequired(address indexed account, bytes32 indexed periodTag, uint8 reasonCode);

    error Unauthorized();
    error InvalidAddress();
    error InvalidFeeRate();
    error NotWhitelisted();
    error InitCodeTooShort();
    error UnapprovedFactory();
    error NoApprovedTargets();
    error UnsupportedAccountCall();
    error CallDataTooShort();
    error UnapprovedTarget();
    error InsufficientBalanceForFee();
    error FeeTransferFailed();
    error EntryPointTransferFailed();
    error ComplianceRejected(uint8 reasonCode);

    modifier onlyEntryPoint() {
        if (msg.sender != entryPoint) revert Unauthorized();
        _;
    }

    constructor(
        address entryPoint_,
        address feeToken_,
        address treasury_,
        uint256 maxFeeCap_,
        address approvedFactory_,
        address owner_
    ) Ownable(owner_) {
        if (entryPoint_ == address(0) || feeToken_ == address(0) || treasury_ == address(0)) {
            revert InvalidAddress();
        }

        entryPoint = entryPoint_;
        feeToken = IERC20(feeToken_);
        treasury = treasury_;
        maxFeeCap = maxFeeCap_;
        approvedFactory = approvedFactory_;
        feeRateBps = 100;
    }

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256
    ) external view onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        if (whitelistEnabled && !whitelisted[userOp.sender]) revert NotWhitelisted();

        if (userOp.initCode.length > 0 && approvedFactory != address(0)) {
            if (userOp.initCode.length < 20) revert InitCodeTooShort();
            address initFactory = address(bytes20(userOp.initCode[:20]));
            if (initFactory != approvedFactory) revert UnapprovedFactory();
        }

        if (approvedTargetsCount == 0) revert NoApprovedTargets();
        _validateAccountCall(userOp.callData);

        uint256 transferAmount = _decodeTransferAmount(userOp.paymasterAndData);
        bytes32 periodTag = _decodePeriodTag(userOp.paymasterAndData);
        uint8 complianceReason = _checkCompliance(userOp.sender, periodTag, transferAmount);

        uint256 fee = (transferAmount * feeRateBps) / 10_000;
        if (maxFeeCap > 0 && fee > maxFeeCap) {
            fee = maxFeeCap;
        }

        if (feeToken.balanceOf(userOp.sender) < fee) revert InsufficientBalanceForFee();

        context = abi.encode(userOp.sender, fee, periodTag, complianceReason);
        validationData = 0;
    }

    function postOp(
        PostOpMode,
        bytes calldata context,
        uint256,
        uint256
    ) external onlyEntryPoint {
        (address account, uint256 fee, bytes32 periodTag, uint8 complianceReason) = abi.decode(
            context,
            (address, uint256, bytes32, uint8)
        );
        if (complianceReason == 7) {
            emit ComplianceReportRequired(account, periodTag, complianceReason);
        }
        if (fee == 0) return;

        bool success = feeToken.transferFrom(account, treasury, fee);
        if (!success) revert FeeTransferFailed();
        emit FeeCollected(account, fee);
    }

    function setFeeConfig(uint256 feeRateBps_, uint256 maxFeeCap_) external onlyOwner {
        if (feeRateBps_ > MAX_FEE_BPS) revert InvalidFeeRate();
        feeRateBps = feeRateBps_;
        maxFeeCap = maxFeeCap_;
        emit FeeConfigUpdated(feeRateBps_, maxFeeCap_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert InvalidAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setFeeToken(address feeToken_) external onlyOwner {
        if (feeToken_ == address(0)) revert InvalidAddress();
        feeToken = IERC20(feeToken_);
        emit FeeTokenUpdated(feeToken_);
    }

    function setApprovedFactory(address factory_) external onlyOwner {
        approvedFactory = factory_;
        emit FactoryUpdated(factory_);
    }

    function setApprovedTarget(address target, bool approved) external onlyOwner {
        if (target == address(0)) revert InvalidAddress();

        bool current = approvedTargets[target];
        if (approved && !current) {
            approvedTargetsCount++;
        } else if (!approved && current) {
            approvedTargetsCount--;
        }

        approvedTargets[target] = approved;
        emit TargetApproved(target, approved);
    }

    function setWhitelist(address account, bool status) external onlyOwner {
        whitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }

    function setWhitelistEnabled(bool enabled) external onlyOwner {
        whitelistEnabled = enabled;
        emit WhitelistEnabledUpdated(enabled);
    }

    function setComplianceGate(address gate) external onlyOwner {
        complianceGate = gate;
        emit ComplianceGateUpdated(gate, complianceEnabled);
    }

    function setComplianceEnabled(bool enabled) external onlyOwner {
        complianceEnabled = enabled;
        emit ComplianceGateUpdated(complianceGate, enabled);
    }

    function depositToEntryPoint() external payable onlyOwner {
        (bool success, ) = payable(entryPoint).call{ value: msg.value }(
            abi.encodeWithSignature("depositTo(address)", address(this))
        );
        if (!success) revert EntryPointTransferFailed();
    }

    function withdrawFromEntryPoint(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        (bool success, ) = entryPoint.call(
            abi.encodeWithSignature("withdrawTo(address,uint256)", to, amount)
        );
        if (!success) revert EntryPointTransferFailed();
    }

    function _decodeTransferAmount(bytes calldata paymasterAndData) internal pure returns (uint256) {
        if (paymasterAndData.length < PAYMASTER_DATA_OFFSET + 32) {
            return 0;
        }
        return abi.decode(paymasterAndData[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET + 32], (uint256));
    }

    function _decodePeriodTag(bytes calldata paymasterAndData) internal pure returns (bytes32) {
        if (paymasterAndData.length < PAYMASTER_PERIOD_TAG_OFFSET + 32) {
            return bytes32(0);
        }
        return abi.decode(paymasterAndData[PAYMASTER_PERIOD_TAG_OFFSET:PAYMASTER_PERIOD_TAG_OFFSET + 32], (bytes32));
    }

    function _checkCompliance(address account, bytes32 periodTag, uint256 publicAmount) internal view returns (uint8 reasonCode) {
        if (!complianceEnabled || complianceGate == address(0)) {
            return 0;
        }

        bool allowed;
        (allowed, reasonCode) = IComplianceGate(complianceGate).canShield(account, periodTag, publicAmount);
        if (!allowed && reasonCode != 7) {
            revert ComplianceRejected(reasonCode);
        }
        return reasonCode;
    }

    function _validateAccountCall(bytes calldata callData) internal view {
        if (callData.length < 4) revert CallDataTooShort();

        bytes4 selector = bytes4(callData[:4]);
        if (selector != EXECUTE_SELECTOR) revert UnsupportedAccountCall();
        if (callData.length < 36) revert CallDataTooShort();

        address target = address(uint160(uint256(bytes32(callData[4:36]))));
        if (!approvedTargets[target]) revert UnapprovedTarget();
    }

    receive() external payable {}
}
