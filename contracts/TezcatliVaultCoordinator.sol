// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";

interface ITezcatliManagedVault {
    function coordinatorDeployToStrategy(
        address strategyAdapter,
        uint64 assets,
        uint256 minSharesOut
    ) external returns (uint256 sharesOut);
    function coordinatorRedeemFromStrategy(
        address strategyAdapter,
        uint256 shares,
        uint64 minAssetsOut
    ) external returns (uint256 assetsOut);
    function setSettlementPending(bool status) external;
}

interface ITezcatliStrategyAdapterView {
    function vault() external view returns (address);
    function totalManagedAssets() external view returns (uint256);
}

interface ITezcatliStrategyRiskPolicy {
    function requireDeployPolicy(
        address vault,
        address strategyAdapter,
        uint256 postStrategyManaged,
        uint256 postTotalManaged,
        uint256 quoteSharesOut,
        uint256 minSharesOut,
        uint16 requestedLeverageBps
    ) external view;

    function requireRedeemPolicy(
        address vault,
        address strategyAdapter,
        uint256 quoteAssetsOut,
        uint256 minAssetsOut,
        uint16 requestedLeverageBps
    ) external view;

    function requirePendingWithinLimit(
        address vault,
        address strategyAdapter,
        uint64 pendingSeconds
    ) external view;

    function maxPendingTimeOf(address vault, address strategyAdapter) external view returns (uint64);
}

contract TezcatliVaultCoordinator is Ownable {
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint8 public constant RISK_BUCKET_LOW = 0;
    uint8 public constant RISK_BUCKET_MEDIUM = 1;
    uint8 public constant RISK_BUCKET_HIGH = 2;

    struct StrategyConfig {
        bool enabled;
        uint8 riskBucket;
        uint16 targetBps;
        uint16 maxBps;
    }

    struct PendingSettlement {
        bool active;
        uint64 startedAt;
        uint64 maxPendingTime;
    }

    mapping(address => bool) public operators;
    mapping(address => bool) public approvedVaults;
    mapping(address => mapping(address => StrategyConfig)) public strategyConfigs;
    mapping(address => mapping(address => PendingSettlement)) public pendingSettlements;
    mapping(address => uint256) public pendingSettlementCountByVault;
    mapping(address => address[]) private _vaultStrategies;
    mapping(address => mapping(address => bool)) private _isListedStrategy;
    address public riskPolicy;

    event OperatorUpdated(address indexed operator, bool status);
    event VaultApprovalUpdated(address indexed vault, bool approved);
    event RiskPolicyUpdated(address indexed previousPolicy, address indexed newPolicy);
    event StrategyConfigUpdated(
        address indexed vault,
        address indexed strategyAdapter,
        uint8 riskBucket,
        uint16 targetBps,
        uint16 maxBps,
        bool enabled
    );
    event StrategyDeployExecuted(
        address indexed vault,
        address indexed strategyAdapter,
        uint64 assets,
        uint256 minSharesOut,
        uint256 sharesOut
    );
    event StrategyRedeemExecuted(
        address indexed vault,
        address indexed strategyAdapter,
        uint256 shares,
        uint64 minAssetsOut,
        uint256 assetsOut
    );
    event SettlementPendingStarted(
        address indexed vault,
        address indexed strategyAdapter,
        uint64 startedAt,
        uint64 maxPendingTime
    );
    event SettlementPendingCleared(address indexed vault, address indexed strategyAdapter);

    error Unauthorized();
    error InvalidAddress();
    error InvalidBps();
    error InvalidBucket();
    error VaultNotApproved();
    error StrategyNotEnabled();
    error AllocationExceeded();
    error InvalidStrategyAdapter();
    error RiskPolicyNotConfigured();
    error SettlementPending();
    error SettlementNotPending();

    modifier onlyOperatorOrOwner() {
        if (msg.sender != owner() && !operators[msg.sender]) revert Unauthorized();
        _;
    }

    constructor(address owner_) Ownable(owner_) {}

    function setOperator(address operator, bool status) external onlyOwner {
        if (operator == address(0)) revert InvalidAddress();
        operators[operator] = status;
        emit OperatorUpdated(operator, status);
    }

    function setApprovedVault(address vault, bool approved) external onlyOwner {
        if (vault == address(0)) revert InvalidAddress();
        approvedVaults[vault] = approved;
        emit VaultApprovalUpdated(vault, approved);
    }

    function setRiskPolicy(address newRiskPolicy) external onlyOwner {
        address previousPolicy = riskPolicy;
        riskPolicy = newRiskPolicy;
        emit RiskPolicyUpdated(previousPolicy, newRiskPolicy);
    }

    function setStrategyConfig(
        address vault,
        address strategyAdapter,
        uint8 riskBucket,
        uint16 targetBps,
        uint16 maxBps,
        bool enabled
    ) external onlyOwner {
        if (!approvedVaults[vault]) revert VaultNotApproved();
        if (strategyAdapter == address(0)) revert InvalidAddress();
        if (riskBucket > RISK_BUCKET_HIGH) revert InvalidBucket();
        if (targetBps > maxBps || maxBps > BPS_DENOMINATOR) revert InvalidBps();
        if (ITezcatliStrategyAdapterView(strategyAdapter).vault() != vault) revert InvalidStrategyAdapter();

        StrategyConfig storage config = strategyConfigs[vault][strategyAdapter];
        config.enabled = enabled;
        config.riskBucket = riskBucket;
        config.targetBps = targetBps;
        config.maxBps = maxBps;

        if (!_isListedStrategy[vault][strategyAdapter]) {
            _isListedStrategy[vault][strategyAdapter] = true;
            _vaultStrategies[vault].push(strategyAdapter);
        }

        emit StrategyConfigUpdated(vault, strategyAdapter, riskBucket, targetBps, maxBps, enabled);
    }

    function deployToStrategyWithAdapter(
        address vault,
        address strategyAdapter,
        uint64 assets,
        uint256 minSharesOut
    ) external onlyOperatorOrOwner returns (uint256 sharesOut) {
        return deployToStrategyWithPolicy(
            vault,
            strategyAdapter,
            assets,
            minSharesOut,
            minSharesOut,
            0
        );
    }

    function deployToStrategyWithPolicy(
        address vault,
        address strategyAdapter,
        uint64 assets,
        uint256 quoteSharesOut,
        uint256 minSharesOut,
        uint16 requestedLeverageBps
    ) public onlyOperatorOrOwner returns (uint256 sharesOut) {
        if (!approvedVaults[vault]) revert VaultNotApproved();
        _requireNoPendingSettlement(vault, strategyAdapter);
        (uint256 postStrategyManaged, uint256 postTotalManaged) = _enforceAllocationCap(vault, strategyAdapter, assets);
        _enforceRiskDeployPolicy(
            vault,
            strategyAdapter,
            postStrategyManaged,
            postTotalManaged,
            quoteSharesOut,
            minSharesOut,
            requestedLeverageBps
        );

        sharesOut = ITezcatliManagedVault(vault).coordinatorDeployToStrategy(strategyAdapter, assets, minSharesOut);
        emit StrategyDeployExecuted(vault, strategyAdapter, assets, minSharesOut, sharesOut);
    }

    function redeemFromStrategyWithAdapter(
        address vault,
        address strategyAdapter,
        uint256 shares,
        uint64 minAssetsOut
    ) external onlyOperatorOrOwner returns (uint256 assetsOut) {
        return redeemFromStrategyWithPolicy(
            vault,
            strategyAdapter,
            shares,
            minAssetsOut,
            minAssetsOut,
            0
        );
    }

    function redeemFromStrategyWithPolicy(
        address vault,
        address strategyAdapter,
        uint256 shares,
        uint256 quoteAssetsOut,
        uint64 minAssetsOut,
        uint16 requestedLeverageBps
    ) public onlyOperatorOrOwner returns (uint256 assetsOut) {
        if (!approvedVaults[vault]) revert VaultNotApproved();
        _requireEnabledStrategy(vault, strategyAdapter);
        _requireNoPendingSettlement(vault, strategyAdapter);
        _enforceRiskRedeemPolicy(
            vault,
            strategyAdapter,
            quoteAssetsOut,
            minAssetsOut,
            requestedLeverageBps
        );

        assetsOut = ITezcatliManagedVault(vault).coordinatorRedeemFromStrategy(strategyAdapter, shares, minAssetsOut);
        emit StrategyRedeemExecuted(vault, strategyAdapter, shares, minAssetsOut, assetsOut);
    }

    function startCriticalSettlement(address vault, address strategyAdapter) external onlyOperatorOrOwner {
        if (!approvedVaults[vault]) revert VaultNotApproved();
        _requireEnabledStrategy(vault, strategyAdapter);
        if (riskPolicy == address(0)) revert RiskPolicyNotConfigured();

        PendingSettlement storage pending = pendingSettlements[vault][strategyAdapter];
        if (pending.active) revert SettlementPending();

        uint64 maxPendingTime = ITezcatliStrategyRiskPolicy(riskPolicy).maxPendingTimeOf(vault, strategyAdapter);
        pending.active = true;
        pending.startedAt = uint64(block.timestamp);
        pending.maxPendingTime = maxPendingTime;

        pendingSettlementCountByVault[vault] += 1;
        ITezcatliManagedVault(vault).setSettlementPending(true);

        emit SettlementPendingStarted(vault, strategyAdapter, pending.startedAt, pending.maxPendingTime);
    }

    function clearCriticalSettlement(address vault, address strategyAdapter) external onlyOperatorOrOwner {
        if (!approvedVaults[vault]) revert VaultNotApproved();
        PendingSettlement storage pending = pendingSettlements[vault][strategyAdapter];
        if (!pending.active) revert SettlementNotPending();

        delete pendingSettlements[vault][strategyAdapter];
        pendingSettlementCountByVault[vault] -= 1;
        if (pendingSettlementCountByVault[vault] == 0) {
            ITezcatliManagedVault(vault).setSettlementPending(false);
        }

        emit SettlementPendingCleared(vault, strategyAdapter);
    }

    function currentAllocationBps(address vault, address strategyAdapter) external view returns (uint16) {
        StrategyConfig memory config = strategyConfigs[vault][strategyAdapter];
        if (!config.enabled) return 0;

        uint256 totalManaged = _totalManagedAssets(vault);
        if (totalManaged == 0) return 0;

        uint256 strategyManaged = ITezcatliStrategyAdapterView(strategyAdapter).totalManagedAssets();
        return uint16((strategyManaged * BPS_DENOMINATOR) / totalManaged);
    }

    function vaultStrategies(address vault) external view returns (address[] memory) {
        return _vaultStrategies[vault];
    }

    function isCriticalSettlementOverdue(address vault, address strategyAdapter) external view returns (bool) {
        PendingSettlement memory pending = pendingSettlements[vault][strategyAdapter];
        if (!pending.active) return false;
        if (pending.maxPendingTime == 0) return false;
        return uint64(block.timestamp) > pending.startedAt + pending.maxPendingTime;
    }

    function _enforceAllocationCap(
        address vault,
        address strategyAdapter,
        uint64 assets
    ) internal view returns (uint256 postStrategyManaged, uint256 postTotalManaged) {
        _requireEnabledStrategy(vault, strategyAdapter);
        StrategyConfig memory config = strategyConfigs[vault][strategyAdapter];

        uint256 strategyManaged = ITezcatliStrategyAdapterView(strategyAdapter).totalManagedAssets();
        uint256 totalManaged = _totalManagedAssets(vault);

        postStrategyManaged = strategyManaged + uint256(assets);
        postTotalManaged = totalManaged + uint256(assets);
        if (totalManaged == 0) return (postStrategyManaged, postTotalManaged);
        if (config.maxBps == 0 || postTotalManaged == 0) return (postStrategyManaged, postTotalManaged);
        if ((postStrategyManaged * BPS_DENOMINATOR) > (postTotalManaged * config.maxBps)) {
            revert AllocationExceeded();
        }
        return (postStrategyManaged, postTotalManaged);
    }

    function _requireEnabledStrategy(address vault, address strategyAdapter) internal view {
        StrategyConfig memory config = strategyConfigs[vault][strategyAdapter];
        if (!config.enabled) revert StrategyNotEnabled();
    }

    function _requireNoPendingSettlement(address vault, address strategyAdapter) internal view {
        if (pendingSettlements[vault][strategyAdapter].active) revert SettlementPending();
    }

    function _enforceRiskDeployPolicy(
        address vault,
        address strategyAdapter,
        uint256 postStrategyManaged,
        uint256 postTotalManaged,
        uint256 quoteSharesOut,
        uint256 minSharesOut,
        uint16 requestedLeverageBps
    ) internal view {
        if (riskPolicy == address(0)) return;
        ITezcatliStrategyRiskPolicy(riskPolicy).requireDeployPolicy(
            vault,
            strategyAdapter,
            postStrategyManaged,
            postTotalManaged,
            quoteSharesOut,
            minSharesOut,
            requestedLeverageBps
        );
    }

    function _enforceRiskRedeemPolicy(
        address vault,
        address strategyAdapter,
        uint256 quoteAssetsOut,
        uint64 minAssetsOut,
        uint16 requestedLeverageBps
    ) internal view {
        if (riskPolicy == address(0)) return;
        ITezcatliStrategyRiskPolicy(riskPolicy).requireRedeemPolicy(
            vault,
            strategyAdapter,
            quoteAssetsOut,
            uint256(minAssetsOut),
            requestedLeverageBps
        );
    }

    function _totalManagedAssets(address vault) internal view returns (uint256 totalManaged) {
        address[] memory strategies = _vaultStrategies[vault];
        uint256 strategiesLength = strategies.length;

        for (uint256 i = 0; i < strategiesLength; i++) {
            address strategyAdapter = strategies[i];
            if (!strategyConfigs[vault][strategyAdapter].enabled) continue;
            totalManaged += ITezcatliStrategyAdapterView(strategyAdapter).totalManagedAssets();
        }
    }
}
