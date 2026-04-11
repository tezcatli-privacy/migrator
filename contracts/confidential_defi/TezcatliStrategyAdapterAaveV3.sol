// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAaveV3PoolLike {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract TezcatliStrategyAdapterAaveV3 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable vault;
    address public immutable settlementAsset;
    address public immutable pool;
    address public immutable aToken;

    uint256 public managedShares;

    event DeployedToAave(uint256 assets, uint256 shares);
    event RedeemedFromAave(uint256 shares, uint256 assets);
    event EmergencyTokenRecovered(address indexed token, address indexed to, uint256 amount);

    error UnauthorizedVault();
    error InvalidAddress();
    error InvalidAmount();
    error SlippageExceeded();
    error SettlementAssetRecoveryDisabled();
    error ATokenRecoveryDisabled();

    modifier onlyVault() {
        if (msg.sender != vault) revert UnauthorizedVault();
        _;
    }

    constructor(
        address vault_,
        address settlementAsset_,
        address pool_,
        address aToken_,
        address owner_
    ) Ownable(owner_) {
        if (
            vault_ == address(0) ||
            settlementAsset_ == address(0) ||
            pool_ == address(0) ||
            aToken_ == address(0)
        ) revert InvalidAddress();

        vault = vault_;
        settlementAsset = settlementAsset_;
        pool = pool_;
        aToken = aToken_;
    }

    function deploy(uint256 assets, uint256 minSharesOut) external onlyVault nonReentrant returns (uint256 sharesOut) {
        if (assets == 0) revert InvalidAmount();

        IERC20 settlementToken = IERC20(settlementAsset);
        settlementToken.safeTransferFrom(msg.sender, address(this), assets);
        settlementToken.forceApprove(pool, assets);

        uint256 beforeBalance = IERC20(aToken).balanceOf(address(this));
        IAaveV3PoolLike(pool).supply(settlementAsset, assets, address(this), 0);
        uint256 afterBalance = IERC20(aToken).balanceOf(address(this));
        sharesOut = afterBalance - beforeBalance;
        if (sharesOut < minSharesOut) revert SlippageExceeded();

        managedShares += sharesOut;
        emit DeployedToAave(assets, sharesOut);
    }

    function redeem(
        uint256 shares,
        uint256 minAssetsOut,
        address receiver
    ) external onlyVault nonReentrant returns (uint256 assetsOut) {
        if (shares == 0 || shares > managedShares) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();

        uint256 totalATokens = IERC20(aToken).balanceOf(address(this));
        uint256 proportionalAssets = (totalATokens * shares) / managedShares;
        if (proportionalAssets == 0) revert InvalidAmount();

        assetsOut = IAaveV3PoolLike(pool).withdraw(settlementAsset, proportionalAssets, receiver);
        if (assetsOut < minAssetsOut) revert SlippageExceeded();

        managedShares -= shares;
        emit RedeemedFromAave(shares, assetsOut);
    }

    function totalManagedAssets() external view returns (uint256) {
        return IERC20(aToken).balanceOf(address(this));
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (token == settlementAsset) revert SettlementAssetRecoveryDisabled();
        if (token == aToken) revert ATokenRecoveryDisabled();

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyTokenRecovered(token, to, amount);
    }
}
