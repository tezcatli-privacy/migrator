// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockTarget {
    uint256 public counter;
    uint256 public lastValue;

    event Ping(uint256 indexed counter, uint256 value);

    function ping(uint256 value) external {
        counter += 1;
        lastValue = value;
        emit Ping(counter, value);
    }
}
