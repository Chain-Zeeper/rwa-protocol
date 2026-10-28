// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRule {
    // `token` is the RWA token being transferred: msg.sender is always the
    // hub, so rules that keep per-token state must key it on this.
    function check(address _token, address _from, address _to, uint256 _amount, bytes memory params) external view returns (bool);
    // Account eligibility alone, with no amount or counterparty (ERC-7943
    // canSend / canReceive). A rule with no per-account restriction returns true.
    function canSend(address _token, address _account, bytes memory params) external view returns (bool);
    function canReceive(address _token, address _account, bytes memory params) external view returns (bool);
    function name() external view returns (string memory);
    function ruleReference() external view returns (string memory);
}
