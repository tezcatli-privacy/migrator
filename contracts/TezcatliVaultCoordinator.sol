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
}

interface ITezcatliStrategyAdapterView {
    function vault() external view returns (address);
    function totalManagedAssets() external view returns (uint256);
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

    mapping(address => bool) public operators;
    mapping(address => bool) public approvedVaults;
    mapping(address => mapping(address => StrategyConfig)) public strategyConfigs;
    mapping(address => address[]) private _vaultStrategies;
    mapping(address => mapping(address => bool)) private _isListedStrategy;

    event OperatorUpdated(address indexed operator, bool status);
    event VaultApprovalUpdated(address indexed vault, bool approved);
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

    error Unauthorized();
    error InvalidAddress();
    error InvalidBps();
    error InvalidBucket();
    error VaultNotApproved();
    error StrategyNotEnabled();
    error AllocationExceeded();
    error InvalidStrategyAdapter();

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
        if (!approvedVaults[vault]) revert VaultNotApproved();
        _enforceAllocationCap(vault, strategyAdapter, assets);

        sharesOut = ITezcatliManagedVault(vault).coordinatorDeployToStrategy(strategyAdapter, assets, minSharesOut);
        emit StrategyDeployExecuted(vault, strategyAdapter, assets, minSharesOut, sharesOut);
    }

    function redeemFromStrategyWithAdapter(
        address vault,
        address strategyAdapter,
        uint256 shares,
        uint64 minAssetsOut
    ) external onlyOperatorOrOwner returns (uint256 assetsOut) {
        if (!approvedVaults[vault]) revert VaultNotApproved();
        _requireEnabledStrategy(vault, strategyAdapter);

        assetsOut = ITezcatliManagedVault(vault).coordinatorRedeemFromStrategy(strategyAdapter, shares, minAssetsOut);
        emit StrategyRedeemExecuted(vault, strategyAdapter, shares, minAssetsOut, assetsOut);
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

    function _enforceAllocationCap(address vault, address strategyAdapter, uint64 assets) internal view {
        _requireEnabledStrategy(vault, strategyAdapter);
        StrategyConfig memory config = strategyConfigs[vault][strategyAdapter];
        if (config.maxBps == 0) return;

        uint256 strategyManaged = ITezcatliStrategyAdapterView(strategyAdapter).totalManagedAssets();
        uint256 totalManaged = _totalManagedAssets(vault);
        if (totalManaged == 0) return;

        uint256 postStrategyManaged = strategyManaged + uint256(assets);
        uint256 postTotalManaged = totalManaged + uint256(assets);

        if (postTotalManaged == 0) return;
        if ((postStrategyManaged * BPS_DENOMINATOR) > (postTotalManaged * config.maxBps)) {
            revert AllocationExceeded();
        }
    }

    function _requireEnabledStrategy(address vault, address strategyAdapter) internal view {
        StrategyConfig memory config = strategyConfigs[vault][strategyAdapter];
        if (!config.enabled) revert StrategyNotEnabled();
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
