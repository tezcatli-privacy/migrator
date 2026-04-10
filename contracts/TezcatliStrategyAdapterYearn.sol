// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TezcatliStrategyAdapterYearn is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable vault;
    address public immutable settlementAsset;
    address public immutable yearnVault;
    uint256 public managedShares;

    event DeployedToYearn(uint256 assets, uint256 shares);
    event RedeemedFromYearn(uint256 shares, uint256 assets);
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
        address yearnVault_,
        address owner_
    ) Ownable(owner_) {
        if (vault_ == address(0) || settlementAsset_ == address(0) || yearnVault_ == address(0)) {
            revert InvalidAddress();
        }

        vault = vault_;
        settlementAsset = settlementAsset_;
        yearnVault = yearnVault_;

        if (ERC4626(yearnVault_).asset() != settlementAsset_) {
            revert InvalidAddress();
        }
    }

    function deploy(uint256 assets, uint256 minSharesOut) external onlyVault nonReentrant returns (uint256 sharesOut) {
        if (assets == 0) revert InvalidAmount();

        IERC20(settlementAsset).safeTransferFrom(msg.sender, address(this), assets);
        IERC20(settlementAsset).forceApprove(yearnVault, assets);

        sharesOut = ERC4626(yearnVault).deposit(assets, address(this));
        if (sharesOut < minSharesOut) revert SlippageExceeded();

        managedShares += sharesOut;
        emit DeployedToYearn(assets, sharesOut);
    }

    function redeem(
        uint256 shares,
        uint256 minAssetsOut,
        address receiver
    ) external onlyVault nonReentrant returns (uint256 assetsOut) {
        if (shares == 0 || shares > managedShares) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();

        assetsOut = ERC4626(yearnVault).redeem(shares, receiver, address(this));
        if (assetsOut < minAssetsOut) revert SlippageExceeded();

        managedShares -= shares;
        emit RedeemedFromYearn(shares, assetsOut);
    }

    function totalManagedAssets() external view returns (uint256) {
        if (managedShares == 0) return 0;
        return ERC4626(yearnVault).previewRedeem(managedShares);
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (token == settlementAsset) revert SettlementAssetRecoveryDisabled();

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyTokenRecovered(token, to, amount);
    }
}
