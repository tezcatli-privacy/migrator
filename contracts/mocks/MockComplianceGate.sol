// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockComplianceGate {
    bool public allowShield = true;
    uint8 public shieldReasonCode = 0;
    bool public allowUnshield = true;
    uint8 public unshieldReasonCode = 0;

    function setShieldDecision(bool allowed, uint8 reasonCode) external {
        allowShield = allowed;
        shieldReasonCode = reasonCode;
    }

    function setUnshieldDecision(bool allowed, uint8 reasonCode) external {
        allowUnshield = allowed;
        unshieldReasonCode = reasonCode;
    }

    function canShield(address, bytes32, uint256) external view returns (bool, uint8) {
        return (allowShield, shieldReasonCode);
    }

    function canUnshield(address, bytes32, uint256) external view returns (bool, uint8) {
        return (allowUnshield, unshieldReasonCode);
    }
}
