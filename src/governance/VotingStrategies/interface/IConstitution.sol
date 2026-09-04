// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VotingParameters} from "../../interface/IGoverner.sol";

interface IConstitution{
    function name() external view returns (string memory);
    function getVotes(address governor, uint256 proposal, address voter) external view returns (uint256);
    function getVotingPower(address voter) external view returns (uint256);
    function hasPassed(address governer,uint256 proposal) external view returns (bool);
    function getDefaultVotingParameters() external view returns (VotingParameters memory);
    function canVote(address voter) external view returns (bool);
    function canPropose(address proposer) external view returns (bool);
}