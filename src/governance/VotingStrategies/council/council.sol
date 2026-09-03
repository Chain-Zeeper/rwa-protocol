// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import  "../../interface/IGoverner.sol";
import {IConstitution} from "../interface/IConstitution.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";


contract Council is IConstitution, Ownable,Initializable {

    uint256 thresholdBps;
    uint256 quorumBps;
    mapping(address => bool) public isCouncil;
    uint256 public totalCouncilMembers;
    event CouncilMemberAdded(address indexed councilMember);
    event CouncilMemberRemoved(address indexed councilMember);
  
    function initialize(address owner,uint256 _thresholdBps,uint256 _quorumBps,address[] memory councilMembers) external initializer {
        _transferOwnership(owner);
        thresholdBps = _thresholdBps;
        quorumBps = _quorumBps;
        for (uint256 i = 0; i < councilMembers.length; i++) {
            addCouncilMember(councilMembers[i]);
        }
        
    }
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }
    function addCouncilMember(address councilMember) public onlyOwner {
        require(!isCouncil[councilMember], "CouncilState: Already a council member");
        totalCouncilMembers += 1;
        isCouncil[councilMember] = true;
        emit CouncilMemberAdded( councilMember);
    }
    function removeCouncilMember(address councilMember) public onlyOwner {
        totalCouncilMembers -= 1;
        isCouncil[councilMember] = false;
        emit CouncilMemberRemoved( councilMember);
    }

    function name() external pure returns (string memory){
        return "Council";
    }

    function getVotes(address governor, uint256 proposal, address voter) external view returns (uint256){
        return isCouncil[voter] ? 1 : 0;
    }

    function getVotingPower(address voter) external pure returns (uint256){
        return 1;
    }

    function getExecuteThreshold() public view returns (uint256){
        uint256 threshold = thresholdBps * totalCouncilMembers / 10000;
        return threshold;
    }

    
    function getQuorum() public view returns (uint256){
        return quorumBps * totalCouncilMembers / 10000;
    }

    function hasPassed(address governor,uint256 proposal) external view returns (bool){
        IGoverner g = IGoverner(governor);
        Proposal memory p = g.getProposal(proposal);
        uint256 totalVotes = p.forVotes + p.againstVotes;
        return p.forVotes >= getExecuteThreshold() && totalVotes >=  getQuorum();
    }

    // default returns false until proposer eligibility is designed
    function canPropose(address proposer) external view returns (bool){
        return isCouncil[proposer];
    }

    function canVote(address voter) external view returns (bool){
        return isCouncil[voter];
    }

}
