// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FHE, ebool, euint64, InEuint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";
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

contract TezcatliConfidentialVault is IFHERC20Receiver, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable asset;
    address public coordinator;
    address public strategyAdapter;
    address public feeModel;
    address public feeRecipient;
    uint64 public minWithdrawDelay;
    uint256 public strategyShares;

    mapping(address => euint64) private _confidentialShares;
    euint64 private _totalConfidentialShares;
    mapping(address => uint8) private _lockOptionByUser;
    mapping(address => uint64) private _lockStartByUser;
    mapping(address => uint64) private _withdrawUnlockAtByUser;
    mapping(address => bool) private _hasLockOption;

    event DepositRecorded(address indexed sender, address indexed beneficiary, euint64 amount);
    event WithdrawalExecuted(address indexed owner, address indexed recipient, euint64 amount);
    event CoordinatorUpdated(address indexed previousCoordinator, address indexed newCoordinator);
    event StrategyAdapterUpdated(address indexed previousAdapter, address indexed newAdapter);
    event FeeModelUpdated(address indexed previousFeeModel, address indexed newFeeModel);
    event FeeRecipientUpdated(address indexed previousFeeRecipient, address indexed newFeeRecipient);
    event MinWithdrawDelayUpdated(uint64 previousDelay, uint64 newDelay);
    event UserLockOptionConfigured(address indexed user, uint8 lockOption, uint64 startTimestamp);
    event YieldFeeCharged(address indexed user, address indexed feeRecipient, euint64 feeAmount, uint16 feeBps);
    event StrategyDeployed(uint64 assets, uint256 sharesOut);
    event StrategyRedeemed(uint256 sharesIn, uint256 assetsOut);
    event EmergencyTokenRecovered(address indexed token, address indexed to, uint256 amount);

    error InvalidAsset();
    error InvalidBeneficiary();
    error InvalidRecipient();
    error UnauthorizedAsset();
    error UnauthorizedCoordinator();
    error AssetRecoveryDisabled();
    error InvalidRecoveryAddress();
    error InvalidStrategyAdapter();
    error StrategyNotConfigured();
    error InvalidFeeModel();
    error InvalidFeeRecipient();
    error InvalidLockOption();
    error WithdrawLocked(uint64 unlockAt);
    error StrategyPositionOpen();
    error InvalidAmount();

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

        (ebool userOk, euint64 newUserShares) = FHESafeMath.tryIncrease(_confidentialShares[beneficiary], amount);
        (ebool totalOk, euint64 newTotalShares) = FHESafeMath.tryIncrease(_totalConfidentialShares, amount);

        _confidentialShares[beneficiary] = newUserShares;
        _totalConfidentialShares = newTotalShares;
        _withdrawUnlockAtByUser[beneficiary] = uint64(block.timestamp) + minWithdrawDelay;

        FHE.allowThis(newUserShares);
        FHE.allow(newUserShares, beneficiary);
        FHE.allowThis(newTotalShares);

        if (lockOptionProvided) {
            if (feeModel == address(0)) revert InvalidFeeModel();
            if (!ITezcatliFeeModel(feeModel).isValidLockOption(lockOption)) revert InvalidLockOption();

            _lockOptionByUser[beneficiary] = lockOption;
            _lockStartByUser[beneficiary] = uint64(block.timestamp);
            _hasLockOption[beneficiary] = true;
            emit UserLockOptionConfigured(beneficiary, lockOption, uint64(block.timestamp));
        }

        emit DepositRecorded(from, beneficiary, amount);
        ebool accepted = FHE.and(userOk, totalOk);
        FHE.allow(accepted, msg.sender);
        return accepted;
    }

    function withdrawConfidential(
        InEuint64 calldata encryptedShares,
        address recipient
    ) external nonReentrant whenNotPaused returns (euint64 transferred) {
        if (recipient == address(0)) revert InvalidRecipient();

        uint64 unlockAt = _withdrawUnlockAtByUser[msg.sender];
        if (unlockAt > 0 && block.timestamp < unlockAt) revert WithdrawLocked(unlockAt);

        euint64 requested = FHE.asEuint64(encryptedShares);
        euint64 userShares = _confidentialShares[msg.sender];
        ebool userHasEnough = FHE.gte(userShares, requested);
        euint64 cappedRequest = FHE.select(userHasEnough, requested, userShares);
        euint64 zero = FHE.asEuint64(0);
        euint64 payoutAmount = cappedRequest;
        euint64 feeAmount = zero;
        uint16 feeBps = 0;

        if (_hasLockOption[msg.sender] && feeModel != address(0)) {
            if (strategyShares != 0) revert StrategyPositionOpen();

            euint64 totalShares = _totalConfidentialShares;
            euint64 vaultAssets = ITezcatliWrappedConfidentialAsset(asset).confidentialBalanceOf(address(this));
            euint64 grossAmount = FHE.div(FHE.mul(cappedRequest, vaultAssets), totalShares);

            ebool hasYield = FHE.gte(grossAmount, cappedRequest);
            euint64 yieldAmount = FHE.select(hasYield, FHE.sub(grossAmount, cappedRequest), zero);

            feeBps = ITezcatliFeeModel(feeModel).currentFeeBps(
                _lockOptionByUser[msg.sender],
                _lockStartByUser[msg.sender],
                uint64(block.timestamp)
            );

            euint64 feeRate = FHE.asEuint64(uint64(feeBps));
            euint64 bpsDenominator = FHE.asEuint64(10_000);
            feeAmount = FHE.div(FHE.mul(yieldAmount, feeRate), bpsDenominator);
            payoutAmount = FHE.sub(grossAmount, feeAmount);
        }

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

        euint64 newUserShares;
        euint64 newTotalShares;
        (, newUserShares) = FHESafeMath.tryDecrease(userShares, cappedRequest);
        (, newTotalShares) = FHESafeMath.tryDecrease(_totalConfidentialShares, cappedRequest);

        _confidentialShares[msg.sender] = newUserShares;
        _totalConfidentialShares = newTotalShares;
        FHE.allowThis(newUserShares);
        FHE.allow(newUserShares, msg.sender);
        FHE.allowThis(newTotalShares);
        FHE.allow(transferred, msg.sender);
        emit WithdrawalExecuted(msg.sender, recipient, transferred);
    }

    function setCoordinator(address newCoordinator) external onlyOwner {
        address previousCoordinator = coordinator;
        coordinator = newCoordinator;
        emit CoordinatorUpdated(previousCoordinator, newCoordinator);
    }

    function setStrategyAdapter(address newStrategyAdapter) external onlyOwner {
        if (newStrategyAdapter != address(0)) {
            ITezcatliStrategyAdapter adapter = ITezcatliStrategyAdapter(newStrategyAdapter);
            if (adapter.vault() != address(this)) revert InvalidStrategyAdapter();

            address expectedSettlementAsset = ITezcatliWrappedConfidentialAsset(asset).underlyingToken();
            if (adapter.settlementAsset() != expectedSettlementAsset) revert InvalidStrategyAdapter();
        }

        address previousAdapter = strategyAdapter;
        strategyAdapter = newStrategyAdapter;
        emit StrategyAdapterUpdated(previousAdapter, newStrategyAdapter);
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

    function coordinatorDeployToStrategy(
        uint64 assets,
        uint256 minSharesOut
    ) external onlyCoordinator nonReentrant whenNotPaused returns (uint256 sharesOut) {
        if (strategyAdapter == address(0)) revert StrategyNotConfigured();
        if (assets == 0) revert InvalidAmount();

        ITezcatliWrappedConfidentialAsset wrappedAsset = ITezcatliWrappedConfidentialAsset(asset);
        wrappedAsset.unshield(assets);

        IERC20 settlementAsset = IERC20(wrappedAsset.underlyingToken());
        settlementAsset.forceApprove(strategyAdapter, uint256(assets));

        sharesOut = ITezcatliStrategyAdapter(strategyAdapter).deploy(uint256(assets), minSharesOut);
        strategyShares += sharesOut;

        emit StrategyDeployed(assets, sharesOut);
    }

    function coordinatorRedeemFromStrategy(
        uint256 shares,
        uint64 minAssetsOut
    ) external onlyCoordinator nonReentrant whenNotPaused returns (uint256 assetsOut) {
        if (strategyAdapter == address(0)) revert StrategyNotConfigured();
        if (shares == 0 || shares > strategyShares) revert InvalidAmount();

        assetsOut = ITezcatliStrategyAdapter(strategyAdapter).redeem(shares, uint256(minAssetsOut), address(this));
        if (assetsOut > type(uint64).max) revert InvalidAmount();

        ITezcatliWrappedConfidentialAsset wrappedAsset = ITezcatliWrappedConfidentialAsset(asset);
        IERC20 settlementAsset = IERC20(wrappedAsset.underlyingToken());
        settlementAsset.forceApprove(asset, assetsOut);
        wrappedAsset.shieldTo(address(this), uint64(assetsOut));

        strategyShares -= shares;
        emit StrategyRedeemed(shares, assetsOut);
    }

    function confidentialSharesOf(address account) external view returns (euint64) {
        return _confidentialShares[account];
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
}
