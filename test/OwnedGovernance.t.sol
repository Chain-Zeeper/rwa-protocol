// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Governor, DelegateRegistration, FunctionAuthority, VotingParametersRegistration} from "../src/governance/Governer.sol";
import {Proposal, VotingParameters} from "../src/governance/interface/IGoverner.sol";
import {Council} from "../src/governance/constitution/council/council.sol";
import {Owned} from "../src/governance/constitution/owned/owned.sol";
import {ConstitutionRegistry} from "../src/governance/constitution/ConstitutionRegistry.sol";
import {OwnedDelegate} from "../src/governance/delegate/OwnedDelegate.sol";
import {OwnedDelegateFactory} from "../src/governance/delegate/OwnedDelegateFactory.sol";

contract AdminPool is Ownable {
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

abstract contract OwnedGovernanceBase is Test {
    uint256 constant VOTING_PERIOD = 3 days;
    uint16 constant TWO_THIRDS_BPS = 6666;

    address admin = makeAddr("admin");
    address outsider = makeAddr("outsider");
    address payable treasury = payable(makeAddr("treasury"));

    function _deployOwned(address owner) internal returns (Owned) {
        Owned impl = new Owned();
        return Owned(address(new ERC1967Proxy(address(impl), abi.encodeCall(Owned.initialize, (owner, VOTING_PERIOD)))));
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

    function _deployCouncilWith(address[] memory members, uint256 votingPeriod) internal returns (Council) {
        Council impl = new Council();
        return Council(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        Council.initialize, (address(this), TWO_THIRDS_BPS, TWO_THIRDS_BPS, votingPeriod, members)
                    )
                )
            )
        );
    }

    function _action(address target, bytes memory data)
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
// An owned governor: Ownable ergonomics, proposal machinery underneath
// ===================================================================
contract OwnedConstitutionTest is OwnedGovernanceBase {
    Owned constitution;
    Governor governor;
    AdminPool pool;

    function setUp() public {
        constitution = _deployOwned(admin);
        governor = _deployGovernor(address(constitution), new DelegateRegistration[](0));
        pool = new AdminPool(address(governor));
    }

    function test_ElectorateIsExactlyTheOwner() public {
        assertEq(constitution.name(), "Owned");
        assertEq(constitution.owner(), admin);
        assertTrue(constitution.canPropose(admin));
        assertTrue(constitution.canVote(admin));
        assertEq(constitution.getVotingPower(admin), 1);
        assertFalse(constitution.canPropose(outsider));
        assertEq(constitution.getVotingPower(outsider), 0);
    }

    // the headline: one transaction in, effect out -- no waiting, no second call
    function test_OwnerProposesVotesAndExecutesInOneTransaction() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (250)));

        vm.prank(admin);
        uint256 proposalId = governor.propose(targets, values, calldatas, keccak256("set fee"));

        assertEq(pool.feeBps(), 250);
        assertTrue(governor.getProposal(proposalId).executed);
    }

    // ...but it is still a proposal, with a trail Ownable cannot give you
    function test_OwnedActionStillLeavesAFullProposalTrail() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (250)));
        bytes32 descriptionHash = keccak256("set fee to 2.5%");

        vm.prank(admin);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);

        Proposal memory p = governor.getProposal(proposalId);
        assertEq(p.proposer, admin);
        assertEq(p.forVotes, 0); // settled by who proposed it, not by a ballot
        assertTrue(p.executed);
        assertEq(p.descriptionHash, descriptionHash);
        assertEq(p.actionHash, keccak256(abi.encode(targets, values, calldatas, descriptionHash)));
    }

    // the owner filing a proposal already settles it -- no ballot is cast on
    // their behalf, the constitution simply has nobody else to hear from
    function test_ProposeSettlesAndExecutesWithoutCastingABallot() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (400)));

        vm.prank(admin);
        uint256 proposalId = governor.propose(targets, values, calldatas, keccak256("set fee"));

        assertFalse(governor.hasVoted(proposalId, admin)); // no ballot was forged for them
        assertTrue(governor.getProposal(proposalId).executed);
        assertFalse(governor.canExecuteNow(proposalId)); // already executed
        assertEq(pool.feeBps(), 400);
    }

    function test_RevertWhen_ReExecutingAnAlreadySettledProposal() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (400)));

        vm.prank(admin);
        uint256 proposalId = governor.propose(targets, values, calldatas, keccak256("set fee"));

        vm.expectRevert("Proposal already executed");
        governor.execute(proposalId, 0, targets, values, calldatas, keccak256("set fee"));
    }

    function test_RevertWhen_OutsiderProposes() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (1)));

        vm.prank(outsider);
        vm.expectRevert("Proposer not eligible");
        governor.propose(targets, values, calldatas, keccak256("x"));
    }

    function test_RevertWhen_OutsiderVotes() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (1)));
        vm.prank(admin);
        uint256 proposalId = governor.propose(targets, values, calldatas, keccak256("x"));

        vm.prank(outsider);
        vm.expectRevert("Cannot vote");
        governor.vote(proposalId, true);
    }

    function test_OwnedGovernorCanReachItsOwnGovernanceSurface() public {
        Owned replacement = _deployOwned(admin);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _action(
            address(governor), abi.encodeCall(Governor.changeConstitutionalStrategy, (address(replacement)))
        );

        vm.prank(admin);
        governor.propose(targets, values, calldatas, keccak256("swap constitution"));

        assertEq(governor.constitution(), address(replacement));
    }

    // progressive decentralisation without a migration: the governor's address
    // never changes, so the pool it owns needs no re-pointing
    function test_HandingOverToACouncilKeepsTheGovernorAddress() public {
        address[] memory members = new address[](3);
        members[0] = makeAddr("m1");
        members[1] = makeAddr("m2");
        members[2] = makeAddr("m3");
        Council councilImpl = new Council();
        Council council = Council(
            address(
                new ERC1967Proxy(
                    address(councilImpl),
                    abi.encodeCall(
                        Council.initialize, (address(this), TWO_THIRDS_BPS, TWO_THIRDS_BPS, VOTING_PERIOD, members)
                    )
                )
            )
        );

        address governorAddress = address(governor);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _action(address(governor), abi.encodeCall(Governor.changeConstitutionalStrategy, (address(council))));

        vm.prank(admin);
        governor.propose(targets, values, calldatas, keccak256("decentralise"));

        assertEq(address(governor), governorAddress);
        assertEq(pool.owner(), governorAddress);
        assertEq(governor.constitution(), address(council));

        // and the old owner is now powerless
        (targets, values, calldatas) = _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (900)));
        vm.prank(admin);
        vm.expectRevert("Proposer not eligible");
        governor.propose(targets, values, calldatas, keccak256("late grab"));
    }

    // ---------------------------------------------------------------
    // ownership
    // ---------------------------------------------------------------

    function test_TwoStepOwnershipTransfer() public {
        address successor = makeAddr("successor");

        vm.prank(admin);
        constitution.transferOwnership(successor);
        assertEq(constitution.owner(), admin); // not yet
        assertEq(constitution.pendingOwner(), successor);

        vm.prank(successor);
        constitution.acceptOwnership();
        assertEq(constitution.owner(), successor);
        assertEq(constitution.pendingOwner(), address(0));

        assertTrue(constitution.canPropose(successor));
        assertFalse(constitution.canPropose(admin));
    }

    function test_RevertWhen_WrongAccountAcceptsOwnership() public {
        vm.prank(admin);
        constitution.transferOwnership(makeAddr("successor"));

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        constitution.acceptOwnership();
    }

    function test_RevertWhen_OutsiderTransfersOwnershipOrRetunesPeriod() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        constitution.transferOwnership(outsider);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        constitution.setVotingPeriod(1 days);
    }

    // an owned governor with no owner could never execute anything again,
    // including the proposal that would install a new constitution
    function test_RevertWhen_RenouncingOwnership() public {
        vm.prank(admin);
        vm.expectRevert("use transferOwnership");
        constitution.renounceOwnership();
    }

    function test_DeployableThroughTheConstitutionRegistry() public {
        ConstitutionRegistry registry = new ConstitutionRegistry(address(this));
        registry.registerConstitution(3, address(new Owned()));

        address instance = registry.deployConstitution(3, abi.encodeCall(Owned.initialize, (admin, VOTING_PERIOD)));

        // initialised by the registry, yet owned by admin -- owner is a
        // parameter, not the caller
        assertEq(Owned(instance).owner(), admin);
        vm.prank(address(registry));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(registry)));
        Owned(instance).transferOwnership(outsider);
    }

    function test_RevertWhen_InitializedWithZeroOwner() public {
        Owned impl = new Owned();
        vm.expectRevert("zero owner");
        new ERC1967Proxy(address(impl), abi.encodeCall(Owned.initialize, (address(0), VOTING_PERIOD)));
    }
}

// ===================================================================
// An owner is still subject to delegated vetoes
// ===================================================================
contract OwnedWithDelegateTest is OwnedGovernanceBase {
    Owned constitution;
    Governor governor;
    AdminPool pool;
    OwnedDelegate delegate;

    address vetoHolder;
    uint256 vetoHolderPk;

    function setUp() public {
        (vetoHolder, vetoHolderPk) = makeAddrAndKey("vetoHolder");

        OwnedDelegateFactory factory = new OwnedDelegateFactory(address(new OwnedDelegate()));
        delegate = OwnedDelegate(factory.deploy(vetoHolder));

        constitution = _deployOwned(admin);
        pool = new AdminPool(address(this));

        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(pool),
            delegate: address(delegate),
            selector: AdminPool.withdrawTo.selector,
            authority: FunctionAuthority.Delegated
        });

        governor = _deployGovernor(address(constitution), registrations);
        pool.transferOwnership(address(governor));
        vm.deal(address(pool), 10 ether);
    }

    function _proposeWithdrawal()
        internal
        returns (uint256 proposalId, address[] memory t, uint256[] memory v, bytes[] memory c)
    {
        (t, v, c) = _action(address(pool), abi.encodeCall(AdminPool.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        proposalId = governor.propose(t, v, c, keccak256("withdraw"));
    }

    // the whole point of delegation: even an owner cannot fast-path past it
    function test_OwnerCannotExecuteADelegatedSelectorImmediately() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();

        assertFalse(governor.getProposal(proposalId).executed);
        assertEq(treasury.balance, 0);
        assertFalse(governor.canExecuteNow(proposalId));
        assertEq(governor.delegates(proposalId, 0), address(delegate));
    }

    // and it must not revert: reverting would roll back the proposeApproval
    // call, so the veto-holder would never learn the proposal exists
    function test_TheDelegateIsStillNotifiedWhenExecutionIsDeferred() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();

        (address mirroredHub, uint256 mirroredId, bytes32 actionHash,,) = delegate.requests(address(governor), proposalId);
        assertEq(mirroredHub, address(governor));
        assertEq(mirroredId, proposalId);
        assertEq(actionHash, governor.getProposal(proposalId).actionHash);
    }

    // once the veto-holder signs off there is still no timer to serve
    function test_ExecutesImmediatelyAfterTheApproverSignsOff() public {
        (uint256 proposalId, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        vm.prank(vetoHolder);
        delegate.approveProposal(address(governor), proposalId);

        assertTrue(governor.canExecuteNow(proposalId)); // no warp
        governor.execute(proposalId, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    function test_RevertWhen_ApprovalCallerIsNotTheApprover() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        delegate.approveProposal(address(governor), proposalId);
    }

    // Ownable2Step on the adapter means the veto-holder can be replaced in
    // place. Without it a compromised or retired approver would force a fresh
    // adapter plus a governance proposal on every hub that registered the old
    // one -- the adapter's address is what hubs point at, and it does not move.
    function test_VetoHolderCanBeRotatedWithoutReRegisteringTheAdapter() public {
        address successor = makeAddr("successor");
        address adapterAddress = address(delegate);

        vm.prank(vetoHolder);
        delegate.transferOwnership(successor);
        assertEq(delegate.approver(), vetoHolder); // two-step: not yet

        vm.prank(successor);
        delegate.acceptOwnership();
        assertEq(delegate.approver(), successor);
        assertEq(address(delegate), adapterAddress); // hubs still point here

        (uint256 proposalId, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        vm.prank(vetoHolder); // the retired holder has no say any more
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, vetoHolder));
        delegate.approveProposal(address(governor), proposalId);

        vm.prank(successor);
        delegate.approveProposal(address(governor), proposalId);

        governor.execute(proposalId, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    // an adapter with no approver would block every hub that registered it,
    // permanently and with no route back
    function test_RevertWhen_RenouncingTheVeto() public {
        vm.prank(vetoHolder);
        vm.expectRevert("use transferOwnership");
        delegate.renounceOwnership();
    }

    // undelegated selectors on the same target keep the one-transaction path
    function test_UndelegatedSelectorStillExecutesInOneTransaction() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (125)));

        vm.prank(admin);
        governor.propose(t, v, c, keccak256("set fee"));

        assertEq(pool.feeBps(), 125);
    }
}

// ===================================================================
// Electorates with a real turnout period are unaffected
// ===================================================================
contract CouncilStillWaitsTest is OwnedGovernanceBase {
    Council council;
    Governor governor;
    AdminPool pool;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;

        Council impl = new Council();
        council = Council(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        Council.initialize, (address(this), TWO_THIRDS_BPS, TWO_THIRDS_BPS, VOTING_PERIOD, members)
                    )
                )
            )
        );
        governor = _deployGovernor(address(council), new DelegateRegistration[](0));
        pool = new AdminPool(address(governor));
    }

    function test_CouncilRefusesEarlyExecution() public {
        assertFalse(council.canExecuteEarly(address(governor), 0));
    }

    // a council votes over a period by design, so the deadline still stands
    // even once the threshold is met
    function test_MeetingTheThresholdEarlyDoesNotUnlockExecution() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (300)));

        vm.prank(alice);
        uint256 proposalId = governor.propose(t, v, c, keccak256("set fee"));
        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);

        // Council.hasPassed reads a membership checkpoint strictly before now,
        // so it cannot be asked in the block the proposal was created in
        vm.warp(block.timestamp + 1);
        assertTrue(council.hasPassed(address(governor), proposalId));

        // canExecuteNow never reaches that call: Council.canExecuteEarly is
        // false, so it short-circuits while voting is still open
        assertFalse(governor.canExecuteNow(proposalId)); // passed, but not yet due

        vm.expectRevert("Voting still open");
        governor.execute(proposalId, 0, t, v, c, keccak256("set fee"));

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertTrue(governor.canExecuteNow(proposalId));
        governor.execute(proposalId, 0, t, v, c, keccak256("set fee"));
        assertEq(pool.feeBps(), 300);
    }

    // a council proposal still needs its electorate; propose just cannot
    // short-circuit here
    function test_ProposeFallsBackToTheNormalPathForACouncil() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (300)));

        vm.prank(alice);
        uint256 proposalId = governor.propose(t, v, c, keccak256("set fee"));

        assertFalse(governor.getProposal(proposalId).executed);
        assertEq(pool.feeBps(), 0);

        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, t, v, c, keccak256("set fee"));
        assertEq(pool.feeBps(), 300);
    }
}

// ===================================================================
// An owned hub whose veto-holder is a whole council
//
// The realistic RWA shape: an issuer admin runs day-to-day governance, but
// anything touching investor funds needs sign-off from a council that votes on
// its own clock. Exercises an Owned hub against a Governor spoke rather than
// the single-approver OwnedDelegate.
// ===================================================================
contract OwnedWithCouncilSpokeTest is OwnedGovernanceBase {
    uint256 constant SPOKE_PERIOD = 7 days;

    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank");

    Owned constitution;
    Governor hub;
    Governor spoke;
    AdminPool pool;

    function setUp() public {
        address[] memory members = new address[](3);
        members[0] = dave;
        members[1] = erin;
        members[2] = frank;
        spoke = _deployGovernor(
            address(_deployCouncilWith(members, SPOKE_PERIOD)), new DelegateRegistration[](0)
        );

        constitution = _deployOwned(admin);
        pool = new AdminPool(address(this));

        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(pool),
            delegate: address(spoke),
            selector: AdminPool.withdrawTo.selector,
            authority: FunctionAuthority.Delegated
        });

        hub = _deployGovernor(address(constitution), registrations);
        pool.transferOwnership(address(hub));
        vm.deal(address(pool), 10 ether);
    }

    function _proposeWithdrawal()
        internal
        returns (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c)
    {
        (t, v, c) = _action(address(pool), abi.encodeCall(AdminPool.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        id = hub.propose(t, v, c, keccak256("withdraw"));
    }

    function _councilApproves(uint256 hubProposalId) internal {
        uint256 spokeId = spoke.approvalProposalId(address(hub), hubProposalId);
        require(spokeId != 0, "spoke was never asked");

        vm.prank(dave);
        spoke.vote(spokeId, true);
        vm.prank(erin);
        spoke.vote(spokeId, true);

        vm.warp(block.timestamp + SPOKE_PERIOD + 1);

        (address[] memory st, uint256[] memory sv, bytes[] memory sc) = _action(
            address(spoke), abi.encodeWithSelector(spoke.approveProposal.selector, address(hub), hubProposalId)
        );
        spoke.execute(
            spokeId, 0, st, sv, sc, keccak256(abi.encode("approval", address(hub), hubProposalId))
        );
    }

    function test_OwnerCannotFastPathPastACouncilVeto() public {
        (uint256 id,,,) = _proposeWithdrawal();

        assertFalse(hub.getProposal(id).executed);
        assertEq(treasury.balance, 0);
        assertEq(hub.delegates(id, 0), address(spoke));
    }

    // the hub's own 3-day period would have closed long before the council's
    // 7-day one; _propose stretches it to cover the spoke
    function test_OwnedHubStretchesItsDeadlineToCoverTheCouncil() public {
        uint256 start = block.timestamp;
        (uint256 id,,,) = _proposeWithdrawal();

        assertEq(hub.getProposal(id).voteEnd, start + SPOKE_PERIOD);
    }

    function test_ExecutesOnceTheCouncilHasSignedOff() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        _councilApproves(id);
        assertTrue(spoke.hasApproved(address(hub), id));

        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    // the council can simply decline: the owner has no way around it
    function test_RevertWhen_TheCouncilNeverApproves() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        vm.warp(block.timestamp + SPOKE_PERIOD + 1);
        vm.expectRevert("delegate approval missing");
        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 0);
    }

    // undelegated actions keep the one-call path even with a spoke configured
    function test_UndelegatedActionStillExecutesOnPropose() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (75)));

        vm.prank(admin);
        hub.propose(t, v, c, keccak256("set fee"));
        assertEq(pool.feeBps(), 75);
    }
}

// ===================================================================
// An owned hub answering to two different veto-holders at once
//
// A wildcard OwnedDelegate covering every call to the pool, plus a council
// spoke on the withdrawal selector specifically. Both must sign off.
// ===================================================================
contract OwnedWithTwoDelegatesTest is OwnedGovernanceBase {
    bytes4 constant ANY_SELECTOR = 0xffffffff;
    uint256 constant SPOKE_PERIOD = 5 days;

    address vetoHolder = makeAddr("vetoHolder");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank");

    Governor hub;
    Governor spoke;
    OwnedDelegate wildcard;
    AdminPool pool;

    function setUp() public {
        address[] memory members = new address[](3);
        members[0] = dave;
        members[1] = erin;
        members[2] = frank;
        spoke = _deployGovernor(
            address(_deployCouncilWith(members, SPOKE_PERIOD)), new DelegateRegistration[](0)
        );

        wildcard = OwnedDelegate(new OwnedDelegateFactory(address(new OwnedDelegate())).deploy(vetoHolder));

        pool = new AdminPool(address(this));

        DelegateRegistration[] memory registrations = new DelegateRegistration[](2);
        registrations[0] = DelegateRegistration({
            target: address(pool),
            delegate: address(wildcard),
            selector: ANY_SELECTOR,
            authority: FunctionAuthority.Delegated
        });
        registrations[1] = DelegateRegistration({
            target: address(pool),
            delegate: address(spoke),
            selector: AdminPool.withdrawTo.selector,
            authority: FunctionAuthority.Delegated
        });

        hub = _deployGovernor(address(_deployOwned(admin)), registrations);
        pool.transferOwnership(address(hub));
        vm.deal(address(pool), 10 ether);
    }

    function _proposeWithdrawal()
        internal
        returns (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c)
    {
        (t, v, c) = _action(address(pool), abi.encodeCall(AdminPool.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        id = hub.propose(t, v, c, keccak256("withdraw"));
    }

    function test_BothVetoHoldersAreRecordedAndNotified() public {
        (uint256 id,,,) = _proposeWithdrawal();

        assertEq(hub.delegates(id, 0), address(spoke));
        assertEq(hub.delegates(id, 1), address(wildcard));

        (,, bytes32 mirrored,,) = wildcard.requests(address(hub), id);
        assertEq(mirrored, hub.getProposal(id).actionHash);
        assertTrue(spoke.approvalProposalId(address(hub), id) != 0);
    }

    function test_RevertWhen_OnlyOneVetoHolderApproves() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        vm.prank(vetoHolder);
        wildcard.approveProposal(address(hub), id);

        assertFalse(hub.canExecuteNow(id));
        vm.expectRevert("delegate approval missing");
        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 0);
    }

    function test_ExecutesOnlyAfterBothApprove() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        vm.prank(vetoHolder);
        wildcard.approveProposal(address(hub), id);

        uint256 spokeId = spoke.approvalProposalId(address(hub), id);
        vm.prank(dave);
        spoke.vote(spokeId, true);
        vm.prank(erin);
        spoke.vote(spokeId, true);
        vm.warp(block.timestamp + SPOKE_PERIOD + 1);

        (address[] memory st, uint256[] memory sv, bytes[] memory sc) =
            _action(address(spoke), abi.encodeWithSelector(spoke.approveProposal.selector, address(hub), id));
        spoke.execute(spokeId, 0, st, sv, sc, keccak256(abi.encode("approval", address(hub), id)));

        assertTrue(hub.canExecuteNow(id));
        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    // the wildcard alone gates a selector the council never sees
    function test_WildcardAloneGatesAnUndelegatedSelector() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (60)));

        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("set fee"));

        assertEq(pool.feeBps(), 0); // withheld by the wildcard
        assertEq(hub.delegates(id, 0), address(wildcard));

        vm.prank(vetoHolder);
        wildcard.approveProposal(address(hub), id);
        hub.execute(id, 0, t, v, c, keccak256("set fee"));
        assertEq(pool.feeBps(), 60);
    }
}

// ===================================================================
// Governance of governance: one Governor owning another
//
// The third contract-owner shape. The child's Owned constitution names the
// parent Governor as its owner, so the child only ever acts on the parent's
// instruction -- and because both settle on propose, a single call from the
// parent's admin cascades all the way through to the action.
// ===================================================================
contract GovernorAsOwnerTest is OwnedGovernanceBase {
    Governor parent;
    Governor child;
    AdminPool pool;

    function setUp() public {
        parent = _deployGovernor(address(_deployOwned(admin)), new DelegateRegistration[](0));
        child = _deployGovernor(address(_deployOwned(address(parent))), new DelegateRegistration[](0));
        pool = new AdminPool(address(child));
    }

    function _childAction(uint256 feeBps)
        internal
        view
        returns (address[] memory t, uint256[] memory v, bytes[] memory c)
    {
        return _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (feeBps)));
    }

    function test_ChildIsOwnedByTheParentGovernor() public {
        assertEq(Owned(child.constitution()).owner(), address(parent));
        assertTrue(Owned(child.constitution()).canPropose(address(parent)));
        assertFalse(Owned(child.constitution()).canPropose(admin));
    }

    // one call from the parent's admin cascades through both governors
    function test_OneCallCascadesThroughBothGovernors() public {
        (address[] memory ct, uint256[] memory cv, bytes[] memory cc) = _childAction(310);
        bytes32 childDescription = keccak256("child sets fee");

        (address[] memory pt, uint256[] memory pv, bytes[] memory pc) = _action(
            address(child), abi.encodeCall(Governor.propose, (ct, cv, cc, childDescription))
        );

        vm.prank(admin);
        uint256 parentId = parent.propose(pt, pv, pc, keccak256("instruct child"));

        assertTrue(parent.getProposal(parentId).executed);
        assertEq(pool.feeBps(), 310);

        bytes32 childActionHash = keccak256(abi.encode(ct, cv, cc, childDescription));
        uint256 childId = uint256(keccak256(abi.encode(address(child), block.chainid, childActionHash, uint256(0))));
        Proposal memory p = child.getProposal(childId);
        assertEq(p.proposer, address(parent));
        assertTrue(p.executed);
    }

    // the parent's admin has no standing with the child directly
    function test_RevertWhen_ParentAdminAddressesTheChildDirectly() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _childAction(999);

        vm.prank(admin);
        vm.expectRevert("Proposer not eligible");
        child.propose(t, v, c, keccak256("skip the parent"));
        assertEq(pool.feeBps(), 0);
    }

    function test_RevertWhen_AnOutsiderAddressesEitherGovernor() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _childAction(1);

        vm.prank(outsider);
        vm.expectRevert("Proposer not eligible");
        child.propose(t, v, c, keccak256("x"));

        vm.prank(outsider);
        vm.expectRevert("Proposer not eligible");
        parent.propose(t, v, c, keccak256("x"));
    }

    // handing the child to someone else severs the parent's control
    function test_ChildCanBeHandedOffAwayFromTheParent() public {
        Owned childConstitution = Owned(child.constitution());

        (address[] memory pt, uint256[] memory pv, bytes[] memory pc) = _action(
            address(childConstitution), abi.encodeCall(Ownable2Step.transferOwnership, (admin))
        );
        vm.prank(admin);
        parent.propose(pt, pv, pc, keccak256("hand child over"));

        vm.prank(admin);
        childConstitution.acceptOwnership();
        assertEq(childConstitution.owner(), admin);

        // the child now answers to admin directly, and no longer to the parent
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _childAction(42);
        vm.prank(admin);
        child.propose(t, v, c, keccak256("direct now"));
        assertEq(pool.feeBps(), 42);
    }
}
