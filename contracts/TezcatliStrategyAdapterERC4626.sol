// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TezcatliStrategyAdapterERC4626 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable vault;
    address public immutable settlementAsset;
    address public immutable strategyVault;
    uint256 public managedShares;

    event DeployedToStrategy(uint256 assets, uint256 shares);
    event RedeemedFromStrategy(uint256 shares, uint256 assets);
    event EmergencyTokenRecovered(address indexed token, address indexed to, uint256 amount);

    error UnauthorizedVault();
    error InvalidAddress();
    error InvalidAmount();
    error SlippageExceeded();
    error SettlementAssetRecoveryDisabled();

    modifier onlyVault() {
        if (msg.sender != vault) revert UnauthorizedVault();
        _;
    }

    constructor(
        address vault_,
        address settlementAsset_,
        address strategyVault_,
        address owner_
    ) Ownable(owner_) {
        if (vault_ == address(0) || settlementAsset_ == address(0) || strategyVault_ == address(0)) {
            revert InvalidAddress();
        }

        vault = vault_;
        settlementAsset = settlementAsset_;
        strategyVault = strategyVault_;

        if (ERC4626(strategyVault_).asset() != settlementAsset_) {
            revert InvalidAddress();
        }
    }

    function deploy(uint256 assets, uint256 minSharesOut) external onlyVault nonReentrant returns (uint256 sharesOut) {
        if (assets == 0) revert InvalidAmount();

        IERC20(settlementAsset).safeTransferFrom(msg.sender, address(this), assets);
        IERC20(settlementAsset).forceApprove(strategyVault, assets);

        sharesOut = ERC4626(strategyVault).deposit(assets, address(this));
        if (sharesOut < minSharesOut) revert SlippageExceeded();

        managedShares += sharesOut;
        emit DeployedToStrategy(assets, sharesOut);
    }

    function redeem(
        uint256 shares,
        uint256 minAssetsOut,
        address receiver
    ) external onlyVault nonReentrant returns (uint256 assetsOut) {
        if (shares == 0 || shares > managedShares) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();

        assetsOut = ERC4626(strategyVault).redeem(shares, receiver, address(this));
        if (assetsOut < minAssetsOut) revert SlippageExceeded();

        managedShares -= shares;
        emit RedeemedFromStrategy(shares, assetsOut);
    }

    function totalManagedAssets() external view returns (uint256) {
        if (managedShares == 0) return 0;
        return ERC4626(strategyVault).previewRedeem(managedShares);
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (token == settlementAsset) revert SettlementAssetRecoveryDisabled();

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyTokenRecovered(token, to, amount);
    }
}
