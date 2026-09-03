// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct Proposal {
    address proposer;
    uint256 voteStart;
    uint256 voteEnd;
    uint256 forVotes;
    uint256 againstVotes;
    bytes32 actionHash;
    bytes32 descriptionHash;
    uint256 nounce;
    bool executed;
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