// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FHERC20 } from "fhenix-confidential-contracts/contracts/FHERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TezcatliWrappedToken is FHERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlyingToken;

    event Shielded(address indexed sender, address indexed recipient, uint64 amount);
    event Unshielded(address indexed account, uint64 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        address underlyingToken_,
        uint8 decimals_
    ) FHERC20(name_, symbol_, decimals_) {
        require(underlyingToken_ != address(0), "TezcatliWrappedToken: invalid underlying");
        underlyingToken = IERC20(underlyingToken_);
    }

    function shield(uint64 amount) external {
        shieldTo(msg.sender, amount);
    }

    function shieldTo(address recipient, uint64 amount) public {
        require(recipient != address(0), "TezcatliWrappedToken: invalid recipient");
        require(amount > 0, "TezcatliWrappedToken: zero amount");

        underlyingToken.safeTransferFrom(msg.sender, address(this), uint256(amount));
        _mint(recipient, amount);

        emit Shielded(msg.sender, recipient, amount);
    }

    function unshield(uint64 amount) external {
        require(amount > 0, "TezcatliWrappedToken: zero amount");

        _burn(msg.sender, amount);
        underlyingToken.safeTransfer(msg.sender, uint256(amount));

        emit Unshielded(msg.sender, amount);
    }
}
