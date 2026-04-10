// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";

interface ITezcatliManagedVault {
    function coordinatorDeployToStrategy(uint64 assets, uint256 minSharesOut) external returns (uint256 sharesOut);
    function coordinatorRedeemFromStrategy(uint256 shares, uint64 minAssetsOut) external returns (uint256 assetsOut);
}

contract TezcatliVaultCoordinator is Ownable {
    mapping(address => bool) public operators;
    mapping(address => bool) public approvedVaults;

    event OperatorUpdated(address indexed operator, bool status);
    event VaultApprovalUpdated(address indexed vault, bool approved);
    event StrategyDeployExecuted(address indexed vault, uint64 assets, uint256 minSharesOut, uint256 sharesOut);
    event StrategyRedeemExecuted(address indexed vault, uint256 shares, uint64 minAssetsOut, uint256 assetsOut);

    error Unauthorized();
    error InvalidAddress();
    error VaultNotApproved();

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

    function deployToStrategy(
        address vault,
        uint64 assets,
        uint256 minSharesOut
    ) external onlyOperatorOrOwner returns (uint256 sharesOut) {
        if (!approvedVaults[vault]) revert VaultNotApproved();
        sharesOut = ITezcatliManagedVault(vault).coordinatorDeployToStrategy(assets, minSharesOut);
        emit StrategyDeployExecuted(vault, assets, minSharesOut, sharesOut);
    }

    function redeemFromStrategy(
        address vault,
        uint256 shares,
        uint64 minAssetsOut
    ) external onlyOperatorOrOwner returns (uint256 assetsOut) {
        if (!approvedVaults[vault]) revert VaultNotApproved();
        assetsOut = ITezcatliManagedVault(vault).coordinatorRedeemFromStrategy(shares, minAssetsOut);
        emit StrategyRedeemExecuted(vault, shares, minAssetsOut, assetsOut);
    }
}
