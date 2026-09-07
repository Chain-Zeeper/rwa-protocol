// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
import { IConstitution } from "./interface/IConstitution.sol";
import { IGoverner, Proposal, VotingParameters } from "../interface/IGoverner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// Draft: RWA-token-balance-weighted voting strategy. Voting power is read
// straight off current token balance, not a proposal-time snapshot -- see
// getVotes below. Revisit once RWA.sol is on ERC20Votes.
//
// Initializable (rather than immutable constructor args) so this can be
// registered as a template and cloned via ConstitutionRegistry, same as Council.
contract RWAHolder is IConstitution, Initializable {
    address public rwaToken;
    uint256 public thresholdBps;
    uint256 public quorumBps;
    uint256 public votingPeriod;

    address complianceHub;

    constructor() { _disableInitializers(); }

    function initialize(address _rwaToken, uint256 _thresholdBps, uint256 _quorumBps, uint256 _votingPeriod) external initializer {
        require(_thresholdBps <= 10000 && _quorumBps <= 10000, "bps must be <= 10000");
        rwaToken = _rwaToken;
        thresholdBps = _thresholdBps;
        quorumBps = _quorumBps;
        votingPeriod = _votingPeriod;
    }

    function name() external pure returns (string memory) {
        return "RWAHolder";
    }

    function canPropose(address proposer) external view returns (bool) {
        return IERC20(rwaToken).balanceOf(proposer) > 0;
    }

    function canVote(address voter) external view returns (bool) {
        return IERC20(rwaToken).balanceOf(voter) > 0;
    }

    function getVotingPower(address voter) external view returns (uint256) {
        
        return IERC20(rwaToken).balanceOf(voter);
    }

    // TODO: not a real snapshot -- reads current balance rather than balance
    // at proposal.voteStart, so a holder can move tokens between addresses to
    // vote more than once. Needs RWA.sol on ERC20Votes + getPastVotes here.
    function getVotes(address /* governor */, uint256 /* proposal */, address voter) external view returns (uint256) {
        return IERC20(rwaToken).balanceOf(voter);
    }

    function getExecuteThreshold() public view returns (uint256) {
        return thresholdBps * IERC20(rwaToken).totalSupply() / 10000;
    }

    function getQuorum() public view returns (uint256) {
        return quorumBps * IERC20(rwaToken).totalSupply() / 10000;
    }

    function getDefaultVotingParameters() external view returns (VotingParameters memory) {
        return VotingParameters(uint16(quorumBps), uint16(thresholdBps), votingPeriod);
    }


    // A passed proposal stays executable for this long after voteEnd; past it
    // the authorisation lapses instead of standing indefinitely.
    function executionGrace() external pure returns (uint256) {
        return 30 days;
    }

    // Token holders need the full window to turn out.
    function canExecuteEarly(address, uint256) external pure returns (bool) {
        return false;
    }

    function hasPassed(address governor, uint256 proposal) external view returns (bool) {
        if (IERC20(rwaToken).totalSupply() == 0) return false;
        Proposal memory p = IGoverner(governor).getProposal(proposal);
        uint256 totalVotes = p.forVotes + p.againstVotes;
        return p.forVotes >= getExecuteThreshold() && totalVotes >= getQuorum();
    }
}
