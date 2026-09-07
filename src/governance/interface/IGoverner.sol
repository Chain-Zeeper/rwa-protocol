// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct Proposal {
    address proposer;
    uint16 quorumBps;
    uint16 thresholdBps;
    uint256 voteStart;
    uint256 voteEnd;
    uint256 forVotes;
    uint256 againstVotes;
    bytes32 actionHash;
    bytes32 descriptionHash;
    uint256 nounce;
    bool executed;
    // the constitution in force when this proposal was created. Execution
    // requires it to still be the governor's constitution, so authorisation
    // banked under one set of rules can never be spent under another.
    address constitution;
}

// shared shape for both a governor's per-target/selector overrides and a
// constitution's fallback defaults, so the two line up field-for-field
struct VotingParameters {
    uint16 quorumBps;
    uint16 thresholdBps;
    uint256 votingPeriod;
}

interface IGoverner{
    function propose(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256);

    function proposeApproval(
        address hub,
        uint256 hubProposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256);

    function hasApproved(address hub, uint256 hubProposalId) external view returns (bool);

    function getProposal(uint256 proposalId) external view returns (Proposal memory);
}