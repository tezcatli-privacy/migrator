// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FHE, ebool, euint64, InEuint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import { FHESafeMath } from "fhenix-confidential-contracts/contracts/utils/FHESafeMath.sol";
import { IFHERC20Receiver } from "fhenix-confidential-contracts/contracts/interfaces/IFHERC20Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITezcatliConfidentialAsset {
    function confidentialTransfer(address to, euint64 amount) external returns (euint64 transferred);
}

contract TezcatliConfidentialVault is IFHERC20Receiver, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable asset;

    mapping(address => euint64) private _confidentialShares;
    euint64 private _totalConfidentialShares;

    event DepositRecorded(address indexed sender, address indexed beneficiary, euint64 amount);
    event WithdrawalExecuted(address indexed owner, address indexed recipient, euint64 amount);
    event EmergencyTokenRecovered(address indexed token, address indexed to, uint256 amount);

    error InvalidAsset();
    error InvalidBeneficiary();
    error InvalidRecipient();
    error UnauthorizedAsset();
    error AssetRecoveryDisabled();
    error InvalidRecoveryAddress();

    constructor(address asset_, address owner_) Ownable(owner_) {
        if (asset_ == address(0)) revert InvalidAsset();
        asset = asset_;
    }

    function onConfidentialTransferReceived(
        address,
        address from,
        euint64 amount,
        bytes calldata data
    ) external whenNotPaused returns (ebool) {
        if (msg.sender != asset) revert UnauthorizedAsset();

        address beneficiary = from;
        if (data.length > 0) {
            if (data.length != 32) revert InvalidBeneficiary();
            beneficiary = abi.decode(data, (address));
        }
        if (beneficiary == address(0)) revert InvalidBeneficiary();

        (ebool userOk, euint64 newUserShares) = FHESafeMath.tryIncrease(_confidentialShares[beneficiary], amount);
        (ebool totalOk, euint64 newTotalShares) = FHESafeMath.tryIncrease(_totalConfidentialShares, amount);

        _confidentialShares[beneficiary] = newUserShares;
        _totalConfidentialShares = newTotalShares;

        FHE.allowThis(newUserShares);
        FHE.allow(newUserShares, beneficiary);
        FHE.allowThis(newTotalShares);

        emit DepositRecorded(from, beneficiary, amount);
        ebool accepted = FHE.and(userOk, totalOk);
        FHE.allow(accepted, msg.sender);
        return accepted;
    }

    function withdrawConfidential(
        InEuint64 calldata encryptedShares,
        address recipient
    ) external nonReentrant whenNotPaused returns (euint64 transferred) {
        if (recipient == address(0)) revert InvalidRecipient();

        euint64 requested = FHE.asEuint64(encryptedShares);
        (ebool userOk, euint64 newUserShares) = FHESafeMath.tryDecrease(_confidentialShares[msg.sender], requested);
        (ebool totalOk, euint64 newTotalShares) = FHESafeMath.tryDecrease(_totalConfidentialShares, requested);

        ebool success = FHE.and(userOk, totalOk);
        euint64 payout = FHE.select(success, requested, FHE.asEuint64(0));

        _confidentialShares[msg.sender] = newUserShares;
        _totalConfidentialShares = newTotalShares;

        FHE.allowThis(newUserShares);
        FHE.allow(newUserShares, msg.sender);
        FHE.allowThis(newTotalShares);
        FHE.allowThis(payout);
        FHE.allow(payout, msg.sender);
        FHE.allow(payout, asset);

        transferred = ITezcatliConfidentialAsset(asset).confidentialTransfer(recipient, payout);
        emit WithdrawalExecuted(msg.sender, recipient, transferred);
    }

    function confidentialSharesOf(address account) external view returns (euint64) {
        return _confidentialShares[account];
    }

    function totalConfidentialShares() external view returns (euint64) {
        return _totalConfidentialShares;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecoveryAddress();
        if (token == asset) revert AssetRecoveryDisabled();

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyTokenRecovered(token, to, amount);
    }
}
