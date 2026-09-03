// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "./interface/IGoverner.sol";
import {IConstitution} from "./VotingStrategies/interface/IConstitution.sol";


struct VotingStyle {
    address strategy;
    uint16 quorumBps;
    uint16 thresholdBps;
    bytes32 config;
}

enum FunctionAuthority {
    Hub,        // governor can still call this directly
    Delegated   // fully delegated to the spoke; hub access revoked
}

struct DelageteGovernace {
    address governer;
    FunctionAuthority authority;
}

struct Action {
    address target;
    uint256 value;
    bytes data;
}

struct Approvals {
    bool approved;
    uint256 timestamp;
}

struct DelegateRegistration {
    address target;
    address delegate;
    bytes4 selector;
    FunctionAuthority authority;
}

contract Governor is IGoverner,Initializable {
    constructor() { _disableInitializers(); }

    address public constitution;
    uint256 public nounce;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => Action[]) internal actions;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    mapping(address => mapping(bytes4 => DelageteGovernace)) public delagateGovernance;

    // hub => hub proposal id => approval record
    mapping(address => mapping(uint256 => Approvals)) public approvals;
    // hub => hub proposal id => this contract's proposal id for that approval
    mapping(address => mapping(uint256 => uint256)) public approvalProposalId;

    mapping(uint256 => address[]) public delegates;

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        uint256 nounce,
        bytes32 descriptionHash
    );

    event ProposalApproved(address indexed hub, uint256 indexed hubProposalId, uint256 timestamp);

    // ---------------------------------------------------------------
    // constitutional strategy
    // ---------------------------------------------------------------

    function changeConstitutionalStrategy(address newConstitution) external onlyGovernance {
        require(newConstitution != address(0), "cannot set to zero address");
        _changeConstitutionalStrategy(newConstitution);
    }

    function _changeConstitutionalStrategy(address newStrategy) internal {
        constitution = newStrategy;
    }

    function initialize(
        address _constitutionalStrategy,
        bytes32 constitutionalConfig,
        DelegateRegistration[] calldata registrations
    ) external initializer {
        _changeConstitutionalStrategy(_constitutionalStrategy);
        for (uint256 i = 0; i < registrations.length; i++) {
            require(registrations[i].target != address(this), "governor selectors seeded internally");
            require(registrations[i].delegate != address(this), "cannot delegate to self");
            _setDelegateGovernance(
                registrations[i].target,
                registrations[i].selector,
                registrations[i].delegate,
                registrations[i].authority
            );
        }
    }

    // ---------------------------------------------------------------
    // delegation
    // ---------------------------------------------------------------

    function _setDelegateGovernance(
        address target,
        bytes4 selector,
        address delegate,
        FunctionAuthority authority
    ) internal {
        delagateGovernance[target][selector] = DelageteGovernace(delegate, authority);
    }

    function setDelegateGovernance(
        address target,
        bytes4 selector,
        address delegate,
        FunctionAuthority authority
    ) external {
        require(delegate != address(this), "cannot delegate to self");

        DelageteGovernace memory current = delagateGovernance[target][selector];

        if (current.governer != address(0) && current.authority == FunctionAuthority.Delegated) {
            if (msg.sender != current.governer) {
                revert("only delegated governer can call this function");
            }
            _setDelegateGovernance(target, selector, delegate, authority);
            return;
        }

        if (msg.sender != address(this)) {
            revert("only via executed proposal");
        }
        _setDelegateGovernance(target, selector, delegate, authority);
    }

    function restoreDelegateGovernance(address target, bytes4 selector) external {
        DelageteGovernace memory current = delagateGovernance[target][selector];

        if (current.authority == FunctionAuthority.Delegated) {
            require(msg.sender == current.governer, "only delegated governer can restore");
        } else {
            require(msg.sender == address(this), "only via executed proposal");
        }

        delete delagateGovernance[target][selector];
    }

    // ---------------------------------------------------------------
    // approvals (this contract acting as a delegate for some hub)
    // ---------------------------------------------------------------

    function approveProposal(address hub, uint256 hubProposalId) external onlyGovernance {
        if (approvals[hub][hubProposalId].approved) {
            return; // idempotent: keep the original timestamp
        }
        approvals[hub][hubProposalId] = Approvals({ approved: true, timestamp: block.timestamp });
        emit ProposalApproved(hub, hubProposalId, block.timestamp);
    }

    function hasApproved(address hub, uint256 hubProposalId) external view returns (bool) {
        return approvals[hub][hubProposalId].approved;
    }

    function proposeApproval(
        address hub,
        uint256 hubProposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256) {
        require(targets.length == values.length && targets.length == calldatas.length, "length mismatch");

        // already have an approval proposal for this hub proposal: idempotent, hand back the id
        uint256 existing = approvalProposalId[hub][hubProposalId];
        if (existing != 0) {
            return existing;
        }

        _validateHubProposal(hub, hubProposalId, targets, values, calldatas, descriptionHash);

        uint256 childProposalId = _proposeApprovalAction(hub, hubProposalId);
        approvalProposalId[hub][hubProposalId] = childProposalId;
        return childProposalId;
    }

    // 1. the id must correspond to a real, live proposal on that hub
    // 2. the actions shown to voters must be the ones the hub actually proposed
    function _validateHubProposal(
        address hub,
        uint256 hubProposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) internal view {
        Proposal memory hubProposal = IGoverner(hub).getProposal(hubProposalId);
        require(hubProposal.voteStart != 0, "no such hub proposal");
        require(block.timestamp < hubProposal.voteEnd, "hub voting already closed");

        bytes32 actionHash = keccak256(abi.encode(targets, values, calldatas, descriptionHash));
        require(actionHash == hubProposal.actionHash, "actions do not match proposal");
    }

    // build our own payload, the hub never supplies calldata we execute
    function _proposeApprovalAction(address hub, uint256 hubProposalId) internal returns (uint256) {
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(this);
        v[0] = 0;
        c[0] = abi.encodeWithSelector(this.approveProposal.selector, hub, hubProposalId);

        return _propose(t, v, c, keccak256(abi.encode("approval", hub, hubProposalId)));
    }

    // ---------------------------------------------------------------
    // proposals
    // ---------------------------------------------------------------

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function propose(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256) {
        require(targets.length == values.length && targets.length == calldatas.length, "Mismatched proposal parameters");
        require(IConstitution(constitution).canPropose(msg.sender), "Proposer not eligible");
        return _propose(targets, values, calldatas, descriptionHash);
    }

    function _propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal returns (uint256) {
        bytes32 actionHash = keccak256(abi.encode(targets, values, calldatas, descriptionHash));
        uint256 proposalId = uint256(keccak256(abi.encode(address(this), block.chainid, actionHash, nounce)));

        // written before the delegate loop: the delegates call back to read it
        proposals[proposalId] = Proposal({
            proposer: msg.sender,
            voteStart: block.timestamp,
            voteEnd: block.timestamp + 3 days, // TODO: configurable voting period
            forVotes: 0,
            againstVotes: 0,
            actionHash: actionHash,
            descriptionHash: descriptionHash,
            nounce: nounce,
            executed: false
        });

        for (uint256 i = 0; i < targets.length; i++) {
            bytes4 selector = _selectorOf(calldatas[i]);
            DelageteGovernace memory delagate = delagateGovernance[targets[i]][selector];

            if (delagate.governer != address(0) && delagate.authority == FunctionAuthority.Delegated) {
                IGoverner(delagate.governer).proposeApproval(
                    address(this),
                    proposalId,
                    targets,
                    values,
                    calldatas,
                    descriptionHash
                );
                _addDelegate(proposalId, delagate.governer);
            }
        }

        emit ProposalCreated(proposalId, msg.sender, targets, values, calldatas, nounce, descriptionHash);
        nounce++;
        return proposalId;
    }

    function _addDelegate(uint256 proposalId, address delegate) internal {
        address[] storage ds = delegates[proposalId];
        for (uint256 i = 0; i < ds.length; i++) {
            if (ds[i] == delegate) return; // already required for this proposal
        }
        ds.push(delegate);
    }

    function _selectorOf(bytes memory data) internal pure returns (bytes4 selector) {
        require(data.length >= 4, "calldata too short");
        assembly {
            selector := mload(add(data, 0x20))
        }
    }

    // ---------------------------------------------------------------
    // execution
    // ---------------------------------------------------------------

    function execute(
        uint256 proposalId,
        uint256 _nounce,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.voteStart != 0, "no such proposal");
        require(proposal.nounce == _nounce, "Invalid nounce");
        require(!proposal.executed, "Proposal already executed");
        require(block.timestamp > proposal.voteEnd, "Voting still open");

        // the actions passed in must be the ones that were proposed
        bytes32 actionHash = keccak256(abi.encode(targets, values, calldatas, descriptionHash));
        require(actionHash == proposal.actionHash, "actions do not match proposal");
        require(
            proposalId == uint256(keccak256(abi.encode(address(this), block.chainid, actionHash, _nounce))),
            "proposal id mismatch"
        );

        // every delegate that was required at proposal time must have approved
        address[] storage required = delegates[proposalId];
        for (uint256 i = 0; i < required.length; i++) {
            require(
                IGoverner(required[i]).hasApproved(address(this), proposalId),
                "delegate approval missing"
            );
        }

        bool passed = IConstitution(constitution).hasPassed(address(this), proposalId); // TODO: not implemented yet
        require(passed, "Proposal did not pass");

        proposal.executed = true;
        for (uint256 i = 0; i < targets.length; i++) {
            _execute(targets[i], values[i], calldatas[i]);
        }
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

    // ---------------------------------------------------------------
    // voting  (unfinished)
    // ---------------------------------------------------------------

    function vote(uint256 proposalId, bool support) external {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp >= proposal.voteStart && block.timestamp <= proposal.voteEnd, "Voting is closed");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        require(IConstitution(constitution).canVote(msg.sender), "Cannot vote");
        hasVoted[proposalId][msg.sender] = true;
        IConstitution strategy = IConstitution(constitution);
        uint256 weight = strategy.getVotes(address(this), proposalId, msg.sender);
        proposal.forVotes += support ? weight : 0;
        proposal.againstVotes += support ? 0 : weight;

    }


    modifier onlyGovernance() {
        require(msg.sender == address(this), "only via executed proposal");
        _;
    }
}