// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IComplianceHub {
    function canTransfer(address token, address from, address to, uint256 amount) external view returns (bool);
}