// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockYieldVault is ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset_) ERC20("Mock Yield Vault", "myvUSDC") ERC4626(asset_) {}

    function donate(uint256 amount) external {
        require(amount > 0, "Zero amount");
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }
}
