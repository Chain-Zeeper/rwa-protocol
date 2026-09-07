// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IGoverner, Proposal} from "../interface/IGoverner.sol";

// Lets any single address hold a veto over a governor's delegated selectors.
//
// Governor's hub/spoke model expects `delagateGovernance[target][selector]` to
// point at something implementing IGoverner: the hub calls `proposeApproval`
// while proposing, and `execute` refuses to run until `hasApproved` is true.
// Another Governor satisfies that natively. Nothing else does -- not a Safe,
// not a multisig, not a plain admin key -- so this adapter stands in for them.
//
// The approver is deliberately just an address. It can be:
//
//   * a Gnosis Safe -- owners approve through the multisig they already use;
//   * an EOA -- a plain admin veto, a compliance officer, an issuer;
//   * another Governor, or any contract at all.
//
// Nothing here is Safe-specific, because nothing needs to be. Approval is a
// plain call from the approver -- `msg.sender == approver` -- which for a Safe
// means a multisig transaction that has already met its threshold on-chain, and
// for an EOA means an ordinary transaction.
//
// There is deliberately no signature-verification path. A Safe already checks
// its owners' signatures itself before it will call anything, so re-checking
// them here would only duplicate work this contract is worse placed to do.
//
// Approval is one-way and one-shot per (hub, proposalId), matching
// Governor.approveProposal: there is no revocation, because an approver that
// could withdraw approval after voting closed could race a pending execute.
contract OwnedDelegate is IGoverner, Ownable2Step, Initializable {
    struct ApprovalRequest {
        address hub;
        uint256 hubProposalId;
        bytes32 actionHash;
        bytes32 descriptionHash;
        uint256 requestedAt;
    }

    struct Approval {
        bool approved;
        uint256 timestamp;
    }

    // hub => hub proposal id => the mirrored request the approver signs off on
    mapping(address => mapping(uint256 => ApprovalRequest)) public requests;
    // hub => hub proposal id => approval record
    mapping(address => mapping(uint256 => Approval)) public approvals;
    // requestId => the request, so getProposal has something to resolve
    mapping(uint256 => ApprovalRequest) internal requestsById;

    event ApprovalRequested(
        address indexed hub,
        uint256 indexed hubProposalId,
        uint256 indexed requestId,
        bytes32 actionHash
    );
    event ProposalApproved(address indexed hub, uint256 indexed hubProposalId, uint256 timestamp);

    // Ownable's constructor only ever runs against this implementation, never
    // against a clone, so the address it names here is thrown away; initialize
    // sets the real approver.
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    // takes the approver as a parameter rather than reading msg.sender, so this
    // can be cloned by a factory the same way constitutions are. No contract
    // check: an EOA approver is a supported configuration.
    function initialize(address _approver) external initializer {
        require(_approver != address(0), "zero approver");
        _transferOwnership(_approver);
    }

    // Ownership of this adapter IS the veto, so the two words mean the same
    // thing here. `approver` reads better at the call sites that care about the
    // role; `owner`/`transferOwnership`/`acceptOwnership` come from
    // Ownable2Step, which is also what makes the veto-holder rotatable without
    // re-registering the adapter on every hub that points at it.
    function approver() external view returns (address) {
        return owner();
    }

    // An adapter with no approver could never approve anything again, which
    // would permanently block every delegated selector on every hub that
    // registered it. Rotate instead.
    function renounceOwnership() public pure override {
        revert("use transferOwnership");
    }

    // ---------------------------------------------------------------
    // delegate surface (called by the hub)
    // ---------------------------------------------------------------

    // Mirrors a hub proposal locally so the approver has something bound to
    // sign. Left open rather than restricted to `msg.sender == hub`, matching
    // Governor.proposeApproval: the validation below is what makes it safe.
    function proposeApproval(
        address hub,
        uint256 hubProposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256) {
        require(targets.length == values.length && targets.length == calldatas.length, "length mismatch");

        uint256 requestId = getRequestId(hub, hubProposalId);

        // idempotent: the hub re-proposing the same id hands back the same handle
        if (requests[hub][hubProposalId].actionHash != bytes32(0)) {
            return requestId;
        }

        bytes32 actionHash = _validateHubProposal(hub, hubProposalId, targets, values, calldatas, descriptionHash);

        ApprovalRequest memory request = ApprovalRequest({
            hub: hub,
            hubProposalId: hubProposalId,
            actionHash: actionHash,
            descriptionHash: descriptionHash,
            requestedAt: block.timestamp
        });
        requests[hub][hubProposalId] = request;
        requestsById[requestId] = request;

        emit ApprovalRequested(hub, hubProposalId, requestId, actionHash);
        return requestId;
    }

    // 1. the id must correspond to a real, live proposal on that hub
    // 2. the actions the approver is shown must be the ones the hub proposed
    function _validateHubProposal(
        address hub,
        uint256 hubProposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) internal view returns (bytes32 actionHash) {
        Proposal memory hubProposal = IGoverner(hub).getProposal(hubProposalId);
        require(hubProposal.voteStart != 0, "no such hub proposal");
        require(block.timestamp < hubProposal.voteEnd, "hub voting already closed");

        actionHash = keccak256(abi.encode(targets, values, calldatas, descriptionHash));
        require(actionHash == hubProposal.actionHash, "actions do not match proposal");
    }

    function hasApproved(address hub, uint256 hubProposalId) external view returns (bool) {
        return approvals[hub][hubProposalId].approved;
    }

    // This adapter only ever approves what a hub asks it to; it has no
    // electorate of its own to originate proposals with.
    function propose(
        address[] calldata,
        uint256[] calldata,
        bytes[] calldata,
        bytes32
    ) external pure returns (uint256) {
        revert("OwnedDelegate: cannot originate proposals");
    }

    // Mirror view of a request, resolved live against the hub so the timing
    // fields stay accurate if the hub extended its own voting period after the
    // mirror was taken. `forVotes`/`executed` carry the approver's decision.
    function getProposal(uint256 requestId) external view returns (Proposal memory) {
        ApprovalRequest memory request = requestsById[requestId];
        if (request.actionHash == bytes32(0)) {
            return Proposal({
                proposer: address(0),
                quorumBps: 0,
                thresholdBps: 0,
                voteStart: 0,
                voteEnd: 0,
                forVotes: 0,
                againstVotes: 0,
                actionHash: bytes32(0),
                descriptionHash: bytes32(0),
                nounce: 0,
                executed: false,
                constitution: address(0)
            });
        }

        Proposal memory hubProposal = IGoverner(request.hub).getProposal(request.hubProposalId);
        bool approved = approvals[request.hub][request.hubProposalId].approved;

        hubProposal.proposer = request.hub;
        hubProposal.forVotes = approved ? 1 : 0;
        hubProposal.againstVotes = 0;
        hubProposal.executed = approved;
        return hubProposal;
    }

    // ---------------------------------------------------------------
    // approval
    // ---------------------------------------------------------------

    function approveProposal(address hub, uint256 hubProposalId) external onlyOwner {
        _approve(hub, hubProposalId);
    }

    function getRequestId(address hub, uint256 hubProposalId) public view returns (uint256) {
        return uint256(keccak256(abi.encode(address(this), block.chainid, hub, hubProposalId)));
    }

    // The approver can only ever approve actions it has already been shown:
    // without this, it could blind-approve an id before the hub mirrored what
    // that id actually does.
    function _approve(address hub, uint256 hubProposalId) internal {
        require(requests[hub][hubProposalId].actionHash != bytes32(0), "no approval request");

        if (approvals[hub][hubProposalId].approved) {
            return; // idempotent: keep the original timestamp
        }
        approvals[hub][hubProposalId] = Approval({approved: true, timestamp: block.timestamp});
        emit ProposalApproved(hub, hubProposalId, block.timestamp);
    }
}
