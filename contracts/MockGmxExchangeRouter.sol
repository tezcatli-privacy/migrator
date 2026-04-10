// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockGmxExchangeRouter {
    using SafeERC20 for IERC20;

    uint256 public orderCount;
    address public lastOrderAccount;
    bytes32 public lastOrderKey;

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        uint256 length = data.length;
        results = new bytes[](length);

        for (uint256 i = 0; i < length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            if (!success) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            results[i] = result;
        }
    }

    function sendTokens(address token, address receiver, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, receiver, amount);
    }

    function createOrder(bytes32 orderKey) external returns (bytes32) {
        orderCount += 1;
        lastOrderAccount = msg.sender;
        lastOrderKey = orderKey;
        return orderKey;
    }
}
