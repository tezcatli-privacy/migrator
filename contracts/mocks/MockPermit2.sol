// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockPermit2 {
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitBatch {
        PermitDetails[] details;
        address spender;
        uint256 sigDeadline;
    }

    struct AllowanceTransferDetails {
        address from;
        address to;
        uint160 amount;
        address token;
    }

    struct AllowanceData {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    mapping(address => mapping(address => mapping(address => AllowanceData))) private _allowances;

    function allowance(
        address owner,
        address token,
        address spender
    ) external view returns (uint160 amount, uint48 expiration, uint48 nonce) {
        AllowanceData memory stored = _allowances[owner][token][spender];
        return (stored.amount, stored.expiration, stored.nonce);
    }

    function permit(address owner, PermitBatch calldata permitBatch, bytes calldata) external {
        require(permitBatch.spender != address(0), "invalid spender");
        require(block.timestamp <= permitBatch.sigDeadline, "signature expired");

        for (uint256 i = 0; i < permitBatch.details.length; i++) {
            PermitDetails calldata detail = permitBatch.details[i];
            _allowances[owner][detail.token][permitBatch.spender] = AllowanceData({
                amount: detail.amount,
                expiration: detail.expiration,
                nonce: detail.nonce + 1
            });
        }
    }

    function transferFrom(AllowanceTransferDetails[] calldata transferDetails) external {
        for (uint256 i = 0; i < transferDetails.length; i++) {
            AllowanceTransferDetails calldata detail = transferDetails[i];
            AllowanceData memory stored = _allowances[detail.from][detail.token][msg.sender];

            require(stored.expiration == 0 || block.timestamp <= stored.expiration, "allowance expired");
            require(stored.amount >= detail.amount, "allowance too low");

            _allowances[detail.from][detail.token][msg.sender].amount = stored.amount - detail.amount;
            IERC20(detail.token).transferFrom(detail.from, detail.to, detail.amount);
        }
    }
}
