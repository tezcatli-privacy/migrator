// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TezcatliDustSwap is Ownable {
    using SafeERC20 for IERC20;

    struct RateConfig {
        uint256 numerator;
        uint256 denominator;
        bool enabled;
    }

    IERC20 public immutable settlementToken;

    mapping(address => RateConfig) public rates;

    event RateConfigured(
        address indexed tokenIn,
        uint256 numerator,
        uint256 denominator,
        bool enabled
    );
    event SettlementFunded(uint256 amount);
    event Swapped(
        address indexed tokenIn,
        address indexed sender,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address settlementToken_, address initialOwner) Ownable(initialOwner) {
        require(settlementToken_ != address(0), "Invalid settlement token");
        settlementToken = IERC20(settlementToken_);
    }

    function setRate(
        address tokenIn,
        uint256 numerator,
        uint256 denominator,
        bool enabled
    ) external onlyOwner {
        require(tokenIn != address(0), "Invalid token");
        require(denominator > 0, "Invalid denominator");

        rates[tokenIn] = RateConfig({
            numerator: numerator,
            denominator: denominator,
            enabled: enabled
        });

        emit RateConfigured(tokenIn, numerator, denominator, enabled);
    }

    function fundSettlement(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");

        settlementToken.safeTransferFrom(msg.sender, address(this), amount);
        emit SettlementFunded(amount);
    }

    function quote(address tokenIn, uint256 amountIn) public view returns (uint256 amountOut) {
        RateConfig memory config = rates[tokenIn];

        require(config.enabled, "Unsupported token");
        return amountIn * config.numerator / config.denominator;
    }

    function swapToSettlement(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut) {
        require(tokenIn != address(0), "Invalid token");
        require(recipient != address(0), "Invalid recipient");
        require(amountIn > 0, "Zero amount");

        amountOut = quote(tokenIn, amountIn);
        require(amountOut >= minAmountOut, "Insufficient output");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        settlementToken.safeTransfer(recipient, amountOut);

        emit Swapped(tokenIn, msg.sender, recipient, amountIn, amountOut);
    }
}
