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
import {Owned} from "../src/governance/constitution/owned/owned.sol";

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

abstract contract ExternalGovernanceBase is Test {
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

    // A veto holder is an ordinary Governor whose constitution names the holder.
    // No adapter: a Governor already implements IGoverner, so it drops straight
    // into a delegate slot.
    function _deployVetoSpoke(address holder) internal returns (Governor) {
        Owned impl = new Owned();
        Owned c = Owned(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(Owned.initialize, (holder, VOTING_PERIOD))))
        );
        return _deployGovernor(address(c), new DelegateRegistration[](0));
    }

    // the Safe signing off: one Safe transaction casts the spoke's ballot, and
    // executing the approval afterwards is permissionless
    function _safeApprovesVia(Governor spoke, address hub, uint256 hubProposalId) internal {
        uint256 childId = spoke.approvalProposalId(hub, hubProposalId);
        require(childId != 0, "spoke was never asked to approve");

        _execFromSafe(address(spoke), abi.encodeCall(Governor.vote, (childId, true)));

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _singleAction(address(spoke), abi.encodeWithSelector(spoke.approveProposal.selector, hub, hubProposalId));
        spoke.execute(
            childId, spoke.getProposal(childId).nounce, t, v, c,
            keccak256(abi.encode("approval", hub, hubProposalId))
        );
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
contract ExternalVetoHolderTest is ExternalGovernanceBase {
    Governor hub;
    Governor spoke; // the Safe's veto, expressed as a governor it owns
    MockPool pool;

    function setUp() public {
        _initActors();

        spoke = _deployVetoSpoke(address(safe));
        pool = new MockPool(address(this));

        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(pool),
            delegate: address(spoke),
            selector: MockPool.withdrawTo.selector,
            authority: FunctionAuthority.Hard
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

    function test_TheSafeIsTheVetoHolderThroughItsSpoke() public {
        assertEq(Owned(spoke.constitution()).owner(), address(safe));
        assertTrue(Owned(spoke.constitution()).canVote(address(safe)));
        assertFalse(Owned(spoke.constitution()).canVote(dave)); // an owner, not the Safe
    }

    function test_ProposingAsksTheSpokeForApproval() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();

        uint256 childId = spoke.approvalProposalId(address(hub), proposalId);
        assertTrue(childId != 0, "the spoke was never asked");
        assertEq(
            spoke.getProposal(childId).descriptionHash,
            keccak256(abi.encode("approval", address(hub), proposalId))
        );
        assertEq(hub.delegates(proposalId, 0), address(spoke));
    }

    function test_SafeApprovesThroughItsSpoke() public {
        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposeWithdrawal();
        _voteThrough(proposalId);

        _safeApprovesVia(spoke, address(hub), proposalId);
        assertTrue(spoke.hasApproved(address(hub), proposalId));

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

    // an individual Safe owner is not the Safe, and the spoke knows it
    function test_RevertWhen_ASafeOwnerVotesInTheirOwnName() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();
        uint256 childId = spoke.approvalProposalId(address(hub), proposalId);

        vm.prank(dave);
        vm.expectRevert("Cannot vote");
        spoke.vote(childId, true);

        vm.prank(outsider);
        vm.expectRevert("Cannot vote");
        spoke.vote(childId, true);
    }

    // the veto holder can only ever be asked about actions the hub really
    // proposed -- the same validation an adapter did, native to the governor
    function test_RevertWhen_MirroringActionsThatDoNotMatchTheHubProposal() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _singleAction(address(pool), abi.encodeCall(MockPool.withdrawTo, (treasury, 9 ether)));

        Governor fresh = _deployVetoSpoke(address(safe));
        vm.expectRevert("actions do not match proposal");
        fresh.proposeApproval(address(hub), proposalId, targets, values, calldatas, keccak256("withdraw 1 ether"));
    }

    function test_ProposeApprovalIsIdempotent() public {
        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposeWithdrawal();

        uint256 first = spoke.approvalProposalId(address(hub), proposalId);
        uint256 again = spoke.proposeApproval(
            address(hub), proposalId, targets, values, calldatas, keccak256("withdraw 1 ether")
        );
        assertEq(again, first, "asking twice must not mint a second approval proposal");
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
// An external governance protocol as the owner
//
// How any outside system takes charge: `Owned` names it as the single owner, it
// executes propose, msg.sender is that system, the constitution says that
// settles it, and the action runs. A Gnosis Safe stands in for the general case
// here because it settles its own consent before calling -- which is the only
// thing the protocol requires of it, and is why no Safe-specific code exists.
// Worth its own coverage because every other Owned test uses an EOA owner, and
// a contract owner exercises a different path.
// ===================================================================
contract ExternalOwnerTest is ExternalGovernanceBase {
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
        Governor delegate = _deployVetoSpoke(vetoHolder);

        MockPool gated = new MockPool(address(this));
        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(gated),
            delegate: address(delegate),
            selector: MockPool.withdrawTo.selector,
            authority: FunctionAuthority.Hard
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

        uint256 childId = delegate.approvalProposalId(address(g), proposalId);
        vm.prank(vetoHolder);
        delegate.vote(childId, true);
        (address[] memory at, uint256[] memory av, bytes[] memory ac) = _singleAction(
            address(delegate), abi.encodeWithSelector(delegate.approveProposal.selector, address(g), proposalId)
        );
        delegate.execute(
            childId, delegate.getProposal(childId).nounce, at, av, ac,
            keccak256(abi.encode("approval", address(g), proposalId))
        );

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
