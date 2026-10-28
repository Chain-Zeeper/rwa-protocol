// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRule} from "../IRule.sol";

contract MaxTransferable is IRule {

    function check(address _token, address _from, address _to, uint256 _amount, bytes memory params) external pure returns (bool) {
        uint256 maxAmount = abi.decode(params, (uint256));
        return _amount <= maxAmount;
    }
    // Caps amounts only; no account is ineligible.
    function canSend(address, address, bytes memory) external pure returns (bool) {
        return true;
    }
    function canReceive(address, address, bytes memory) external pure returns (bool) {
        return true;
    }
    function name() external pure returns (string memory) {
        return "MaxTransferable";
    }
    function ruleReference() external pure returns (string memory) {
        return "MaxTransferable";
    }
}
