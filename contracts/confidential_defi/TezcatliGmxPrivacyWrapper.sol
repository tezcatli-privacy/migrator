// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface ITezcatliGmxExchangeRouter {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}

contract TezcatliGmxPrivacyWrapper is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    struct RelayOrderAuthorization {
        address stealthAddress;
        address gmxRouter;
        address collateralToken;
        uint256 collateralAmount;
        uint256 collateralUsd;
        uint256 sizeUsd;
        uint256 nonce;
        uint256 deadline;
        bytes32 multicallHash;
    }

    uint16 public constant TARGET_LEVERAGE_BPS = 20_000; // 2.0x

    mapping(address => uint256) public nonces;
    mapping(address => bool) public approvedRouters;
    mapping(address => bool) public approvedCollateralTokens;

    event RouterApprovalUpdated(address indexed router, bool approved);
    event CollateralTokenApprovalUpdated(address indexed token, bool approved);
    event OrderRelayed(
        address indexed stealthAddress,
        address indexed gmxRouter,
        address indexed collateralToken,
        uint256 collateralAmount,
        bytes32 multicallHash
    );

    error InvalidAddress();
    error InvalidAmount();
    error EmptyMulticall();
    error AuthorizationExpired();
    error InvalidNonce();
    error InvalidSignature();
    error RouterNotApproved();
    error CollateralTokenNotApproved();
    error InvalidMulticallHash();
    error InvalidLeverage();

    constructor(address owner_) Ownable(owner_) {}

    function setApprovedRouter(address router, bool approved) external onlyOwner {
        if (router == address(0)) revert InvalidAddress();
        approvedRouters[router] = approved;
        emit RouterApprovalUpdated(router, approved);
    }

    function setApprovedCollateralToken(address token, bool approved) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        approvedCollateralTokens[token] = approved;
        emit CollateralTokenApprovalUpdated(token, approved);
    }

    function getRelayDigest(
        RelayOrderAuthorization calldata authorization
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                authorization.stealthAddress,
                authorization.gmxRouter,
                authorization.collateralToken,
                authorization.collateralAmount,
                authorization.collateralUsd,
                authorization.sizeUsd,
                authorization.nonce,
                authorization.deadline,
                authorization.multicallHash
            )
        );
    }

    function relayCreateOrder(
        RelayOrderAuthorization calldata authorization,
        bytes calldata signature,
        bytes[] calldata multicallData,
        address refundReceiver
    ) external payable nonReentrant {
        if (multicallData.length == 0) revert EmptyMulticall();
        bytes32 computedMulticallHash = keccak256(abi.encode(multicallData));
        _validateAuthorization(authorization, computedMulticallHash, signature);

        IERC20 collateralToken = IERC20(authorization.collateralToken);
        uint256 collateralBefore = collateralToken.balanceOf(address(this));

        collateralToken.safeTransferFrom(
            authorization.stealthAddress,
            address(this),
            authorization.collateralAmount
        );

        collateralToken.forceApprove(authorization.gmxRouter, authorization.collateralAmount);
        ITezcatliGmxExchangeRouter(authorization.gmxRouter).multicall{ value: msg.value }(multicallData);
        collateralToken.forceApprove(authorization.gmxRouter, 0);

        uint256 collateralAfter = collateralToken.balanceOf(address(this));
        if (collateralAfter > collateralBefore) {
            address receiver = refundReceiver == address(0) ? authorization.stealthAddress : refundReceiver;
            collateralToken.safeTransfer(receiver, collateralAfter - collateralBefore);
        }

        emit OrderRelayed(
            authorization.stealthAddress,
            authorization.gmxRouter,
            authorization.collateralToken,
            authorization.collateralAmount,
            authorization.multicallHash
        );
    }

    function _validateAuthorization(
        RelayOrderAuthorization calldata authorization,
        bytes32 computedMulticallHash,
        bytes calldata signature
    ) internal {
        if (authorization.stealthAddress == address(0)) revert InvalidAddress();
        if (authorization.gmxRouter == address(0) || authorization.collateralToken == address(0)) revert InvalidAddress();
        if (authorization.collateralAmount == 0) revert InvalidAmount();
        if (authorization.collateralUsd == 0 || authorization.sizeUsd == 0) revert InvalidAmount();
        if (authorization.sizeUsd != authorization.collateralUsd * 2) revert InvalidLeverage();
        if (block.timestamp > authorization.deadline) revert AuthorizationExpired();
        if (!approvedRouters[authorization.gmxRouter]) revert RouterNotApproved();
        if (!approvedCollateralTokens[authorization.collateralToken]) revert CollateralTokenNotApproved();
        if (authorization.nonce != nonces[authorization.stealthAddress]) revert InvalidNonce();
        if (authorization.multicallHash != computedMulticallHash) revert InvalidMulticallHash();

        bytes32 digest = getRelayDigest(authorization).toEthSignedMessageHash();
        if (digest.recover(signature) != authorization.stealthAddress) revert InvalidSignature();

        nonces[authorization.stealthAddress] += 1;
    }
}
