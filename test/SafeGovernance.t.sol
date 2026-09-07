// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Governor, DelegateRegistration, FunctionAuthority, VotingParametersRegistration} from "../src/governance/Governer.sol";
import {Proposal, VotingParameters} from "../src/governance/interface/IGoverner.sol";
import {Council} from "../src/governance/constitution/council/council.sol";
import {ConstitutionRegistry} from "../src/governance/constitution/ConstitutionRegistry.sol";
import {SafeConstitution} from "../src/governance/constitution/safe/SafeConstitution.sol";
import {Owned} from "../src/governance/constitution/owned/owned.sol";
import {OwnedDelegate} from "../src/governance/delegate/OwnedDelegate.sol";
import {OwnedDelegateFactory} from "../src/governance/delegate/OwnedDelegateFactory.sol";

import {MockSafe} from "./mocks/MockSafe.sol";

// Same shape as the pool used in Governance.t.sol: an Ownable admin surface
// that only an executed proposal can reach.
contract MockPool is Ownable {
    uint256 public feeBps;

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        feeBps = _feeBps;
    }

    function withdrawTo(address payable to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }
}

abstract contract SafeGovernanceBase is Test {
    uint256 constant VOTING_PERIOD = 3 days;

    // "two thirds" as a ceiling-rounded bps: 6666 is the largest bps that still
    // means 2-of-3 (see the note in Governance.t.sol)
    uint16 constant TWO_THIRDS_BPS = 6666;

    // hub council
    address alice;
    uint256 alicePk;
    address bob;
    uint256 bobPk;
    address carol = makeAddr("carol");

    // Safe owners
    address dave;
    uint256 davePk;
    address erin;
    uint256 erinPk;
    address frank;
    uint256 frankPk;

    address relayer = makeAddr("relayer");
    address outsider = makeAddr("outsider");
    address payable treasury = payable(makeAddr("treasury"));

    MockSafe safe;

    function _initActors() internal {
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        (dave, davePk) = makeAddrAndKey("dave");
        (erin, erinPk) = makeAddrAndKey("erin");
        (frank, frankPk) = makeAddrAndKey("frank");

        address[] memory owners = new address[](3);
        owners[0] = dave;
        owners[1] = erin;
        owners[2] = frank;
        safe = new MockSafe(owners, 2); // 2-of-3
    }

    // ---------------------------------------------------------------
    // Safe signing helpers
    // ---------------------------------------------------------------

    // Safe requires the concatenated signatures to be ordered by strictly
    // ascending signer address, so sort before signing.
    function _safeSignatures(uint256[] memory pks, bytes32 dataHash) internal returns (bytes memory sigs) {
        for (uint256 i = 1; i < pks.length; i++) {
            uint256 key = pks[i];
            uint256 j = i;
            while (j > 0 && vm.addr(pks[j - 1]) > vm.addr(key)) {
                pks[j] = pks[j - 1];
                j--;
            }
            pks[j] = key;
        }
        for (uint256 i = 0; i < pks.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], dataHash);
            sigs = abi.encodePacked(sigs, r, s, v);
        }
    }

    // Runs `data` against `to` from the Safe's own address, once the threshold
    // of owners has signed the transaction.
    function _execFromSafe(address to, bytes memory data) internal {
        bytes32 txHash = safe.getTransactionHash(to, 0, data, safe.nonce());
        bytes memory sigs = _safeSignatures(_pks2(davePk, erinPk), txHash);
        vm.prank(relayer);
        safe.execTransaction(to, 0, data, sigs);
    }

    function _pks2(uint256 a, uint256 b) internal pure returns (uint256[] memory pks) {
        pks = new uint256[](2);
        pks[0] = a;
        pks[1] = b;
    }

    // ---------------------------------------------------------------
    // deployment helpers
    // ---------------------------------------------------------------

    function _deployCouncil(address[] memory members) internal returns (Council) {
        Council impl = new Council();
        bytes memory init = abi.encodeCall(
            Council.initialize,
            (address(this), TWO_THIRDS_BPS, TWO_THIRDS_BPS, VOTING_PERIOD, members)
        );
        return Council(address(new ERC1967Proxy(address(impl), init)));
    }

    function _hubCouncilMembers() internal view returns (address[] memory members) {
        members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
    }

    function _deployGovernor(address constitution, DelegateRegistration[] memory registrations)
        internal
        returns (Governor)
    {
        Governor impl = new Governor(address(0));
        bytes memory init = abi.encodeCall(
            Governor.initialize,
            (constitution, registrations, new VotingParametersRegistration[](0))
        );
        return Governor(payable(address(new ERC1967Proxy(address(impl), init))));
    }

    function _singleAction(address target, bytes memory data)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        calldatas[0] = data;
    }
}

// ===================================================================
// 1. A Safe as a delegate: the hub cannot execute without its sign-off
// ===================================================================
contract SafeDelegateTest is SafeGovernanceBase {
    Governor hub;
    MockPool pool;
    OwnedDelegate delegate;
    OwnedDelegateFactory factory;

    function setUp() public {
        _initActors();

        factory = new OwnedDelegateFactory(address(new OwnedDelegate()));

        // the adapter's address is deterministic in the Safe's, so the hub can
        // be wired to it in the same breath it is deployed
        delegate = OwnedDelegate(factory.deploy(address(safe)));

        pool = new MockPool(address(this));

        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(pool),
            delegate: address(delegate),
            selector: MockPool.withdrawTo.selector,
            authority: FunctionAuthority.Delegated
        });

        hub = _deployGovernor(address(_deployCouncil(_hubCouncilMembers())), registrations);
        pool.transferOwnership(address(hub));
        vm.deal(address(pool), 10 ether);
    }

    function _proposeWithdrawal()
        internal
        returns (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        (targets, values, calldatas) =
            _singleAction(address(pool), abi.encodeCall(MockPool.withdrawTo, (treasury, 1 ether)));
        vm.prank(alice);
        proposalId = hub.propose(targets, values, calldatas, keccak256("withdraw 1 ether"));
    }

    function _voteThrough(uint256 proposalId) internal {
        vm.prank(alice);
        hub.vote(proposalId, true);
        vm.prank(bob);
        hub.vote(proposalId, true);
    }

    function test_FactoryAddressIsDeterministicAndBoundToTheSafe() public {
        assertEq(factory.delegateFor(address(safe)), address(delegate));
        assertTrue(factory.isDeployed(address(safe)));
        assertEq(address(delegate.approver()), address(safe));
    }

    function test_ProposingMirrorsAnApprovalRequestOntoTheDelegate() public {
        (uint256 proposalId,,, bytes[] memory calldatas) = _proposeWithdrawal();

        (address mirroredHub, uint256 mirroredId, bytes32 actionHash,,) = delegate.requests(address(hub), proposalId);
        assertEq(mirroredHub, address(hub));
        assertEq(mirroredId, proposalId);
        assertEq(actionHash, hub.getProposal(proposalId).actionHash);
        assertGt(uint256(actionHash), 0);
        assertEq(calldatas.length, 1);
    }

    function test_SafeApprovesByExecutingTheCallItself() public {
        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposeWithdrawal();
        _voteThrough(proposalId);

        _execFromSafe(address(delegate), abi.encodeCall(OwnedDelegate.approveProposal, (address(hub), proposalId)));
        assertTrue(delegate.hasApproved(address(hub), proposalId));

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        hub.execute(proposalId, 0, targets, values, calldatas, keccak256("withdraw 1 ether"));
        assertEq(treasury.balance, 1 ether);
    }

    function test_RevertWhen_ExecutingWithoutSafeApproval() public {
        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposeWithdrawal();
        _voteThrough(proposalId);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("delegate approval missing");
        hub.execute(proposalId, 0, targets, values, calldatas, keccak256("withdraw 1 ether"));
        assertEq(treasury.balance, 0);
    }

    function test_RevertWhen_ApprovalCallerIsNotTheSafe() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();

        vm.prank(dave); // an owner of the Safe, but not the Safe
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, dave));
        delegate.approveProposal(address(hub), proposalId);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        delegate.approveProposal(address(hub), proposalId);
    }

    // approving an id the hub never mirrored would be signing a blank cheque:
    // the Safe can only ever attest to actions it has already been shown
    function test_RevertWhen_ApprovingAProposalThatWasNeverMirrored() public {
        // even a fully-signed Safe transaction cannot approve an unmirrored id
        bytes memory data = abi.encodeCall(OwnedDelegate.approveProposal, (address(hub), 12345));
        bytes32 txHash = safe.getTransactionHash(address(delegate), 0, data, safe.nonce());
        bytes memory sigs = _safeSignatures(_pks2(davePk, erinPk), txHash);

        vm.prank(relayer);
        vm.expectRevert("no approval request");
        safe.execTransaction(address(delegate), 0, data, sigs);

        assertFalse(delegate.hasApproved(address(hub), 12345));
    }

    function test_RevertWhen_MirroringActionsThatDoNotMatchTheHubProposal() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(pool), abi.encodeCall(MockPool.withdrawTo, (treasury, 9 ether)));

        OwnedDelegate fresh = OwnedDelegate(new OwnedDelegateFactory(address(new OwnedDelegate())).deploy(address(safe)));
        vm.expectRevert("actions do not match proposal");
        fresh.proposeApproval(address(hub), proposalId, targets, values, calldatas, keccak256("withdraw 1 ether"));
    }

    function test_ApprovalIsIdempotentAndKeepsItsOriginalTimestamp() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();

        _execFromSafe(address(delegate), abi.encodeCall(OwnedDelegate.approveProposal, (address(hub), proposalId)));
        (, uint256 firstTimestamp) = delegate.approvals(address(hub), proposalId);

        vm.warp(block.timestamp + 1 hours);
        _execFromSafe(address(delegate), abi.encodeCall(OwnedDelegate.approveProposal, (address(hub), proposalId)));

        (bool approved, uint256 secondTimestamp) = delegate.approvals(address(hub), proposalId);
        assertTrue(approved);
        assertEq(secondTimestamp, firstTimestamp);
    }

    function test_RevertWhen_DelegateIsAskedToOriginateAProposal() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(pool), abi.encodeCall(MockPool.setFeeBps, (100)));
        vm.expectRevert("OwnedDelegate: cannot originate proposals");
        delegate.propose(targets, values, calldatas, keccak256("d"));
    }

    function test_MirrorViewTracksHubTimingAndApprovalState() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();
        uint256 requestId = delegate.getRequestId(address(hub), proposalId);

        Proposal memory hubProposal = hub.getProposal(proposalId);
        Proposal memory mirrored = delegate.getProposal(requestId);
        assertEq(mirrored.voteEnd, hubProposal.voteEnd);
        assertEq(mirrored.actionHash, hubProposal.actionHash);
        assertEq(mirrored.proposer, address(hub));
        assertEq(mirrored.forVotes, 0);
        assertFalse(mirrored.executed);

        _execFromSafe(address(delegate), abi.encodeCall(OwnedDelegate.approveProposal, (address(hub), proposalId)));
        mirrored = delegate.getProposal(requestId);
        assertEq(mirrored.forVotes, 1);
        assertTrue(mirrored.executed);
    }

    function test_UnknownRequestIdReadsAsEmpty() public {
        Proposal memory mirrored = delegate.getProposal(999);
        assertEq(mirrored.voteStart, 0);
        assertEq(mirrored.actionHash, bytes32(0));
    }

    // an unrelated selector on the same target is untouched by the delegation
    function test_UndelegatedSelectorNeedsNoSafeApproval() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(pool), abi.encodeCall(MockPool.setFeeBps, (250)));

        vm.prank(alice);
        uint256 proposalId = hub.propose(targets, values, calldatas, keccak256("set fee"));
        _voteThrough(proposalId);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        hub.execute(proposalId, 0, targets, values, calldatas, keccak256("set fee"));
        assertEq(pool.feeBps(), 250);
    }
}

// ===================================================================
// 2. A Safe's owner set as the electorate
// ===================================================================
contract SafeConstitutionTest is SafeGovernanceBase {
    SafeConstitution constitution;
    Governor governor;
    MockPool pool;

    function setUp() public {
        _initActors();
        constitution = _deployConstitution(TWO_THIRDS_BPS, TWO_THIRDS_BPS);
        governor = _deployGovernor(address(constitution), new DelegateRegistration[](0));
        pool = new MockPool(address(governor));
    }

    function _deployConstitution(uint16 quorumBps, uint16 thresholdBps) internal returns (SafeConstitution) {
        SafeConstitution impl = new SafeConstitution();
        bytes memory init =
            abi.encodeCall(SafeConstitution.initialize, (address(safe), quorumBps, thresholdBps, VOTING_PERIOD));
        return SafeConstitution(address(new ERC1967Proxy(address(impl), init)));
    }

    function _proposeFee(Governor g, uint256 feeBps, address proposer)
        internal
        returns (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        (targets, values, calldatas) = _singleAction(address(pool), abi.encodeCall(MockPool.setFeeBps, (feeBps)));
        vm.prank(proposer);
        proposalId = g.propose(targets, values, calldatas, keccak256("set fee"));
    }

    function test_ElectorateIsReadOffTheSafe() public {
        assertEq(constitution.name(), "SafeConstitution");
        assertEq(constitution.totalOwners(), 3);
        assertTrue(constitution.canPropose(dave));
        assertTrue(constitution.canVote(frank));
        assertFalse(constitution.canVote(outsider));
        assertFalse(constitution.canPropose(outsider));
    }

    function test_OwnerCarriesOneVoteAndTheSafeCarriesItsThreshold() public {
        assertEq(constitution.getVotingPower(dave), 1);
        assertEq(constitution.getVotingPower(address(safe)), 2);
        assertEq(constitution.getVotingPower(outsider), 0);
    }

    function test_TwoOfThreeOwnersCanPassAProposal() public {
        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposeFee(governor, 300, dave);

        vm.prank(dave);
        governor.vote(proposalId, true);
        vm.prank(erin);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, keccak256("set fee"));
        assertEq(pool.feeBps(), 300);
    }

    // a Safe transaction has already cleared the threshold on-chain, so the
    // Safe voting as itself is sufficient on its own
    function test_SafeVotingAsItselfCarriesTheWholeThreshold() public {
        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposeFee(governor, 400, dave);

        _execFromSafe(address(governor), abi.encodeCall(Governor.vote, (proposalId, true)));
        assertEq(governor.getProposal(proposalId).forVotes, 2);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, keccak256("set fee"));
        assertEq(pool.feeBps(), 400);
    }

    function test_SafeCanProposeAsItself() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(pool), abi.encodeCall(MockPool.setFeeBps, (150)));

        _execFromSafe(
            address(governor),
            abi.encodeCall(Governor.propose, (targets, values, calldatas, keccak256("safe proposes")))
        );

        bytes32 actionHash = keccak256(abi.encode(targets, values, calldatas, keccak256("safe proposes")));
        uint256 proposalId = uint256(keccak256(abi.encode(address(governor), block.chainid, actionHash, uint256(0))));
        assertEq(governor.getProposal(proposalId).proposer, address(safe));
    }

    function test_RevertWhen_NonOwnerVotesOrProposes() public {
        (uint256 proposalId,,,) = _proposeFee(governor, 300, dave);

        vm.prank(outsider);
        vm.expectRevert("Cannot vote");
        governor.vote(proposalId, true);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(pool), abi.encodeCall(MockPool.setFeeBps, (1)));
        vm.prank(outsider);
        vm.expectRevert("Proposer not eligible");
        governor.propose(targets, values, calldatas, keccak256("x"));
    }

    // 3333 bps of 3 owners rounds to 1, but the Safe's own 2-of-3 threshold is
    // a floor: governance here can be stricter than the multisig, never looser
    function test_SafeThresholdIsAFloorOnTheExecuteThreshold() public {
        SafeConstitution loose = _deployConstitution(3333, 3333);
        assertEq(loose.getQuorum(3333), 1);
        assertEq(loose.getExecuteThreshold(3333), 2); // not 1

        Governor g = _deployGovernor(address(loose), new DelegateRegistration[](0));
        pool = new MockPool(address(g));

        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposeFee(g, 500, dave);

        vm.prank(dave);
        g.vote(proposalId, true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("Proposal did not pass");
        g.execute(proposalId, 0, targets, values, calldatas, keccak256("set fee"));
    }

    // The documented cost of reading the owner set live instead of
    // checkpointing it: adding an owner mid-vote raises the bar retroactively.
    function test_AddingAnOwnerMidVoteRaisesTheBar() public {
        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposeFee(governor, 600, dave);

        vm.prank(dave);
        governor.vote(proposalId, true);
        vm.prank(erin);
        governor.vote(proposalId, true);
        assertTrue(constitution.hasPassed(address(governor), proposalId)); // 2 of 3

        safe.addOwnerWithThreshold(makeAddr("grace"), 2);
        assertEq(constitution.getExecuteThreshold(TWO_THIRDS_BPS), 3); // 2 of 4 no longer enough
        assertFalse(constitution.hasPassed(address(governor), proposalId));

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("Proposal did not pass");
        governor.execute(proposalId, 0, targets, values, calldatas, keccak256("set fee"));
    }

    function test_OnlyTheSafeCanRetuneDefaultVotingParameters() public {
        vm.prank(dave);
        vm.expectRevert("only the safe");
        constitution.setDefaultVotingParameters(5000, 5000, 1 days);

        _execFromSafe(
            address(constitution),
            abi.encodeCall(SafeConstitution.setDefaultVotingParameters, (5000, 5000, 1 days))
        );
        VotingParameters memory params = constitution.getDefaultVotingParameters();
        assertEq(params.quorumBps, 5000);
        assertEq(params.votingPeriod, 1 days);
    }

    function test_DeployableThroughTheConstitutionRegistry() public {
        ConstitutionRegistry registry = new ConstitutionRegistry(address(this));
        registry.registerConstitution(7, address(new SafeConstitution()));

        address instance = registry.deployConstitution(
            7,
            abi.encodeCall(
                SafeConstitution.initialize, (address(safe), TWO_THIRDS_BPS, TWO_THIRDS_BPS, VOTING_PERIOD)
            )
        );

        // the initializer ran with the registry as msg.sender, yet control sits
        // with the Safe, because the Safe is a parameter not a caller
        assertEq(address(SafeConstitution(instance).safe()), address(safe));
        vm.prank(address(registry));
        vm.expectRevert("only the safe");
        SafeConstitution(instance).setDefaultVotingParameters(1, 1, 1);
    }

    function test_RevertWhen_InitializedWithANonContractSafe() public {
        SafeConstitution impl = new SafeConstitution();
        bytes memory init =
            abi.encodeCall(SafeConstitution.initialize, (outsider, TWO_THIRDS_BPS, TWO_THIRDS_BPS, VOTING_PERIOD));
        vm.expectRevert("safe is not a contract");
        new ERC1967Proxy(address(impl), init);
    }
}

// ===================================================================
// A Safe as the owner of an Owned constitution
//
// The other way to put a Safe in charge, and the simpler one: rather than
// SafeConstitution reading the owner set, `Owned` just names the Safe as its
// single owner. The Safe executes propose, msg.sender is the Safe, the
// constitution says that settles it, and the action runs -- one Safe
// transaction end to end. Worth its own coverage because every other Owned test
// uses an EOA owner, and a contract owner exercises a different path.
// ===================================================================
contract SafeAsOwnedOwnerTest is SafeGovernanceBase {
    Owned constitution;
    Governor governor;
    MockPool pool;

    function setUp() public {
        _initActors();
        constitution = _deployOwnedFor(address(safe));
        governor = _deployGovernor(address(constitution), new DelegateRegistration[](0));
        pool = new MockPool(address(governor));
    }

    function _deployOwnedFor(address owner) internal returns (Owned) {
        Owned impl = new Owned();
        return Owned(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(Owned.initialize, (owner, VOTING_PERIOD))))
        );
    }

    function _proposalIdFor(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash,
        uint256 nounce
    ) internal view returns (uint256) {
        bytes32 actionHash = keccak256(abi.encode(targets, values, calldatas, descriptionHash));
        return uint256(keccak256(abi.encode(address(governor), block.chainid, actionHash, nounce)));
    }

    function test_TheSafeIsTheOwner() public {
        assertEq(constitution.owner(), address(safe));
        assertTrue(constitution.canPropose(address(safe)));
        assertFalse(constitution.canPropose(dave)); // a Safe owner, but not the Safe
    }

    // the headline: owners confirm one Safe transaction and the action lands
    function test_SafeProposesAndExecutesInOneSafeTransaction() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(pool), abi.encodeCall(MockPool.setFeeBps, (275)));
        bytes32 descriptionHash = keccak256("safe sets fee");
        uint256 proposalId = _proposalIdFor(targets, values, calldatas, descriptionHash, 0);

        _execFromSafe(
            address(governor),
            abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash))
        );

        assertEq(pool.feeBps(), 275);
        Proposal memory p = governor.getProposal(proposalId);
        assertEq(p.proposer, address(safe));
        assertTrue(p.executed);
        assertEq(p.forVotes, 0); // settled by who proposed it, no ballot forged
        assertFalse(governor.hasVoted(proposalId, address(safe)));
    }

    // an individual owner acting in their own name is not the Safe
    function test_RevertWhen_ASafeOwnerActsWithoutTheMultisig() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(pool), abi.encodeCall(MockPool.setFeeBps, (999)));

        vm.prank(dave);
        vm.expectRevert("Proposer not eligible");
        governor.propose(targets, values, calldatas, keccak256("solo"));
        assertEq(pool.feeBps(), 0);
    }

    // below-threshold owners cannot make the Safe act either
    function test_RevertWhen_SafeTransactionIsUnderThreshold() public {
        bytes memory data = abi.encodeCall(
            Governor.propose,
            (
                _targets(),
                _values(),
                _calldatas(500),
                keccak256("under threshold")
            )
        );
        bytes32 txHash = safe.getTransactionHash(address(governor), 0, data, safe.nonce());

        uint256[] memory single = new uint256[](1);
        single[0] = davePk;
        bytes memory sigs = _safeSignatures(single, txHash);

        vm.prank(relayer);
        vm.expectRevert(bytes("GS020"));
        safe.execTransaction(address(governor), 0, data, sigs);
        assertEq(pool.feeBps(), 0);
    }

    // a contract owner has to accept ownership the same way an EOA does
    function test_OwnershipMovesFromTheSafeToAnotherOwner() public {
        address successor = makeAddr("successor");

        _execFromSafe(address(constitution), abi.encodeCall(Ownable2Step.transferOwnership, (successor)));
        assertEq(constitution.owner(), address(safe)); // not yet
        assertEq(constitution.pendingOwner(), successor);

        vm.prank(successor);
        constitution.acceptOwnership();
        assertEq(constitution.owner(), successor);

        // and the Safe is now powerless over this governor
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(pool), abi.encodeCall(MockPool.setFeeBps, (1)));
        vm.prank(address(safe));
        vm.expectRevert("Proposer not eligible");
        governor.propose(targets, values, calldatas, keccak256("late grab"));
    }

    // a Safe owner is still subject to a delegated veto
    function test_DelegatedSelectorStillDefersForASafeOwner() public {
        address vetoHolder = makeAddr("vetoHolder");
        OwnedDelegateFactory factory = new OwnedDelegateFactory(address(new OwnedDelegate()));
        OwnedDelegate delegate = OwnedDelegate(factory.deploy(vetoHolder));

        MockPool gated = new MockPool(address(this));
        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(gated),
            delegate: address(delegate),
            selector: MockPool.withdrawTo.selector,
            authority: FunctionAuthority.Delegated
        });

        Owned c = _deployOwnedFor(address(safe));
        Governor g = _deployGovernor(address(c), registrations);
        gated.transferOwnership(address(g));
        vm.deal(address(gated), 10 ether);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(gated), abi.encodeCall(MockPool.withdrawTo, (treasury, 1 ether)));
        bytes32 descriptionHash = keccak256("withdraw");

        bytes32 actionHash = keccak256(abi.encode(targets, values, calldatas, descriptionHash));
        uint256 proposalId = uint256(keccak256(abi.encode(address(g), block.chainid, actionHash, uint256(0))));

        _execFromSafe(
            address(g), abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash))
        );

        assertFalse(g.getProposal(proposalId).executed);
        assertEq(treasury.balance, 0);

        vm.prank(vetoHolder);
        delegate.approveProposal(address(g), proposalId);

        g.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
        assertEq(treasury.balance, 1 ether);
    }

    function _targets() internal view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(pool);
    }

    function _values() internal pure returns (uint256[] memory v) {
        v = new uint256[](1);
    }

    function _calldatas(uint256 feeBps) internal pure returns (bytes[] memory c) {
        c = new bytes[](1);
        c[0] = abi.encodeCall(MockPool.setFeeBps, (feeBps));
    }
}
