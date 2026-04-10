// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./MockAToken.sol";

contract MockAaveV3Pool {
    using SafeERC20 for IERC20;

    address public immutable settlementAsset;
    MockAToken public immutable aToken;

    error InvalidAsset();
    error InvalidAddress();

    constructor(address settlementAsset_, address aToken_) {
        if (settlementAsset_ == address(0) || aToken_ == address(0)) revert InvalidAddress();
        settlementAsset = settlementAsset_;
        aToken = MockAToken(aToken_);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        if (asset != settlementAsset) revert InvalidAsset();
        IERC20(settlementAsset).safeTransferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        if (asset != settlementAsset) revert InvalidAsset();
        if (to == address(0)) revert InvalidAddress();

        uint256 aTokenBalance = aToken.balanceOf(msg.sender);
        uint256 amountToWithdraw = amount == type(uint256).max ? aTokenBalance : amount;
        if (amountToWithdraw > aTokenBalance) amountToWithdraw = aTokenBalance;

        aToken.burn(msg.sender, amountToWithdraw);
        IERC20(settlementAsset).safeTransfer(to, amountToWithdraw);
        return amountToWithdraw;
    }

    function simulateYield(address account, uint256 amount) external {
        aToken.mintYield(account, amount);
        IERC20(settlementAsset).safeTransferFrom(msg.sender, address(this), amount);
    }
}
