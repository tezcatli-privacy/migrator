// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";

contract TezcatliStrategyRiskPolicy is Ownable {
    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct PolicyConfig {
        bool enabled;
        uint16 maxAllocationBps;
        uint16 maxSlippageBps;
        uint64 maxPendingTime;
        uint16 maxLeverageBps;
        bool enforceLeverage;
    }

    mapping(address => mapping(address => PolicyConfig)) public policyOf;

    event PolicyConfigured(
        address indexed vault,
        address indexed strategyAdapter,
        bool enabled,
        uint16 maxAllocationBps,
        uint16 maxSlippageBps,
        uint64 maxPendingTime,
        uint16 maxLeverageBps,
        bool enforceLeverage
    );

    error InvalidAddress();
    error InvalidBps();
    error PolicyNotEnabled();
    error AllocationExceeded();
    error InvalidQuote();
    error SlippageExceeded();
    error PendingTimeExceeded();
    error LeverageExceeded();

    constructor(address owner_) Ownable(owner_) {}

    function setPolicy(
        address vault,
        address strategyAdapter,
        bool enabled,
        uint16 maxAllocationBps,
        uint16 maxSlippageBps,
        uint64 maxPendingTime,
        uint16 maxLeverageBps,
        bool enforceLeverage
    ) external onlyOwner {
        if (vault == address(0) || strategyAdapter == address(0)) revert InvalidAddress();
        if (maxAllocationBps > BPS_DENOMINATOR || maxSlippageBps > BPS_DENOMINATOR) revert InvalidBps();
        if (enforceLeverage && maxLeverageBps == 0) revert InvalidBps();

        policyOf[vault][strategyAdapter] = PolicyConfig({
            enabled: enabled,
            maxAllocationBps: maxAllocationBps,
            maxSlippageBps: maxSlippageBps,
            maxPendingTime: maxPendingTime,
            maxLeverageBps: maxLeverageBps,
            enforceLeverage: enforceLeverage
        });

        emit PolicyConfigured(
            vault,
            strategyAdapter,
            enabled,
            maxAllocationBps,
            maxSlippageBps,
            maxPendingTime,
            maxLeverageBps,
            enforceLeverage
        );
    }

    function requireDeployPolicy(
        address vault,
        address strategyAdapter,
        uint256 postStrategyManaged,
        uint256 postTotalManaged,
        uint256 quoteSharesOut,
        uint256 minSharesOut,
        uint16 requestedLeverageBps
    ) external view {
        PolicyConfig memory policy = policyOf[vault][strategyAdapter];
        if (!policy.enabled) revert PolicyNotEnabled();

        _enforceAllocation(policy, postStrategyManaged, postTotalManaged);
        _enforceSlippage(policy.maxSlippageBps, quoteSharesOut, minSharesOut);
        _enforceLeverage(policy, requestedLeverageBps);
    }

    function requireRedeemPolicy(
        address vault,
        address strategyAdapter,
        uint256 quoteAssetsOut,
        uint256 minAssetsOut,
        uint16 requestedLeverageBps
    ) external view {
        PolicyConfig memory policy = policyOf[vault][strategyAdapter];
        if (!policy.enabled) revert PolicyNotEnabled();

        _enforceSlippage(policy.maxSlippageBps, quoteAssetsOut, minAssetsOut);
        _enforceLeverage(policy, requestedLeverageBps);
    }

    function requirePendingWithinLimit(
        address vault,
        address strategyAdapter,
        uint64 pendingSeconds
    ) external view {
        PolicyConfig memory policy = policyOf[vault][strategyAdapter];
        if (!policy.enabled) revert PolicyNotEnabled();
        if (policy.maxPendingTime > 0 && pendingSeconds > policy.maxPendingTime) {
            revert PendingTimeExceeded();
        }
    }

    function maxPendingTimeOf(address vault, address strategyAdapter) external view returns (uint64) {
        return policyOf[vault][strategyAdapter].maxPendingTime;
    }

    function _enforceAllocation(
        PolicyConfig memory policy,
        uint256 postStrategyManaged,
        uint256 postTotalManaged
    ) internal pure {
        if (policy.maxAllocationBps == 0 || postTotalManaged == 0) return;
        if ((postStrategyManaged * BPS_DENOMINATOR) > (postTotalManaged * policy.maxAllocationBps)) {
            revert AllocationExceeded();
        }
    }

    function _enforceSlippage(uint16 maxSlippageBps, uint256 quoteOut, uint256 minOut) internal pure {
        if (maxSlippageBps == 0) return;
        if (quoteOut == 0 || minOut > quoteOut) revert InvalidQuote();

        uint256 slippageBps = ((quoteOut - minOut) * BPS_DENOMINATOR) / quoteOut;
        if (slippageBps > maxSlippageBps) revert SlippageExceeded();
    }

    function _enforceLeverage(PolicyConfig memory policy, uint16 requestedLeverageBps) internal pure {
        if (!policy.enforceLeverage) return;
        if (requestedLeverageBps > policy.maxLeverageBps) revert LeverageExceeded();
    }
}
