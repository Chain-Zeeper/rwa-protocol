// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
import { IConstitution } from "../../VotingStrategies/interface/IConstitution.sol";
import { IGoverner, Proposal } from "../../interface/IGoverner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Draft: RWA-token-balance-weighted voting strategy. Voting power is read
// straight off current token balance, not a proposal-time snapshot -- see
// getVotes below. Revisit once RWA.sol is on ERC20Votes.
contract RWAHolder is IConstitution {
    address public immutable rwaToken;
    uint256 public immutable thresholdBps;
    uint256 public immutable quorumBps;

    address complianceHub;

    constructor(address _rwaToken, uint256 _thresholdBps, uint256 _quorumBps) {
        rwaToken = _rwaToken;
        thresholdBps = _thresholdBps;
        quorumBps = _quorumBps;
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

    function hasPassed(address governor, uint256 proposal) external view returns (bool) {
        Proposal memory p = IGoverner(governor).getProposal(proposal);
        uint256 totalVotes = p.forVotes + p.againstVotes;
        return p.forVotes >= getExecuteThreshold() && totalVotes >= getQuorum();
    }
}
