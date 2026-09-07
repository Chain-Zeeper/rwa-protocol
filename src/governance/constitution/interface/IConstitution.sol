// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VotingParameters} from "../../interface/IGoverner.sol";

interface IConstitution{
    function name() external view returns (string memory);
    function getVotes(address governor, uint256 proposal, address voter) external view returns (uint256);
    function getVotingPower(address voter) external view returns (uint256);
    function hasPassed(address governer,uint256 proposal) external view returns (bool);

    // Whether `proposal` may execute before its voting period has elapsed.
    // The timer exists to give an electorate time to turn out; when a
    // constitution can already tell the outcome is settled -- a single owner
    // has voted, or a Safe transaction has carried the whole threshold -- there
    // is nothing left to wait for. Constitutions with a genuine turnout period
    // return false and the deadline stands.
    //
    // Only sound where the tally is monotonic: votes here are additive with no
    // revocation, so once the bar is met further votes cannot unmeet it.
    // Governor still enforces delegate approvals independently of this.
    function canExecuteEarly(address governer, uint256 proposal) external view returns (bool);

    // How long after voteEnd a passed proposal stays executable. Without a
    // bound, a proposal that passed and was then quietly abandoned remains
    // executable forever -- a standing authorisation nobody remembers granting.
    // type(uint256).max opts out explicitly.
    function executionGrace() external view returns (uint256);
    function getDefaultVotingParameters() external view returns (VotingParameters memory);
    function canVote(address voter) external view returns (bool);
    function canPropose(address proposer) external view returns (bool);
}