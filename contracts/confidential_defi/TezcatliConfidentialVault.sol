// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FHE, ebool, euint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import { FHESafeMath } from "fhenix-confidential-contracts/contracts/utils/FHESafeMath.sol";
import { IFHERC20Receiver } from "fhenix-confidential-contracts/contracts/interfaces/IFHERC20Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITezcatliConfidentialAsset {
    function confidentialTransfer(address to, euint64 amount) external returns (euint64 transferred);
}

interface ITezcatliWrappedConfidentialAsset is ITezcatliConfidentialAsset {
    function underlyingToken() external view returns (address);
    function shieldTo(address recipient, uint64 amount) external;
    function unshield(uint64 amount) external;
    function confidentialBalanceOf(address account) external view returns (euint64);
}

interface ITezcatliStrategyAdapter {
    function vault() external view returns (address);
    function settlementAsset() external view returns (address);
    function deploy(uint256 assets, uint256 minSharesOut) external returns (uint256 sharesOut);
    function redeem(uint256 shares, uint256 minAssetsOut, address receiver) external returns (uint256 assetsOut);
    function totalManagedAssets() external view returns (uint256);
}

interface ITezcatliFeeModel {
    function isValidLockOption(uint8 lockOption) external pure returns (bool);
    function currentFeeBps(uint8 lockOption, uint64 startTimestamp, uint64 currentTimestamp) external pure returns (uint16);
}

interface ITezcatliVaultComplianceGate {
    function canShield(address wallet, bytes32 periodTag, uint256 publicAmount) external view returns (bool, uint8);
    function canUnshield(address wallet, bytes32 periodTag, uint256 publicAmount) external view returns (bool, uint8);
}

contract TezcatliConfidentialVault is IFHERC20Receiver, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable asset;
    address public coordinator;
    address public strategyAdapter;
    address public feeModel;
    address public feeRecipient;
    uint64 public minWithdrawDelay;
    uint256 public strategyShares;
    bool public settlementPending;
    bool public complianceEnabled;
    address public complianceGate;
    mapping(address => bool) public approvedStrategyAdapters;
    mapping(address => uint256) public strategySharesByAdapter;

    mapping(address => euint64) private _confidentialShares;
    mapping(address => euint64) private _principalDepositedByUser;
    mapping(address => euint64) private _grossPositionSnapshotByUser;
    mapping(address => euint64) private _netPositionSnapshotByUser;
    mapping(address => euint64) private _pendingYieldSnapshotByUser;
    mapping(address => euint64) private _pendingFeeSnapshotByUser;
    euint64 private _totalConfidentialShares;
    mapping(address => uint8) private _lockOptionByUser;
    mapping(address => uint64) private _lockStartByUser;
    mapping(address => uint64) private _withdrawUnlockAtByUser;
    mapping(address => bool) private _hasLockOption;
    mapping(address => bool) private _hasActivePosition;
    mapping(address => uint64) private _positionSnapshotUpdatedAtByUser;
    address[] private _registeredStrategyAdapters;
    mapping(address => bool) private _isRegisteredStrategyAdapter;
    uint256 private _activePositionCount;

    event DepositRecorded(address indexed sender, address indexed beneficiary, euint64 amount);
    event WithdrawalExecuted(address indexed owner, address indexed recipient, euint64 amount);
    event CoordinatorUpdated(address indexed previousCoordinator, address indexed newCoordinator);
    event StrategyAdapterUpdated(address indexed previousAdapter, address indexed newAdapter);
    event StrategyAdapterApprovalUpdated(address indexed adapter, bool approved);
    event FeeModelUpdated(address indexed previousFeeModel, address indexed newFeeModel);
    event FeeRecipientUpdated(address indexed previousFeeRecipient, address indexed newFeeRecipient);
    event MinWithdrawDelayUpdated(uint64 previousDelay, uint64 newDelay);
    event SettlementPendingUpdated(bool status);
    event ComplianceGateUpdated(address indexed complianceGate, bool enabled);
    event ComplianceReportRequired(address indexed account, bytes32 indexed periodTag, uint8 reasonCode, bool isUnshieldPath);
    event UserLockOptionConfigured(address indexed user, uint8 lockOption, uint64 startTimestamp);
    event YieldFeeCharged(address indexed user, address indexed feeRecipient, euint64 feeAmount, uint16 feeBps);
    event StrategyDeployed(address indexed adapter, uint64 assets, uint256 sharesOut);
    event StrategyRedeemed(address indexed adapter, uint256 sharesIn, uint256 assetsOut);
    event EmergencyTokenRecovered(address indexed token, address indexed to, uint256 amount);

    error InvalidAsset();
    error InvalidBeneficiary();
    error InvalidRecipient();
    error UnauthorizedAsset();
    error UnauthorizedCoordinator();
    error AssetRecoveryDisabled();
    error InvalidRecoveryAddress();
    error InvalidStrategyAdapter();
    error StrategyAdapterNotApproved();
    error StrategyNotConfigured();
    error InvalidFeeModel();
    error InvalidFeeRecipient();
    error InvalidLockOption();
    error WithdrawLocked(uint64 unlockAt);
    error StrategyPositionOpen();
    error InvalidAmount();
    error SettlementPendingCritical();
    error ComplianceRejected(uint8 reasonCode);

    constructor(address asset_, address owner_) Ownable(owner_) {
        if (asset_ == address(0)) revert InvalidAsset();
        asset = asset_;
        feeRecipient = owner_;
        minWithdrawDelay = 7 days;
    }

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert UnauthorizedCoordinator();
        _;
    }

    function onConfidentialTransferReceived(
        address,
        address from,
        euint64 amount,
        bytes calldata data
    ) external whenNotPaused returns (ebool) {
        if (msg.sender != asset) revert UnauthorizedAsset();

        address beneficiary = from;
        bool lockOptionProvided = false;
        uint8 lockOption = 0;
        if (data.length > 0) {
            if (data.length == 32) {
                beneficiary = abi.decode(data, (address));
            } else if (data.length == 64) {
                (beneficiary, lockOption) = abi.decode(data, (address, uint8));
                lockOptionProvided = true;
            } else {
                revert InvalidBeneficiary();
            }
        }
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        _checkShieldCompliance(beneficiary, bytes32(0), 1);

        ebool accepted = _recordDeposit(beneficiary, amount);

        if (lockOptionProvided) {
            if (feeModel == address(0)) revert InvalidFeeModel();
            if (!ITezcatliFeeModel(feeModel).isValidLockOption(lockOption)) revert InvalidLockOption();

            _lockOptionByUser[beneficiary] = lockOption;
            _lockStartByUser[beneficiary] = uint64(block.timestamp);
            _hasLockOption[beneficiary] = true;
            emit UserLockOptionConfigured(beneficiary, lockOption, uint64(block.timestamp));
        }

        _refreshPositionSnapshot(beneficiary);
        emit DepositRecorded(from, beneficiary, amount);
        FHE.allow(accepted, msg.sender);
        return accepted;
    }

    function withdrawConfidential(address recipient) external nonReentrant whenNotPaused returns (euint64 transferred) {
        if (recipient == address(0)) revert InvalidRecipient();

        uint64 unlockAt = _withdrawUnlockAtByUser[msg.sender];
        if (unlockAt > 0 && block.timestamp < unlockAt) revert WithdrawLocked(unlockAt);
        if (settlementPending) revert SettlementPendingCritical();
        if (strategyShares != 0) revert StrategyPositionOpen();
        if (!_hasActivePosition[msg.sender]) revert InvalidAmount();
        _checkUnshieldCompliance(msg.sender, bytes32(0), 1);

        euint64 userShares = _confidentialShares[msg.sender];
        euint64 userPrincipal = _principalDepositedByUser[msg.sender];
        euint64 zero = FHE.asEuint64(0);
        euint64 payoutAmount;
        euint64 feeAmount = zero;
        uint16 feeBps = 0;
        euint64 totalShares = _totalConfidentialShares;
        euint64 vaultAssets = ITezcatliWrappedConfidentialAsset(asset).confidentialBalanceOf(address(this));
        euint64 grossAmount = FHE.div(FHE.mul(userShares, vaultAssets), totalShares);
        payoutAmount = grossAmount;

        if (_hasLockOption[msg.sender] && feeModel != address(0)) {
            feeBps = ITezcatliFeeModel(feeModel).currentFeeBps(
                _lockOptionByUser[msg.sender],
                _lockStartByUser[msg.sender],
                uint64(block.timestamp)
            );

            feeAmount = _computeYieldFeeCeil(grossAmount, userPrincipal, feeBps);
            payoutAmount = FHE.sub(grossAmount, feeAmount);
        }

        euint64 newUserShares = zero;
        euint64 newTotalShares;
        (, newTotalShares) = FHESafeMath.tryDecrease(totalShares, userShares);
        _confidentialShares[msg.sender] = newUserShares;
        _principalDepositedByUser[msg.sender] = zero;
        _totalConfidentialShares = newTotalShares;
        _hasActivePosition[msg.sender] = false;
        _activePositionCount -= 1;
        FHE.allowThis(newUserShares);
        FHE.allow(newUserShares, msg.sender);
        FHE.allowThis(zero);
        FHE.allow(zero, msg.sender);
        FHE.allowThis(newTotalShares);

        FHE.allowThis(payoutAmount);
        FHE.allow(payoutAmount, msg.sender);
        FHE.allow(payoutAmount, asset);

        transferred = ITezcatliConfidentialAsset(asset).confidentialTransfer(recipient, payoutAmount);

        if (feeRecipient != address(0) && feeBps > 0) {
            FHE.allowThis(feeAmount);
            FHE.allow(feeAmount, msg.sender);
            FHE.allow(feeAmount, asset);
            euint64 protocolFee = ITezcatliConfidentialAsset(asset).confidentialTransfer(feeRecipient, feeAmount);
            emit YieldFeeCharged(msg.sender, feeRecipient, protocolFee, feeBps);
        }
        _clearPositionSnapshot(msg.sender);
        FHE.allow(transferred, msg.sender);
        emit WithdrawalExecuted(msg.sender, recipient, transferred);
    }

    function setCoordinator(address newCoordinator) external onlyOwner {
        address previousCoordinator = coordinator;
        coordinator = newCoordinator;
        emit CoordinatorUpdated(previousCoordinator, newCoordinator);
    }

    function setSettlementPending(bool status) external onlyCoordinator {
        settlementPending = status;
        emit SettlementPendingUpdated(status);
    }

    function setStrategyAdapter(address newStrategyAdapter) external onlyOwner {
        if (newStrategyAdapter != address(0)) {
            _validateStrategyAdapter(newStrategyAdapter);
            _registerStrategyAdapter(newStrategyAdapter);
            if (!approvedStrategyAdapters[newStrategyAdapter]) {
                approvedStrategyAdapters[newStrategyAdapter] = true;
                emit StrategyAdapterApprovalUpdated(newStrategyAdapter, true);
            }
        }

        address previousAdapter = strategyAdapter;
        strategyAdapter = newStrategyAdapter;
        emit StrategyAdapterUpdated(previousAdapter, newStrategyAdapter);
    }

    function setStrategyAdapterApproval(address adapter, bool approved) external onlyOwner {
        if (adapter == address(0)) revert InvalidStrategyAdapter();
        if (approved) {
            _validateStrategyAdapter(adapter);
            _registerStrategyAdapter(adapter);
        } else if (strategySharesByAdapter[adapter] != 0) {
            revert StrategyPositionOpen();
        }

        approvedStrategyAdapters[adapter] = approved;
        emit StrategyAdapterApprovalUpdated(adapter, approved);
    }

    function setFeeModel(address newFeeModel) external onlyOwner {
        if (newFeeModel != address(0) && !ITezcatliFeeModel(newFeeModel).isValidLockOption(0)) {
            revert InvalidFeeModel();
        }

        address previousFeeModel = feeModel;
        feeModel = newFeeModel;
        emit FeeModelUpdated(previousFeeModel, newFeeModel);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert InvalidFeeRecipient();

        address previousFeeRecipient = feeRecipient;
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(previousFeeRecipient, newFeeRecipient);
    }

    function setMinWithdrawDelay(uint64 newDelay) external onlyOwner {
        uint64 previousDelay = minWithdrawDelay;
        minWithdrawDelay = newDelay;
        emit MinWithdrawDelayUpdated(previousDelay, newDelay);
    }

    function setComplianceGate(address newComplianceGate) external onlyOwner {
        complianceGate = newComplianceGate;
        emit ComplianceGateUpdated(newComplianceGate, complianceEnabled);
    }

    function setComplianceEnabled(bool enabled) external onlyOwner {
        complianceEnabled = enabled;
        emit ComplianceGateUpdated(complianceGate, enabled);
    }

    function coordinatorDeployToStrategy(
        address adapter,
        uint64 assets,
        uint256 minSharesOut
    ) external onlyCoordinator nonReentrant whenNotPaused returns (uint256 sharesOut) {
        sharesOut = _coordinatorDeployToStrategy(adapter, assets, minSharesOut);
    }

    function _coordinatorDeployToStrategy(
        address adapter,
        uint64 assets,
        uint256 minSharesOut
    ) internal returns (uint256 sharesOut) {
        if (adapter == address(0)) revert StrategyNotConfigured();
        if (!approvedStrategyAdapters[adapter]) revert StrategyAdapterNotApproved();
        if (assets == 0) revert InvalidAmount();

        ITezcatliWrappedConfidentialAsset wrappedAsset = ITezcatliWrappedConfidentialAsset(asset);
        wrappedAsset.unshield(assets);

        IERC20 settlementAsset = IERC20(wrappedAsset.underlyingToken());
        settlementAsset.forceApprove(adapter, uint256(assets));

        sharesOut = ITezcatliStrategyAdapter(adapter).deploy(uint256(assets), minSharesOut);
        strategyShares += sharesOut;
        strategySharesByAdapter[adapter] += sharesOut;

        emit StrategyDeployed(adapter, assets, sharesOut);
    }

    function coordinatorRedeemFromStrategy(
        address adapter,
        uint256 shares,
        uint64 minAssetsOut
    ) external onlyCoordinator nonReentrant whenNotPaused returns (uint256 assetsOut) {
        assetsOut = _coordinatorRedeemFromStrategy(adapter, shares, minAssetsOut);
    }

    function _coordinatorRedeemFromStrategy(
        address adapter,
        uint256 shares,
        uint64 minAssetsOut
    ) internal returns (uint256 assetsOut) {
        if (adapter == address(0)) revert StrategyNotConfigured();
        if (!approvedStrategyAdapters[adapter]) revert StrategyAdapterNotApproved();
        if (shares == 0 || shares > strategyShares) revert InvalidAmount();
        if (shares > strategySharesByAdapter[adapter]) revert InvalidAmount();

        assetsOut = ITezcatliStrategyAdapter(adapter).redeem(shares, uint256(minAssetsOut), address(this));
        if (assetsOut > type(uint64).max) revert InvalidAmount();

        ITezcatliWrappedConfidentialAsset wrappedAsset = ITezcatliWrappedConfidentialAsset(asset);
        IERC20 settlementAsset = IERC20(wrappedAsset.underlyingToken());
        settlementAsset.forceApprove(asset, assetsOut);
        wrappedAsset.shieldTo(address(this), uint64(assetsOut));

        strategyShares -= shares;
        strategySharesByAdapter[adapter] -= shares;
        emit StrategyRedeemed(adapter, shares, assetsOut);
    }

    function strategyManagedAssetsOf(address adapter) external view returns (uint256) {
        if (!approvedStrategyAdapters[adapter] && strategySharesByAdapter[adapter] == 0) return 0;
        return ITezcatliStrategyAdapter(adapter).totalManagedAssets();
    }

    function confidentialSharesOf(address account) external view returns (euint64) {
        return _confidentialShares[account];
    }

    function principalDepositedOf(address account) external view returns (euint64) {
        return _principalDepositedByUser[account];
    }

    function grossPositionSnapshotOf(address account) external view returns (euint64) {
        return _grossPositionSnapshotByUser[account];
    }

    function netPositionSnapshotOf(address account) external view returns (euint64) {
        return _netPositionSnapshotByUser[account];
    }

    function pendingYieldSnapshotOf(address account) external view returns (euint64) {
        return _pendingYieldSnapshotByUser[account];
    }

    function pendingFeeSnapshotOf(address account) external view returns (euint64) {
        return _pendingFeeSnapshotByUser[account];
    }

    function hasActivePosition(address account) external view returns (bool) {
        return _hasActivePosition[account];
    }

    function positionSnapshotUpdatedAt(address account) external view returns (uint64) {
        return _positionSnapshotUpdatedAtByUser[account];
    }

    function registeredStrategyAdapters() external view returns (address[] memory) {
        return _registeredStrategyAdapters;
    }

    function refreshPositionSnapshot(address account) external {
        _refreshPositionSnapshot(account);
    }

    function hasLockOption(address account) external view returns (bool) {
        return _hasLockOption[account];
    }

    function lockOptionOf(address account) external view returns (uint8) {
        return _lockOptionByUser[account];
    }

    function lockStartOf(address account) external view returns (uint64) {
        return _lockStartByUser[account];
    }

    function withdrawAvailableAt(address account) external view returns (uint64) {
        return _withdrawUnlockAtByUser[account];
    }

    function currentWithdrawalFeeBps(address account) external view returns (uint16) {
        if (!_hasLockOption[account] || feeModel == address(0)) return 0;
        return ITezcatliFeeModel(feeModel).currentFeeBps(_lockOptionByUser[account], _lockStartByUser[account], uint64(block.timestamp));
    }

    function totalConfidentialShares() external view returns (euint64) {
        return _totalConfidentialShares;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecoveryAddress();
        if (token == asset) revert AssetRecoveryDisabled();

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyTokenRecovered(token, to, amount);
    }

    function _validateStrategyAdapter(address adapterAddress) internal view {
        ITezcatliStrategyAdapter adapter = ITezcatliStrategyAdapter(adapterAddress);
        if (adapter.vault() != address(this)) revert InvalidStrategyAdapter();

        address expectedSettlementAsset = ITezcatliWrappedConfidentialAsset(asset).underlyingToken();
        if (adapter.settlementAsset() != expectedSettlementAsset) revert InvalidStrategyAdapter();
    }

    function _recordDeposit(address beneficiary, euint64 amount) internal returns (ebool accepted) {
        euint64 mintedShares = amount;
        if (_activePositionCount != 0) {
            euint64 totalAssetsBeforeDeposit = _estimatedTotalVaultAssetsBeforeDeposit(amount);
            mintedShares = FHE.div(FHE.mul(amount, _totalConfidentialShares), totalAssetsBeforeDeposit);
        }

        (ebool userOk, euint64 updatedUserShares) = FHESafeMath.tryIncrease(_confidentialShares[beneficiary], mintedShares);
        (ebool principalOk, euint64 updatedPrincipal) = FHESafeMath.tryIncrease(_principalDepositedByUser[beneficiary], amount);
        (ebool totalOk, euint64 newTotalShares) = FHESafeMath.tryIncrease(_totalConfidentialShares, mintedShares);

        _confidentialShares[beneficiary] = updatedUserShares;
        _principalDepositedByUser[beneficiary] = updatedPrincipal;
        _totalConfidentialShares = newTotalShares;
        _withdrawUnlockAtByUser[beneficiary] = uint64(block.timestamp) + minWithdrawDelay;
        if (!_hasActivePosition[beneficiary]) {
            _activePositionCount += 1;
        }
        _hasActivePosition[beneficiary] = true;

        FHE.allowThis(updatedUserShares);
        FHE.allow(updatedUserShares, beneficiary);
        FHE.allowThis(updatedPrincipal);
        FHE.allow(updatedPrincipal, beneficiary);
        FHE.allowThis(newTotalShares);

        accepted = FHE.and(FHE.and(userOk, principalOk), totalOk);
    }

    function _registerStrategyAdapter(address adapter) internal {
        if (_isRegisteredStrategyAdapter[adapter]) return;
        _isRegisteredStrategyAdapter[adapter] = true;
        _registeredStrategyAdapters.push(adapter);
    }

    function _estimatedTotalVaultAssetsBeforeDeposit(euint64 incomingAmount) internal returns (euint64 totalAssetsBeforeDeposit) {
        totalAssetsBeforeDeposit = _estimatedTotalVaultAssets();
        totalAssetsBeforeDeposit = FHE.sub(totalAssetsBeforeDeposit, incomingAmount);
    }

    function _estimatedTotalVaultAssets() internal returns (euint64 totalAssets) {
        totalAssets = ITezcatliWrappedConfidentialAsset(asset).confidentialBalanceOf(address(this));

        uint256 adaptersLength = _registeredStrategyAdapters.length;
        for (uint256 i = 0; i < adaptersLength; i++) {
            address adapter = _registeredStrategyAdapters[i];
            if (strategySharesByAdapter[adapter] == 0) continue;

            uint256 managedAssets = ITezcatliStrategyAdapter(adapter).totalManagedAssets();
            if (managedAssets > type(uint64).max) revert InvalidAmount();
            totalAssets = FHE.add(totalAssets, FHE.asEuint64(uint64(managedAssets)));
        }
    }

    function _refreshPositionSnapshot(address account) internal {
        euint64 zero = FHE.asEuint64(0);
        euint64 principal = _principalDepositedByUser[account];

        if (!_hasActivePosition[account]) {
            _principalDepositedByUser[account] = principal;
            _grossPositionSnapshotByUser[account] = zero;
            _netPositionSnapshotByUser[account] = zero;
            _pendingYieldSnapshotByUser[account] = zero;
            _pendingFeeSnapshotByUser[account] = zero;
            _positionSnapshotUpdatedAtByUser[account] = uint64(block.timestamp);
            FHE.allowThis(zero);
            FHE.allow(zero, account);
            return;
        }

        euint64 grossAssets = FHE.div(
            FHE.mul(_confidentialShares[account], _estimatedTotalVaultAssets()),
            _totalConfidentialShares
        );
        euint64 pendingYield = _computePendingYield(grossAssets, principal);
        euint64 pendingFee = zero;
        euint64 netAssets = grossAssets;

        if (_hasLockOption[account] && feeModel != address(0)) {
            uint16 feeBps = ITezcatliFeeModel(feeModel).currentFeeBps(
                _lockOptionByUser[account],
                _lockStartByUser[account],
                uint64(block.timestamp)
            );
            pendingFee = _computeYieldFeeCeil(grossAssets, principal, feeBps);
            netAssets = FHE.sub(grossAssets, pendingFee);
        }

        _grossPositionSnapshotByUser[account] = grossAssets;
        _netPositionSnapshotByUser[account] = netAssets;
        _pendingYieldSnapshotByUser[account] = pendingYield;
        _pendingFeeSnapshotByUser[account] = pendingFee;
        _positionSnapshotUpdatedAtByUser[account] = uint64(block.timestamp);

        FHE.allowThis(principal);
        FHE.allow(principal, account);
        FHE.allowThis(grossAssets);
        FHE.allow(grossAssets, account);
        FHE.allowThis(netAssets);
        FHE.allow(netAssets, account);
        FHE.allowThis(pendingYield);
        FHE.allow(pendingYield, account);
        FHE.allowThis(pendingFee);
        FHE.allow(pendingFee, account);
    }

    function _clearPositionSnapshot(address account) internal {
        euint64 zero = FHE.asEuint64(0);
        _grossPositionSnapshotByUser[account] = zero;
        _netPositionSnapshotByUser[account] = zero;
        _pendingYieldSnapshotByUser[account] = zero;
        _pendingFeeSnapshotByUser[account] = zero;
        _positionSnapshotUpdatedAtByUser[account] = uint64(block.timestamp);
        FHE.allowThis(zero);
        FHE.allow(zero, account);
    }

    function _computeYieldFeeCeil(euint64 grossAmount, euint64 principal, uint16 feeBps) internal returns (euint64 feeAmount) {
        euint64 zero = FHE.asEuint64(0);
        ebool hasYield = FHE.gte(grossAmount, principal);
        euint64 yieldAmount = FHE.select(hasYield, FHE.sub(grossAmount, principal), zero);

        euint64 feeRate = FHE.asEuint64(uint64(feeBps));
        euint64 bpsDenominator = FHE.asEuint64(10_000);
        euint64 feeProduct = FHE.mul(yieldAmount, feeRate);
        euint64 feeFloor = FHE.div(feeProduct, bpsDenominator);
        euint64 feeReconstructed = FHE.mul(feeFloor, bpsDenominator);
        ebool hasRemainder = FHE.gt(feeProduct, feeReconstructed);
        euint64 feeCeilDelta = FHE.select(hasRemainder, FHE.asEuint64(1), zero);
        feeAmount = FHE.add(feeFloor, feeCeilDelta);
    }

    function _computePendingYield(euint64 grossAmount, euint64 principal) internal returns (euint64 pendingYield) {
        euint64 zero = FHE.asEuint64(0);
        ebool hasYield = FHE.gte(grossAmount, principal);
        pendingYield = FHE.select(hasYield, FHE.sub(grossAmount, principal), zero);
    }

    function _checkShieldCompliance(address account, bytes32 periodTag, uint256 publicAmount) internal {
        if (!complianceEnabled || complianceGate == address(0)) return;
        (bool allowed, uint8 reasonCode) = ITezcatliVaultComplianceGate(complianceGate).canShield(account, periodTag, publicAmount);
        if (!allowed && reasonCode != 7) revert ComplianceRejected(reasonCode);
        if (reasonCode == 7) {
            emit ComplianceReportRequired(account, periodTag, reasonCode, false);
        }
    }

    function _checkUnshieldCompliance(address account, bytes32 periodTag, uint256 publicAmount) internal {
        if (!complianceEnabled || complianceGate == address(0)) return;
        (bool allowed, uint8 reasonCode) = ITezcatliVaultComplianceGate(complianceGate).canUnshield(account, periodTag, publicAmount);
        if (!allowed && reasonCode != 7) revert ComplianceRejected(reasonCode);
        if (reasonCode == 7) {
            emit ComplianceReportRequired(account, periodTag, reasonCode, true);
        }
    }
}
