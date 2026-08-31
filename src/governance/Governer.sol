//\/ SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IVotingStrategy} from "./interface/IVotingStrategy.sol";

struct Proposal {
    address proposer;
    uint256 voteStart;
    uint256 voteEnd;
    uint256 forVotes;
    uint256 againstVotes;
    bytes32 descriptionHash;
    bool executed;
}

struct Track {
    address strategy;    
    uint16 quorumBps;      
    uint16 thresholdBps; 
    bytes32 config;    
    uint256 forVotes;
    uint256 againstVotes;
}

struct VotingStyle {
    address strategy;  
    uint16 quorumBps;   
    uint16 thresholdBps;    
    bytes32 config;
}

struct Action {
    address target;
    uint256 value;
    bytes data;
}
contract Governor {

    mapping(address => mapping(bytes4 => VotingStyle)) public voteStyle;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    uint256 public nounce;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => Action[]) internal actions;
    // tracks the paralle tallys for bundled proposals differetn or same voting styles
    // per vote conts against both tallies for voter. where applicable
    mapping(uint256 => Track[]) public tracks;


    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        uint256 nounce,
        bytes32 descriptionHash
    );
    function registerVotingStyle(address target,address strategy, bytes4 selector, bytes32 config) public  onlyGovernance{
        require(voteStyle[target][selector].strategy == address(0), "already registered");
        uint16 q = IVotingStrategy(strategy).quorumBps(config);
        uint16 t = IVotingStrategy(strategy).thresholdBps(config);
        require(q > 0 && q <= 10000 && t > 0 && t <= 10000, "invalid bps from strategy");
        voteStyle[target][selector] = VotingStyle(strategy, q, t, config);
        
    }

    function updateVotingStyle(address _votingStyle, bytes4 selector, uint16 quorumBps, uint16 thresholdBps, bytes32 config) external onlyGovernance {
        require(voteStyle[address(this)][selector].strategy != address(0), "Voting style not registered for this selector");
        voteStyle[_votingStyle][selector] = VotingStyle({
            strategy: _votingStyle,
            quorumBps: IVotingStrategy(_votingStyle).quorumBps(config),
            thresholdBps: IVotingStrategy(_votingStyle).thresholdBps(config),
            config: config
        });
        
    }
    




    constructor(address _registerVotingStyle, bytes32 config) {
        registerVotingStyle(address(this),_registerVotingStyle,this.registerVotingStyle.selector,config);
    }
    function propose(address[] calldata  targets, uint256[] calldata  values, bytes[] calldata  calldatas,  bytes32 descriptionHash ) external returns (uint256) {
        bytes32 actionHash = keccak256(abi.encode(targets, values, calldatas, descriptionHash));
        uint256 proposalId = uint256(keccak256(abi.encode(actionHash, nounce)));
        bool validProoser = false; 
        require(targets.length == values.length && targets.length == calldatas.length, "Mismatched proposal parameters");
        

        for(uint256 i = 0; i < targets.length; i++) {
            bytes4 selector = bytes4(calldatas[i][:4]);
            VotingStyle memory style = voteStyle[targets[i]][selector];
            if(validProoser == false) {
                validProoser = canPropose(msg.sender, targets[i], selector);
            }
            // in case proposal to self to update voting style
            if(targets[i] == address(this) && selector == this.updateVotingStyle.selector) {
                require(calldatas[i].length >= 4 + 32 * 6, "malformed updateVotingStyle call");
                (address affectedTarget, bytes4 affectedSelector) =
                    abi.decode(calldatas[i][4:], (address, bytes4));
                style = voteStyle[affectedTarget][affectedSelector];                
            }
            require(style.strategy != address(0), "Voting style not registered for this target and selector");
            _addTrack(proposalId, style);
              
        }
        if(!validProoser) {
            revert("Proposer is not allowed to propose for any of the actions");
        }
        Proposal memory proposal = Proposal({
            proposer: msg.sender,
            voteStart: block.timestamp,
            voteEnd: block.timestamp + 3 days, // Example voting period
            forVotes: 0,
            againstVotes: 0,
            descriptionHash: descriptionHash,
            executed: false
            });
        proposals[proposalId] = proposal;
        emit ProposalCreated(proposalId, msg.sender, targets, values, calldatas, nounce, descriptionHash);
        nounce ++;
        return proposalId; 
    }

    function execute(
        uint256 proposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external {

    }
    function _addTrack(uint256 proposalId, VotingStyle memory s) internal {
        Track[] storage ts = tracks[proposalId];
        uint256 len = ts.length;

        for (uint256 i = 0; i < len; ) {
            if (ts[i].strategy == s.strategy && ts[i].config == s.config) {
                if (s.quorumBps > ts[i].quorumBps) ts[i].quorumBps = s.quorumBps;
                if (s.thresholdBps > ts[i].thresholdBps) ts[i].thresholdBps = s.thresholdBps;
                return;
            }
            unchecked { ++i; }
        }

        ts.push(Track({
            strategy: s.strategy,
            config: s.config,
            quorumBps: s.quorumBps,
            thresholdBps: s.thresholdBps,
            forVotes: 0,
            againstVotes: 0
        }));
    }

    function _execute(address target, uint256 value, bytes memory data) internal {
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        if (!success) {
            if (returndata.length > 0) {
                assembly {
                    let size := mload(returndata)
                    revert(add(returndata, 0x20), size)
                }
            } else {
                revert("Governor: call reverted without reason");
            }
        }
    }
    function canPropose(address proposer,address target,bytes4 selector) public view returns(bool){
        bytes32 config = voteStyle[target][selector].config;
        IVotingStrategy strategy = IVotingStrategy(voteStyle[target][selector].strategy); 
        return strategy.canPropose(proposer, config);
    }

    function _tallyVotes(uint256 proposalId) internal {
        // Implementation for tallying votes for a proposal
    }


    function canVote(uint256 proposalId, address voter) public view returns (bool) {
        // Implementation for checking if an address can vote on a proposal
    }
    modifier onlyGovernance() {
        require(msg.sender == address(this), "only via executed proposal");
        _;
    }
}

