// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interface/IGoverner.sol";
import {IConstitution} from "./constitution/interface/IConstitution.sol";


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

struct VotingParametersRegistration {
    address target;
    bytes4 selector;
    VotingParameters params;
}

contract Governor is IGoverner, Initializable, ERC2771Context {
    // trustedForwarder is baked into this implementation's bytecode, so every
    // clone against it shares one protocol-wide relayer
    constructor(address trustedForwarder) ERC2771Context(trustedForwarder) {
        _disableInitializers();
    }

    // "any call to this target". A wildcard and a specific rule both apply --
    // delegates union, parameters take the max -- so a narrower rule can raise
    // the bar but never undercut a blanket one.
    bytes4 public constant ANY_SELECTOR = 0xffffffff;

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
    mapping(address => mapping(bytes4 => VotingParameters)) public votingParameters;
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

    // relayed ballots have no msg.sender trail, so the voter is only
    // recoverable from an event
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);

    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

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
        DelegateRegistration[] memory delegateRegistrations,
        VotingParametersRegistration[] memory votingParameterRegistrations
    ) external initializer {
        _changeConstitutionalStrategy(_constitutionalStrategy);
        for (uint256 i = 0; i < delegateRegistrations.length; i++) {
            require(delegateRegistrations[i].target != address(this), "governor selectors seeded internally");
            _setDelegateGovernance(
                delegateRegistrations[i].target,
                delegateRegistrations[i].selector,
                delegateRegistrations[i].delegate,
                delegateRegistrations[i].authority
            );
        }
        for (uint256 i = 0; i < votingParameterRegistrations.length; i++) {
            require(votingParameterRegistrations[i].target != address(this), "governor selectors seeded internally");
            _setVotingParameters(
                votingParameterRegistrations[i].target,
                votingParameterRegistrations[i].selector,
                votingParameterRegistrations[i].params
            );
        }
    }

    function _setVotingParameters(address target, bytes4 selector, VotingParameters memory params) internal {
        votingParameters[target][selector] = params;
    }

    function setVotingParameters(
        address target,
        bytes4 selector,
        uint16 quorumBps,
        uint16 thresholdBps,
        uint256 votingPeriod
    ) external onlyGovernance {
        _setVotingParameters(target, selector, VotingParameters(quorumBps, thresholdBps, votingPeriod));
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

    function _proposeApprovalAction(address hub, uint256 hubProposalId) internal returns (uint256) {
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(this);
        v[0] = 0;
        c[0] = abi.encodeWithSelector(this.approveProposal.selector, hub, hubProposalId);     
        return _propose(msg.sender, t, v, c, keccak256(abi.encode("approval", hub, hubProposalId)));
    }
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function propose(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external returns (uint256 proposalId) {
        require(targets.length == values.length && targets.length == calldatas.length, "Mismatched proposal parameters");
        address proposer = _msgSender();
        require(IConstitution(constitution).canPropose(proposer), "Proposer not eligible");

        proposalId = _propose(proposer, targets, values, calldatas, descriptionHash);

        // Some electorates are settled the moment the proposal exists: a
        // constitution whose authority-holder is the proposer has nobody left
        // to hear from, and says so through hasPassed. Run it now -- that is
        // what makes an owned governor behave like Ownable from a single call,
        // with a full proposal trail behind it.
        //
        // Deliberately does NOT cast a ballot on the proposer's behalf.
        // Proposing and supporting are separate acts for a real electorate, and
        // conflating them would start every council proposal one vote up.
        //
        // Anything not yet settled simply stands open and follows the normal
        // path: an electorate that still has to turn out, or a delegated
        // selector whose veto-holder was only just notified -- in this very
        // transaction, so it cannot possibly have approved yet. Those are left
        // for execute() to pick up, never reverted, because reverting here
        // would roll back _propose and with it the proposeApproval calls that
        // notify the delegates.
        if (canExecuteNow(proposalId)) {
            _runActions(proposalId, targets, values, calldatas);
        }
    }

    function _propose(
        address proposer,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal returns (uint256) {
        bytes32 actionHash = keccak256(abi.encode(targets, values, calldatas, descriptionHash));
        uint256 proposalId = uint256(keccak256(abi.encode(address(this), block.chainid, actionHash, nounce)));
        VotingParameters memory defaults = IConstitution(constitution).getDefaultVotingParameters();

        Proposal storage proposal = proposals[proposalId];
        proposal.proposer = proposer;
        proposal.voteStart = block.timestamp;
        proposal.voteEnd = block.timestamp + defaults.votingPeriod;
        proposal.actionHash = actionHash;
        proposal.descriptionHash = descriptionHash;
        proposal.nounce = nounce;
        // pinned so this proposal can only ever be judged by the rules it was
        // created under; execute refuses if the constitution has since changed
        proposal.constitution = constitution;

        VotingParameters memory strictest;
        uint256 delegateVoteEnd;
        for (uint256 i = 0; i < targets.length; i++) {
            if (calldatas[i].length == 0) continue; // no selector to key a rule on
            bytes4 selector = _selectorOf(calldatas[i]);
            uint256 d = _applyRules(strictest, proposalId, targets[i], selector, targets, values, calldatas, descriptionHash);
            if (d > delegateVoteEnd) delegateVoteEnd = d;
            if (selector != ANY_SELECTOR) {
                d = _applyRules(strictest, proposalId, targets[i], ANY_SELECTOR, targets, values, calldatas, descriptionHash);
                if (d > delegateVoteEnd) delegateVoteEnd = d;
            }
        }

        if (strictest.quorumBps == 0) strictest.quorumBps = defaults.quorumBps;
        if (strictest.thresholdBps == 0) strictest.thresholdBps = defaults.thresholdBps;
        if (strictest.votingPeriod == 0) strictest.votingPeriod = defaults.votingPeriod;

        proposal.quorumBps = strictest.quorumBps;
        proposal.thresholdBps = strictest.thresholdBps;
        proposal.voteEnd = proposal.voteStart + strictest.votingPeriod;

        // A spoke resolves on its own constitution's clock, which may run past
        // ours. Stretch to cover the slowest of them, so a proposal cannot
        // expire while it is still legitimately waiting on a delegate.
        if (delegateVoteEnd > proposal.voteEnd) {
            proposal.voteEnd = delegateVoteEnd;
        }

        emit ProposalCreated(proposalId, proposer, targets, values, calldatas, nounce, descriptionHash);
        nounce++;
        return proposalId;
    }


    function _applyRules(
        VotingParameters memory strictest,
        uint256 proposalId,
        address target,
        bytes4 key,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal returns (uint256 delegateVoteEnd) {
        VotingParameters memory params = votingParameters[target][key];
        if (params.quorumBps > strictest.quorumBps) {
            strictest.quorumBps = params.quorumBps;
        }
        if (params.thresholdBps > strictest.thresholdBps) {
            strictest.thresholdBps = params.thresholdBps;
        }
        if (params.votingPeriod > strictest.votingPeriod) {
            strictest.votingPeriod = params.votingPeriod;
        }

        DelageteGovernace memory delagate = delagateGovernance[target][key];
        if (delagate.governer != address(0) && delagate.authority == FunctionAuthority.Delegated) {
            // proposeApproval hands back the delegate's own handle for this
            // request; reading it tells us when that delegate expects to have
            // decided. A Governor spoke reports its own voting deadline; an
            // OwnedDelegate mirrors ours and so reports nothing new, which is
            // right -- an approver signs whenever, it has no clock.
            //
            // Note this reads back into our own partially-written proposal via
            // the mirror. It is a view call and voteEnd is only provisional at
            // this point, which the max() above absorbs.
            uint256 childId = IGoverner(delagate.governer).proposeApproval(
                address(this),
                proposalId,
                targets,
                values,
                calldatas,
                descriptionHash
            );
            _addDelegate(proposalId, delagate.governer);
            delegateVoteEnd = IGoverner(delagate.governer).getProposal(childId).voteEnd;
        }
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

    // payable so a sponsor can cover a shortfall while executing; amounts sent
    // are fixed by actionHash, and any excess stays here unrefunded
    function execute(
        uint256 proposalId,
        uint256 _nounce,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 descriptionHash
    ) external payable {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.voteStart != 0, "no such proposal");
        require(proposal.nounce == _nounce, "Invalid nounce");
        require(!proposal.executed, "Proposal already executed");
        require(proposal.constitution == constitution, "constitution changed");
        require(!_isExpired(proposal), "proposal expired");

        // the actions passed in must be the ones that were proposed
        bytes32 actionHash = keccak256(abi.encode(targets, values, calldatas, descriptionHash));
        require(actionHash == proposal.actionHash, "actions do not match proposal");

        // The deadline is the default, but a constitution that can already tell
        // the outcome is settled may waive it -- an owner or a Safe has no one
        // left to hear from. Delegate approvals below are checked regardless.
        require(
            block.timestamp > proposal.voteEnd
                || IConstitution(constitution).canExecuteEarly(address(this), proposalId),
            "Voting still open"
        );

        // every delegate that was required at proposal time must have approved
        address[] storage required = delegates[proposalId];
        for (uint256 i = 0; i < required.length; i++) {
            require(
                IGoverner(required[i]).hasApproved(address(this), proposalId),
                "delegate approval missing"
            );
        }

        require(IConstitution(constitution).hasPassed(address(this), proposalId), "Proposal did not pass");

        _runActions(proposalId, targets, values, calldatas);
    }

    // The same predicate execute() enforces, in a form that answers instead of
    // reverting -- used by propose() to decide whether the proposal it just
    // created is already settled, and by any client deciding whether an action
    // will land in one transaction or need a second.
    function canExecuteNow(uint256 proposalId) public view returns (bool) {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.voteStart == 0 || proposal.executed) return false;
        if (proposal.constitution != constitution) return false;
        if (_isExpired(proposal)) return false;

        address[] storage required = delegates[proposalId];
        for (uint256 i = 0; i < required.length; i++) {
            if (!IGoverner(required[i]).hasApproved(address(this), proposalId)) return false;
        }

        if (
            block.timestamp <= proposal.voteEnd
                && !IConstitution(constitution).canExecuteEarly(address(this), proposalId)
        ) {
            return false;
        }

        return IConstitution(constitution).hasPassed(address(this), proposalId);
    }

    // A passed proposal that nobody executed should lapse, not sit as a
    // standing authorisation forever. The grace period comes from the
    // constitution, which is pinned on the proposal, so it cannot be relaxed
    // out from under an existing one by swapping strategies.
    function _isExpired(Proposal storage proposal) internal view returns (bool) {
        uint256 grace = IConstitution(constitution).executionGrace();
        if (grace == type(uint256).max) return false; // explicit opt-out

        uint256 deadline;
        unchecked {
            deadline = proposal.voteEnd + grace;
        }
        if (deadline < proposal.voteEnd) return false; // overflowed: never expires

        return block.timestamp > deadline;
    }

    function _runActions(
        uint256 proposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) internal {
        // set before the calls out, so a target cannot re-enter into a second
        // execution of the same proposal
        proposals[proposalId].executed = true;
        for (uint256 i = 0; i < targets.length; i++) {
            _execute(targets[i], values[i], calldatas[i]);
        }
        emit ProposalExecuted(proposalId, _msgSender());
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

    // the governor holds the treasury it votes over
    receive() external payable {}

    // ---------------------------------------------------------------
    // rescue
    // ---------------------------------------------------------------

    // token address(0) means ETH; amount type(uint256).max means the whole
    // balance, since the amount is fixed in actionHash while the balance is not
    function rescue(address token, address to, uint256 amount) external onlyGovernance {
        require(to != address(0), "cannot rescue to zero address");

        if (token == address(0)) {
            uint256 balance = address(this).balance;
            if (amount == type(uint256).max) {
                amount = balance;
            }
            require(amount <= balance, "insufficient balance");
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "eth rescue failed");
        } else {
            if (amount == type(uint256).max) {
                amount = IERC20(token).balanceOf(address(this));
            }
            SafeERC20.safeTransfer(IERC20(token), to, amount);
        }
    }

    // ---------------------------------------------------------------
    // voting  (unfinished)
    // ---------------------------------------------------------------

    function vote(uint256 proposalId, bool support) external {
        _castVote(proposalId, _msgSender(), support);
    }

    function _castVote(uint256 proposalId, address voter, bool support) internal {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp >= proposal.voteStart && block.timestamp <= proposal.voteEnd, "Voting is closed");
        require(!hasVoted[proposalId][voter], "Already voted");
        require(IConstitution(constitution).canVote(voter), "Cannot vote");
        hasVoted[proposalId][voter] = true;
        uint256 weight = IConstitution(constitution).getVotes(address(this), proposalId, voter);
        proposal.forVotes += support ? weight : 0;
        proposal.againstVotes += support ? 0 : weight;
        emit VoteCast(proposalId, voter, support, weight);
    }

    modifier onlyGovernance() {
        require(msg.sender == address(this), "only via executed proposal");
        _;
    }
}