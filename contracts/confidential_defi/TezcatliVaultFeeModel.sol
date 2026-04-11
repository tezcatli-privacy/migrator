// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract TezcatliVaultFeeModel {
    uint16 public constant BASE_FEE_BPS = 500; // 5.00%
    uint16 public constant FLOOR_FEE_BPS = 50; // 0.50%
    uint16 public constant BPS_DENOMINATOR = 10_000;

    uint8 public constant LOCK_3_MONTHS = 0;
    uint8 public constant LOCK_6_MONTHS = 1;
    uint8 public constant LOCK_12_MONTHS = 2;
    uint8 public constant LOCK_18_MONTHS = 3;

    error InvalidLockOption();

    function isValidLockOption(uint8 lockOption) public pure returns (bool) {
        return lockOption <= LOCK_18_MONTHS;
    }

    function lockConfig(uint8 lockOption) public pure returns (uint64 duration, uint16 floorFeeBps) {
        if (lockOption == LOCK_3_MONTHS) return (90 days, FLOOR_FEE_BPS);
        if (lockOption == LOCK_6_MONTHS) return (180 days, FLOOR_FEE_BPS);
        if (lockOption == LOCK_12_MONTHS) return (365 days, FLOOR_FEE_BPS);
        if (lockOption == LOCK_18_MONTHS) return (540 days, FLOOR_FEE_BPS);
        revert InvalidLockOption();
    }

    function currentFeeBps(
        uint8 lockOption,
        uint64 startTimestamp,
        uint64 currentTimestamp
    ) external pure returns (uint16) {
        return _currentFeeBps(lockOption, startTimestamp, currentTimestamp);
    }

    function _currentFeeBps(
        uint8 lockOption,
        uint64 startTimestamp,
        uint64 currentTimestamp
    ) internal pure returns (uint16) {
        if (currentTimestamp <= startTimestamp) return BASE_FEE_BPS;

        (uint64 duration, uint16 floorFeeBps) = lockConfig(lockOption);
        if (floorFeeBps >= BASE_FEE_BPS) return BASE_FEE_BPS;

        uint64 elapsed = currentTimestamp - startTimestamp;
        if (elapsed >= duration) return floorFeeBps;

        uint256 feeDelta = uint256(BASE_FEE_BPS - floorFeeBps);
        uint256 decayed = (feeDelta * uint256(elapsed)) / uint256(duration);
        return uint16(uint256(BASE_FEE_BPS) - decayed);
    }
}
