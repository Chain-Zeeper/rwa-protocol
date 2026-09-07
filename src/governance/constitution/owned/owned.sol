// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IGoverner, Proposal, VotingParameters} from "../../interface/IGoverner.sol";
import {IConstitution} from "../interface/IConstitution.sol";

// The degenerate constitution: a single address decides everything.
//
// This is what makes an "owned" governor possible without bolting an owner
// role onto Governor itself. Ownership lives here, in the pluggable authority
// layer, which buys three things:
//
//   * progressive decentralisation is a constitution swap, not a migration.
//     changeConstitutionalStrategy moves an owned governor to a Council, a
//     Safe or a token DAO while the governor's address -- and therefore every
//     contract holding `owner == governor`, plus the treasury -- stays put;
//   * the owner still acts through propose/execute, so every action leaves a
//     ProposalCreated trail bound to an actionHash, and delegate approvals
//     still apply to it. An owner can be vetoed on a delegated selector, which
//     is something plain Ownable cannot express;
//   * there is no permanent owner field left behind on the governor to serve
//     as a backdoor once governance has moved on.
//
// The cost over `onlyOwner` is gas: an owned action is still a proposal.
// Governor.propose collapses proposing, voting and executing into one call
// whenever the owner's ballot alone settles the outcome.
//
// `owner` may be an EOA, a Safe, or another governor. A 1-of-1 Safe with
// SafeConstitution is equivalent and gives you owner rotation for free; this
// exists so a deployment that just wants a plain admin address does not have
// to stand up a Safe.
contract Owned is IConstitution, Ownable2Step, Initializable {
    // Only ever a deadline for the owner's own convenience -- canExecuteEarly
    // below means the owner never actually serves it. It matters only if the
    // constitution is later swapped for one with a real electorate, or if a
    // proposal is left to sit.
    uint256 public votingPeriod;

    event VotingPeriodChanged(uint256 oldPeriod, uint256 newPeriod);

    // Ownable's constructor only ever runs against this implementation, never
    // against a clone, so the address it names here is thrown away; initialize
    // sets the real owner. Same pattern Council uses.
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    // owner is a parameter rather than msg.sender because the initializer runs
    // with ConstitutionRegistry as the caller
    function initialize(address _owner, uint256 _votingPeriod) external initializer {
        require(_owner != address(0), "zero owner");
        // A zero period leaves voteEnd == voteStart, which breaks two things:
        // a vote cast in any later block reverts as closed, and a delegate's
        // `block.timestamp < hubProposal.voteEnd` check fails at propose time.
        // The owner never waits for this deadline anyway (canExecuteEarly), so
        // make it generous -- a year is a sensible default.
        require(_votingPeriod > 0, "zero voting period");
        _transferOwnership(_owner);
        votingPeriod = _votingPeriod;
    }

    function name() external pure returns (string memory) {
        return "Owned";
    }

    function canPropose(address proposer) external view returns (bool) {
        return proposer == owner();
    }

    function canVote(address voter) external view returns (bool) {
        return voter == owner();
    }

    function getVotingPower(address voter) public view returns (uint256) {
        return voter == owner() ? 1 : 0;
    }

    function getVotes(address /* governor */, uint256 /* proposal */, address voter) external view returns (uint256) {
        return getVotingPower(voter);
    }

    // 100% quorum and threshold of a one-address electorate is one vote, which
    // is the point. A per-selector override cannot raise the bar above this,
    // since any bps of a single voter ceiling-rounds to 1.
    function getDefaultVotingParameters() external view returns (VotingParameters memory) {
        return VotingParameters(10000, 10000, votingPeriod);
    }

    // With a one-address electorate there is no one else to hear from, so the
    // owner filing a proposal already settles it -- an explicit ballot is
    // accepted too, but never required. This is what lets Governor.propose
    // execute an owned action in the same call without casting a vote on the
    // proposer's behalf.
    function hasPassed(address governor, uint256 proposal) public view returns (bool) {
        Proposal memory p = IGoverner(governor).getProposal(proposal);
        return p.proposer == owner() || p.forVotes >= 1;
    }


    // A passed proposal stays executable for this long after voteEnd; past it
    // the authorisation lapses instead of standing indefinitely.
    function executionGrace() external pure returns (uint256) {
        return 30 days;
    }

    // The owner voting for its own proposal settles it outright: there is no
    // one else to hear from. So an owned governor executes in the same
    // transaction it proposes in.
    //
    // Consequence worth being deliberate about: a votingPeriod override
    // registered on a target/selector as a deliberate delay does NOT hold the
    // owner back. If you want a mandatory delay on something -- and
    // changeConstitutionalStrategy is the strongest candidate, since whoever
    // holds the constitution can install one granting themselves everything --
    // gate it with a delegate, or gate it here with a timestamp check.
    function canExecuteEarly(address governor, uint256 proposal) external view returns (bool) {
        return hasPassed(governor, proposal);
    }

    // ---------------------------------------------------------------
    // ownership
    // ---------------------------------------------------------------

    function setVotingPeriod(uint256 _votingPeriod) external onlyOwner {
        emit VotingPeriodChanged(votingPeriod, _votingPeriod);
        votingPeriod = _votingPeriod;
    }

    // transferOwnership/acceptOwnership come from Ownable2Step: two-step, so a
    // typo cannot strand the governor with an unreachable owner.

    function renounceOwnership() public pure override {
        // deliberately not supported: an owned governor with no owner can never
        // execute anything again, including the proposal that would swap in a
        // new constitution. Hand it to a Safe or a Council instead.
        revert("use transferOwnership");
    }
}
