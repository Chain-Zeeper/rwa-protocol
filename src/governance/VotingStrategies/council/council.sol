// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import  "../../interface/IGoverner.sol";
import {IConstitution} from "../interface/IConstitution.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";


contract Council is IConstitution, Ownable,Initializable {
    using Checkpoints for Checkpoints.Trace208;

    
    mapping(address => bool) public isCouncil;
    uint256 public totalCouncilMembers;
    // historical record of totalCouncilMembers, keyed by timestamp, so
    // threshold/quorum checks can look up membership as of proposal creation
    // instead of the (manipulable) current count
    Checkpoints.Trace208 private _totalCouncilMembersCheckpoints;

    // fallback quorum/threshold/voting-period used when the governor has no
    // per-target/selector override registered for a proposal's actions
    // (an unregistered bps would otherwise default to a 0 requirement, which
    // trivially passes; an unregistered voting period would close voting
    // the instant it opened)
    VotingParameters public defaultVotingParameters;

    event CouncilMemberAdded(address indexed councilMember);
    event CouncilMemberRemoved(address indexed councilMember);
    event DefaultVotingParametersChanged(VotingParameters oldParams, VotingParameters newParams);

    function initialize(
        address owner,
        uint16 quorumBps,
        uint16 thresholdBps,
        uint256 votingPeriod,
        address[] memory councilMembers
    ) external initializer {
        _transferOwnership(owner);
        _setDefaultVotingParameters(VotingParameters(quorumBps, thresholdBps, votingPeriod));
        for (uint256 i = 0; i < councilMembers.length; i++) {
            _addCouncilMember(councilMembers[i]);
        }
        _totalCouncilMembersCheckpoints.push(SafeCast.toUint48(block.timestamp), SafeCast.toUint208(totalCouncilMembers));

    }

    function setDefaultVotingParameters(uint16 quorumBps, uint16 thresholdBps, uint256 votingPeriod) external onlyOwner {
        _setDefaultVotingParameters(VotingParameters(quorumBps, thresholdBps, votingPeriod));
    }

    function _setDefaultVotingParameters(VotingParameters memory params) internal {
        emit DefaultVotingParametersChanged(defaultVotingParameters, params);
        defaultVotingParameters = params;
    }
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }
    function addCouncilMember(address councilMember) external onlyOwner {
        _addCouncilMember(councilMember);
    }

    function _addCouncilMember(address councilMember) internal {
        require(!isCouncil[councilMember], "CouncilState: Already a council member");
        totalCouncilMembers += 1;
        isCouncil[councilMember] = true;
        _totalCouncilMembersCheckpoints.push(SafeCast.toUint48(block.timestamp), SafeCast.toUint208(totalCouncilMembers));
        emit CouncilMemberAdded( councilMember);
    }
    function removeCouncilMember(address councilMember) external onlyOwner {
        _removeCouncilMember(councilMember);
    }

    function _removeCouncilMember(address councilMember) internal {
        require(isCouncil[councilMember], "CouncilState: Not a council member");
        totalCouncilMembers -= 1;
        isCouncil[councilMember] = false;
        _totalCouncilMembersCheckpoints.push(SafeCast.toUint48(block.timestamp), SafeCast.toUint208(totalCouncilMembers));
        emit CouncilMemberRemoved( councilMember);
    }

    // total council members as of `timepoint` (a block timestamp), per the
    // checkpoint trail -- used so threshold/quorum checks are pinned to
    // membership at proposal creation rather than whatever it is now
    function getPastTotalCouncilMembers(uint256 timepoint) public view returns (uint256) {
        require(timepoint < block.timestamp, "Council: future lookup");
        return _totalCouncilMembersCheckpoints.upperLookup(SafeCast.toUint48(timepoint));
    }

    function name() external pure returns (string memory){
        return "Council";
    }

    function getVotes(address governor, uint256 proposal, address voter) external view returns (uint256){
        return isCouncil[voter] ? 1 : 0;
    }

    function getVotingPower(address voter) external view returns (uint256){
        return isCouncil[voter] ? 1 : 0;
    }

    function getExecuteThreshold(uint16 thresholdbps, uint256 timepoint) public view returns (uint256){
        return (thresholdbps * getPastTotalCouncilMembers(timepoint) + 9999) / 10000;
    }

    function getQuorum(uint16 quorumbps, uint256 timepoint) public view returns (uint256){
        return (quorumbps * getPastTotalCouncilMembers(timepoint) + 9999) / 10000;
    }

    function getDefaultVotingParameters() external view returns (VotingParameters memory) {
        return defaultVotingParameters;
    }

    function hasPassed(address governor,uint256 proposal) external view returns (bool){
        if (totalCouncilMembers == 0) return false;
        IGoverner g = IGoverner(governor);
        Proposal memory p = g.getProposal(proposal);
        uint256 totalVotes = p.forVotes + p.againstVotes;
        return p.forVotes >= getExecuteThreshold(p.thresholdBps, p.voteStart) && totalVotes >= getQuorum(p.quorumBps, p.voteStart);
    }

    // default returns false until proposer eligibility is designed
    function canPropose(address proposer) external view returns (bool){
        return isCouncil[proposer];
    }

    function canVote(address voter) external view returns (bool){
        return isCouncil[voter];
    }

}
