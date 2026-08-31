// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.13;

interface IVotingStrategy{
    function name() external view returns (string memory);
    function getVotes(uint256 proposal, address voter) external view returns (uint256);
    function getVotingPower(address voter) external view returns (uint256);
    function getExecuteThreshold() external view returns (uint256);
    function totalVotes(uint256 proposal) external view returns (uint256);
    function quorumBps(bytes32 config)external pure returns(uint16);
    function thresholdBps(bytes32 config) external pure returns(uint16);
    // keep only as byte args for now may be diff
     // default returns false
    function canPropose(address proposer,bytes32 config) external pure returns(bool);
}