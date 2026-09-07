// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IGoverner, Proposal, VotingParameters} from "../../interface/IGoverner.sol";
import {IConstitution} from "../interface/IConstitution.sol";
import {ISafe} from "./interface/ISafe.sol";

// A voting strategy whose electorate is a Gnosis Safe's owner set: the same
// Council rules (one member, one vote) but with membership read off the Safe
// instead of maintained here, so a Safe's owners govern without having to keep
// a second roster in sync.
//
// Two ways to cast the Safe's weight, matching the two ways Safe owners
// already work:
//
//   * an owner votes as themselves, for 1 vote; or
//   * the Safe votes as itself (a multisig transaction calling `vote`), which
//     carries `getThreshold()` votes -- that transaction already cleared the
//     Safe's threshold on-chain, so it stands in for that many owners.
//
// The Safe's own threshold is a floor on the execute threshold: governance
// configured through this constitution can be made stricter than the multisig
// but never looser than it.
//
// LIMITATION, and the reason this is not a drop-in for Council: the owner set
// is read live, not checkpointed at proposal creation. Council snapshots
// `totalCouncilMembers` precisely so the bar cannot move mid-vote; a Safe's
// owners live in a contract this one does not control, so adding or removing
// an owner while a proposal is open shifts quorum and threshold under it. Use
// this where the owner set is stable relative to the voting period, and treat
// owner changes as governance-affecting events.
contract SafeConstitution is IConstitution, Initializable {
    ISafe public safe;

    // fallback quorum/threshold/voting-period, used when the governor has no
    // per-target/selector override for a proposal's actions -- same role as
    // Council.defaultVotingParameters
    VotingParameters public defaultVotingParameters;

    event DefaultVotingParametersChanged(VotingParameters oldParams, VotingParameters newParams);

    modifier onlySafe() {
        require(msg.sender == address(safe), "only the safe");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    // takes the Safe as a parameter rather than reading msg.sender, because the
    // initializer runs with ConstitutionRegistry as the caller
    function initialize(
        address _safe,
        uint16 quorumBps,
        uint16 thresholdBps,
        uint256 votingPeriod
    ) external initializer {
        require(_safe != address(0), "zero safe");
        require(_safe.code.length > 0, "safe is not a contract");
        require(quorumBps <= 10000 && thresholdBps <= 10000, "bps must be <= 10000");
        safe = ISafe(_safe);
        _setDefaultVotingParameters(VotingParameters(quorumBps, thresholdBps, votingPeriod));
    }

    function setDefaultVotingParameters(
        uint16 quorumBps,
        uint16 thresholdBps,
        uint256 votingPeriod
    ) external onlySafe {
        require(quorumBps <= 10000 && thresholdBps <= 10000, "bps must be <= 10000");
        _setDefaultVotingParameters(VotingParameters(quorumBps, thresholdBps, votingPeriod));
    }

    function _setDefaultVotingParameters(VotingParameters memory params) internal {
        emit DefaultVotingParametersChanged(defaultVotingParameters, params);
        defaultVotingParameters = params;
    }

    function name() external pure returns (string memory) {
        return "SafeConstitution";
    }

    function totalOwners() public view returns (uint256) {
        return safe.getOwners().length;
    }

    // The Safe acting as itself has already met its threshold on-chain, so it
    // votes with that much weight; an individual owner votes with 1.
    function getVotingPower(address voter) public view returns (uint256) {
        if (voter == address(safe)) return safe.getThreshold();
        return safe.isOwner(voter) ? 1 : 0;
    }

    function getVotes(address /* governor */, uint256 /* proposal */, address voter) external view returns (uint256) {
        return getVotingPower(voter);
    }

    function canPropose(address proposer) external view returns (bool) {
        return proposer == address(safe) || safe.isOwner(proposer);
    }

    function canVote(address voter) external view returns (bool) {
        return voter == address(safe) || safe.isOwner(voter);
    }

    // ceiling-rounded, like Council: to require M of N owners set bps to
    // floor(M * 10000 / N). Floored at the Safe's own threshold so this can
    // tighten the multisig rule but never relax it.
    function getExecuteThreshold(uint16 thresholdBps) public view returns (uint256) {
        uint256 scaled = (uint256(thresholdBps) * totalOwners() + 9999) / 10000;
        uint256 safeThreshold = safe.getThreshold();
        return scaled > safeThreshold ? scaled : safeThreshold;
    }

    function getQuorum(uint16 quorumBps) public view returns (uint256) {
        return (uint256(quorumBps) * totalOwners() + 9999) / 10000;
    }

    function getDefaultVotingParameters() external view returns (VotingParameters memory) {
        return defaultVotingParameters;
    }


    // A passed proposal stays executable for this long after voteEnd; past it
    // the authorisation lapses instead of standing indefinitely.
    function executionGrace() external pure returns (uint256) {
        return 30 days;
    }

    // A Safe transaction has already gathered M-of-N consent before it ever
    // reaches the governor, so making the Safe wait out a voting period asks
    // the same people to agree twice. Once the bar is met the outcome is
    // settled and execution can happen immediately -- in the same transaction
    // as the proposal, since Governor.propose executes whatever it settles.
    //
    // Note this does NOT bypass delegate approvals: Governor checks those
    // separately, so a delegated selector still waits for its veto-holder.
    function canExecuteEarly(address governor, uint256 proposal) external view returns (bool) {
        return _hasPassed(governor, proposal);
    }

    function hasPassed(address governor, uint256 proposal) external view returns (bool) {
        return _hasPassed(governor, proposal);
    }

    function _hasPassed(address governor, uint256 proposal) internal view returns (bool) {
        if (totalOwners() == 0) return false;
        Proposal memory p = IGoverner(governor).getProposal(proposal);

        // A proposal the Safe filed itself arrived through a transaction that
        // had already met the threshold on-chain, so it carries exactly the
        // consent the Safe's own ballot would. Floored rather than added, so it
        // counts once even if the Safe also votes.
        uint256 forVotes = p.forVotes;
        if (p.proposer == address(safe)) {
            uint256 threshold = safe.getThreshold();
            if (forVotes < threshold) forVotes = threshold;
        }

        uint256 totalVotes = forVotes + p.againstVotes;
        return forVotes >= getExecuteThreshold(p.thresholdBps) && totalVotes >= getQuorum(p.quorumBps);
    }
}
