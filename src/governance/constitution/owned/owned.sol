// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IGoverner, Proposal, VotingParameters} from "../../interface/IGoverner.sol";
import {IConstitution} from "../interface/IConstitution.sol";

// The degenerate constitution: a single address decides everything. Owner may
// be an EOA, a Safe, or another governor.
//
// Keeping ownership here rather than as an owner role on Governor means
// decentralising later is a constitution swap, not a migration -- the
// governor's address never moves, so every contract holding `owner ==
// governor` is untouched -- and an owner still acts through propose/execute,
// so delegated vetoes apply to it. Plain Ownable can express neither.
contract Owned is IConstitution, Ownable2Step, Initializable {
    // The owner never serves this deadline (see canExecuteEarly). It matters
    // only if the constitution is later swapped for a real electorate.
    uint256 public votingPeriod;

    event VotingPeriodChanged(uint256 oldPeriod, uint256 newPeriod);

    // Ownable's constructor runs only against this implementation, never a
    // clone, so the owner it names here is thrown away; initialize sets the
    // real one.
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    // owner is a parameter, not msg.sender: the initializer runs with
    // ConstitutionRegistry as the caller
    function initialize(address _owner, uint256 _votingPeriod) external initializer {
        require(_owner != address(0), "zero owner");
        // zero leaves voteEnd == voteStart: later ballots revert as closed, and
        // every delegated proposal fails the delegate's voteEnd check
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

    // any bps of a one-address electorate ceiling-rounds to one vote, so no
    // per-selector override can raise the bar above this
    function getDefaultVotingParameters() external view returns (VotingParameters memory) {
        return VotingParameters(10000, 10000, votingPeriod);
    }

    // Nobody else to hear from, so the owner filing a proposal settles it. A
    // ballot is accepted but never required -- which is what lets
    // Governor.propose execute in one call without forging a vote.
    function hasPassed(address governor, uint256 proposal) public view returns (bool) {
        Proposal memory p = IGoverner(governor).getProposal(proposal);
        return p.proposer == owner() || p.forVotes >= 1;
    }


    // past this, a passed-but-abandoned proposal lapses rather than standing
    // as a live authorisation forever
    function executionGrace() external pure returns (uint256) {
        return 30 days;
    }

    // Worth being deliberate about: a votingPeriod override registered as a
    // deliberate delay does NOT hold the owner back. For a mandatory delay --
    // changeConstitutionalStrategy being the strongest candidate -- gate it
    // with a delegate, or add a timestamp check here.
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

    // transferOwnership/acceptOwnership come from Ownable2Step, so a typo
    // cannot strand the governor with an unreachable owner.

    // An owned governor with no owner could never execute anything again --
    // including the proposal that would install a new constitution.
    function renounceOwnership() public pure override {
        revert("use transferOwnership");
    }
}
