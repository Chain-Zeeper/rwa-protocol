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

// a target that fails, to exercise how execution surfaces the reason
contract Reverter {
    error CustomFailure(uint256 code);
    function failWithReason() external pure { revert("target said no"); }
    function failWithCustomError() external pure { revert CustomFailure(7); }
    function failSilently() external pure { assembly { revert(0, 0) } }
}

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

    // a pool that pays out can also be paid into -- needed to exercise a bare
    // value transfer landing on a target that carries a wildcard veto
    receive() external payable {}
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

    // A veto holder is just another Governor. It already implements IGoverner,
    // so it drops straight into a delegate slot with no adapter in between, and
    // its own constitution decides who speaks for it -- Owned for a single
    // holder here, but swapping that for a Council turns the very same address
    // into a committee without the hub re-registering anything.
    function _deployVetoSpoke(address holder) internal returns (Governor) {
        return _deployGovernor(address(_deployOwned(holder)), new DelegateRegistration[](0));
    }

    // The holder signing off through its own governance. One ballot settles an
    // Owned spoke, and executing the approval afterwards is permissionless.
    function _spokeApproves(Governor spoke, address holder, address hub, uint256 hubProposalId) internal {
        uint256 childId = spoke.approvalProposalId(hub, hubProposalId);
        require(childId != 0, "spoke was never asked to approve");

        vm.prank(holder);
        spoke.vote(childId, true);

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(spoke), abi.encodeWithSelector(spoke.approveProposal.selector, hub, hubProposalId));
        spoke.execute(
            childId, spoke.getProposal(childId).nounce, t, v, c,
            keccak256(abi.encode("approval", hub, hubProposalId))
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

    // The reason two-step matters here, and it is a bigger deal than for a
    // normal Ownable: this owner is not an admin sitting beside an electorate,
    // it IS the entire electorate. A single-step transfer to a typo'd or
    // unreachable address would leave canPropose false for everyone -- and the
    // proposal that would install a working constitution needs an eligible
    // proposer, so there would be no way back. The governor and every contract
    // it owns would be frozen permanently.
    //
    // Two-step makes the new owner prove control first. An address that cannot
    // call acceptOwnership simply never becomes the owner.
    function test_AnUnclaimedTransferLeavesTheOriginalOwnerInCharge() public {
        address unreachable = address(0xdead);

        vm.prank(admin);
        constitution.transferOwnership(unreachable);
        assertEq(constitution.pendingOwner(), unreachable);

        // nothing has moved: admin still governs, and the governor still works
        assertEq(constitution.owner(), admin);
        assertTrue(constitution.canPropose(admin));

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (75)));
        vm.prank(admin);
        governor.propose(t, v, c, keccak256("still working"));
        assertEq(pool.feeBps(), 75);

        // and the mistake is undone by simply pointing it somewhere reachable
        address successor = makeAddr("successor");
        vm.prank(admin);
        constitution.transferOwnership(successor);
        vm.prank(successor);
        constitution.acceptOwnership();
        assertEq(constitution.owner(), successor);
    }

    function test_RevertWhen_WrongAccountAcceptsOwnership() public {
        vm.prank(admin);
        constitution.transferOwnership(makeAddr("successor"));

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        constitution.acceptOwnership();
    }

    function test_OwnerCanRetuneTheVotingPeriod() public {
        assertEq(constitution.votingPeriod(), VOTING_PERIOD);

        vm.prank(admin);
        constitution.setVotingPeriod(10 days);

        assertEq(constitution.votingPeriod(), 10 days);
        assertEq(constitution.getDefaultVotingParameters().votingPeriod, 10 days);

        // and it takes effect on the next proposal
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (10)));
        vm.prank(admin);
        uint256 id = governor.propose(t, v, c, keccak256("set fee"));
        Proposal memory p = governor.getProposal(id);
        assertEq(p.voteEnd, p.voteStart + 10 days);
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
    Governor spoke; // the veto holder
    AdminPool pool;

    address vetoHolder = makeAddr("vetoHolder");

    function setUp() public {
        spoke = _deployVetoSpoke(vetoHolder);
        constitution = _deployOwned(admin);
        pool = new AdminPool(address(this));

        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(pool),
            delegate: address(spoke),
            selector: AdminPool.withdrawTo.selector,
            authority: FunctionAuthority.Hard
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
        assertEq(governor.delegates(proposalId, 0), address(spoke));
    }

    // and it must not revert: reverting would roll back the proposeApproval
    // call, so the veto holder would never learn the proposal exists
    function test_TheDelegateIsStillNotifiedWhenExecutionIsDeferred() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();

        uint256 childId = spoke.approvalProposalId(address(governor), proposalId);
        assertTrue(childId != 0, "the spoke was never asked");
        assertEq(
            spoke.getProposal(childId).descriptionHash,
            keccak256(abi.encode("approval", address(governor), proposalId))
        );
    }

    // once the veto holder signs off there is still no timer to serve
    function test_ExecutesImmediatelyAfterTheApproverSignsOff() public {
        (uint256 proposalId, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        _spokeApproves(spoke, vetoHolder, address(governor), proposalId);
        assertTrue(spoke.hasApproved(address(governor), proposalId));

        assertTrue(governor.canExecuteNow(proposalId)); // no warp
        governor.execute(proposalId, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    function test_RevertWhen_AnOutsiderTriesToApprove() public {
        (uint256 proposalId,,,) = _proposeWithdrawal();
        uint256 childId = spoke.approvalProposalId(address(governor), proposalId);

        vm.prank(outsider);
        vm.expectRevert("Cannot vote");
        spoke.vote(childId, true);
    }

    // rotating the holder happens inside the spoke, so the hub re-registers
    // nothing -- the spoke's address is what it points at, and that never moves
    function test_VetoHolderCanBeRotatedWithoutReRegistering() public {
        address successor = makeAddr("successor");
        Owned spokeConstitution = Owned(spoke.constitution());
        address spokeAddress = address(spoke);

        vm.prank(vetoHolder);
        spokeConstitution.transferOwnership(successor);
        assertEq(spokeConstitution.owner(), vetoHolder); // two-step: not yet

        vm.prank(successor);
        spokeConstitution.acceptOwnership();
        assertEq(spokeConstitution.owner(), successor);
        assertEq(address(spoke), spokeAddress);

        (uint256 proposalId, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        uint256 childId = spoke.approvalProposalId(address(governor), proposalId);
        vm.prank(vetoHolder); // the retired holder has no say any more
        vm.expectRevert("Cannot vote");
        spoke.vote(childId, true);

        _spokeApproves(spoke, successor, address(governor), proposalId);
        governor.execute(proposalId, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    // a veto holder with no owner could never approve anything again, which
    // would block every hub that registered it
    function test_RevertWhen_RenouncingTheVeto() public {
        Owned spokeConstitution = Owned(spoke.constitution()); // hoisted: prank applies to the next call
        vm.prank(vetoHolder);
        vm.expectRevert("use transferOwnership");
        spokeConstitution.renounceOwnership();
    }

    // the graceful exit an adapter could not perform: the spoke stands itself
    // down by calling the hub's own registration surface
    function test_SpokeCanStandItselfDown() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action(
            address(governor),
            abi.encodeCall(
                Governor.setDelegateGovernance, (address(pool), AdminPool.withdrawTo.selector, address(0), FunctionAuthority.Soft)
            )
        );
        vm.prank(vetoHolder);
        spoke.propose(t, v, c, keccak256("stand down"));

        (address[] memory wt, uint256[] memory wv, bytes[] memory wc) =
            _action(address(pool), abi.encodeCall(AdminPool.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        governor.propose(wt, wv, wc, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
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
// a single-holder spoke.
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
            authority: FunctionAuthority.Hard
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
// A wildcard veto over every call to the pool held by one address, plus a council
// spoke on the withdrawal selector specifically. Both must sign off.
// ===================================================================
contract OwnedWithTwoDelegatesTest is OwnedGovernanceBase {
    bytes4 constant ANY_SELECTOR = 0xffffffff;
    uint256 constant COUNCIL_PERIOD = 5 days;

    address vetoHolder = makeAddr("vetoHolder");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank");

    Governor hub;
    Governor councilSpoke;   // a committee, on one selector
    Governor wildcardSpoke;  // a single holder, over everything
    AdminPool pool;

    function setUp() public {
        address[] memory members = new address[](3);
        members[0] = dave;
        members[1] = erin;
        members[2] = frank;
        councilSpoke = _deployGovernor(
            address(_deployCouncilWith(members, COUNCIL_PERIOD)), new DelegateRegistration[](0)
        );

        // the same shape, a different constitution -- which is the point: a veto
        // holder's internal politics are its own business
        wildcardSpoke = _deployVetoSpoke(vetoHolder);

        pool = new AdminPool(address(this));

        DelegateRegistration[] memory registrations = new DelegateRegistration[](2);
        registrations[0] = DelegateRegistration({
            target: address(pool),
            delegate: address(wildcardSpoke),
            selector: ANY_SELECTOR,
            authority: FunctionAuthority.Hard
        });
        registrations[1] = DelegateRegistration({
            target: address(pool),
            delegate: address(councilSpoke),
            selector: AdminPool.withdrawTo.selector,
            authority: FunctionAuthority.Hard
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

    function _councilApproves(uint256 hubId) internal {
        uint256 childId = councilSpoke.approvalProposalId(address(hub), hubId);
        vm.prank(dave);
        councilSpoke.vote(childId, true);
        vm.prank(erin);
        councilSpoke.vote(childId, true);
        vm.warp(block.timestamp + COUNCIL_PERIOD + 1);

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action(
            address(councilSpoke),
            abi.encodeWithSelector(councilSpoke.approveProposal.selector, address(hub), hubId)
        );
        councilSpoke.execute(
            childId, councilSpoke.getProposal(childId).nounce, t, v, c,
            keccak256(abi.encode("approval", address(hub), hubId))
        );
    }

    function test_BothVetoHoldersAreRecordedAndNotified() public {
        (uint256 id,,,) = _proposeWithdrawal();

        assertEq(hub.delegates(id, 0), address(councilSpoke)); // specific rule first
        assertEq(hub.delegates(id, 1), address(wildcardSpoke));

        assertTrue(councilSpoke.approvalProposalId(address(hub), id) != 0);
        assertTrue(wildcardSpoke.approvalProposalId(address(hub), id) != 0);
    }

    function test_RevertWhen_OnlyOneVetoHolderApproves() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        _spokeApproves(wildcardSpoke, vetoHolder, address(hub), id);

        assertFalse(hub.canExecuteNow(id));
        vm.expectRevert("delegate approval missing");
        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 0);
    }

    function test_ExecutesOnlyAfterBothApprove() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        _spokeApproves(wildcardSpoke, vetoHolder, address(hub), id);
        _councilApproves(id);

        assertTrue(hub.canExecuteNow(id));
        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    // A bare value transfer carries no selector, but it still reaches the
    // target's receive/fallback -- so a blanket veto over that target has to
    // cover it. Otherwise {to, value, ""} walks past the veto that
    // to.withdrawTo() is subject to, for the same money and destination.
    function test_WildcardVetoCoversABareValueTransfer() public {
        vm.deal(address(hub), 5 ether);

        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(pool);
        v[0] = 1 ether;
        c[0] = "";

        uint256 poolBefore = address(pool).balance;

        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("bare send"));

        assertFalse(hub.getProposal(id).executed);
        assertEq(address(pool).balance, poolBefore); // withheld
        assertEq(hub.delegates(id, 0), address(wildcardSpoke));
        assertFalse(hub.canExecuteNow(id));

        _spokeApproves(wildcardSpoke, vetoHolder, address(hub), id);

        hub.execute(id, 0, t, v, c, keccak256("bare send"));
        assertEq(address(pool).balance, poolBefore + 1 ether);
    }

    // ...but a target nobody registered a rule on is still freely payable
    function test_BareValueTransferToAnUnregisteredTargetIsUngated() public {
        vm.deal(address(hub), 5 ether);

        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = treasury;
        v[0] = 1 ether;
        c[0] = "";

        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("pay treasury"));

        assertTrue(hub.getProposal(id).executed);
        assertEq(treasury.balance, 1 ether);
        vm.expectRevert();
        hub.delegates(id, 0); // no delegate was required
    }

    // the wildcard alone gates a selector the council never sees
    function test_WildcardAloneGatesAnUndelegatedSelector() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (60)));

        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("set fee"));

        assertEq(pool.feeBps(), 0); // withheld by the wildcard
        assertEq(hub.delegates(id, 0), address(wildcardSpoke));

        _spokeApproves(wildcardSpoke, vetoHolder, address(hub), id);
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

// ===================================================================
// Soft vetoes: FunctionAuthority.Soft
//
// A Hub-authority delegate must approve exactly like a Delegated one -- the
// difference is that the hub owns the registration, so governance can revoke
// or move it by ordinary proposal. That makes it a sign-off you have to seek
// and a record you leave behind, rather than an absolute block.
// ===================================================================
contract SoftVetoTest is OwnedGovernanceBase {
    address vetoHolder = makeAddr("vetoHolder");

    Governor hub;
    Governor soft; // the veto holder, registered with Soft authority
    AdminPool pool;

    function setUp() public {
        soft = _deployVetoSpoke(vetoHolder);
        pool = new AdminPool(address(this));

        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(pool),
            delegate: address(soft),
            selector: AdminPool.withdrawTo.selector,
            authority: FunctionAuthority.Soft
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

    // the half that was missing before Soft was enforced: a soft veto is still
    // a veto
    function test_SoftVetoStillBlocksUntilItApproves() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        assertFalse(hub.getProposal(id).executed);
        assertEq(treasury.balance, 0);
        assertEq(hub.delegates(id, 0), address(soft));

        vm.expectRevert("delegate approval missing");
        hub.execute(id, 0, t, v, c, keccak256("withdraw"));

        _spokeApproves(soft, vetoHolder, address(hub), id);
        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    // ...but governance owns the registration and can take it away
    function test_HubCanRevokeASoftVetoByProposal() public {
        (address[] memory rt, uint256[] memory rv, bytes[] memory rc) = _action(
            address(hub),
            abi.encodeCall(
                Governor.setDelegateGovernance, (address(pool), AdminPool.withdrawTo.selector, address(0), FunctionAuthority.Soft)
            )
        );
        vm.prank(admin);
        hub.propose(rt, rv, rc, keccak256("drop the soft veto"));

        // a fresh proposal is now unencumbered
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        hub.propose(t, v, c, keccak256("withdraw"));

        assertEq(treasury.balance, 1 ether);
    }

    function test_HubCanMoveASoftVetoToAnotherHolder() public {
        address successor = makeAddr("successor");
        Governor moved = _deployVetoSpoke(successor);

        (address[] memory st, uint256[] memory sv, bytes[] memory sc) = _action(
            address(hub),
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), AdminPool.withdrawTo.selector, address(moved), FunctionAuthority.Soft)
            )
        );
        vm.prank(admin);
        hub.propose(st, sv, sc, keccak256("move the soft veto"));

        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();
        assertEq(hub.delegates(id, 0), address(moved));
        assertEq(soft.approvalProposalId(address(hub), id), 0, "the old holder was never asked");

        _spokeApproves(moved, successor, address(hub), id);
        hub.execute(id, hub.getProposal(id).nounce, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    // revoking is not retroactive: a proposal already recorded against the veto
    // still needs it, so governance cannot revoke mid-flight to unblock one
    function test_RevokingDoesNotReleaseAProposalAlreadyInFlight() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        (address[] memory rt, uint256[] memory rv, bytes[] memory rc) = _action(
            address(hub),
            abi.encodeCall(
                Governor.setDelegateGovernance, (address(pool), AdminPool.withdrawTo.selector, address(0), FunctionAuthority.Soft)
            )
        );
        vm.prank(admin);
        hub.propose(rt, rv, rc, keccak256("drop the soft veto"));

        vm.expectRevert("delegate approval missing");
        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
    }

    // the soft holder does not own the slot -- only the hub does
    function test_RevertWhen_SoftVetoHolderTriesToMoveItself() public {
        vm.prank(vetoHolder);
        vm.expectRevert("only via executed proposal");
        hub.setDelegateGovernance(
            address(pool), AdminPool.withdrawTo.selector, address(soft), FunctionAuthority.Hard
        );

        vm.prank(address(soft));
        vm.expectRevert("only via executed proposal");
        hub.setDelegateGovernance(address(pool), AdminPool.withdrawTo.selector, address(0), FunctionAuthority.Soft);
    }

    // and the contrast: a hard veto cannot be revoked by governance at all
    function test_RevertWhen_HubTriesToRevokeAHardVeto() public {
        Governor hard = _deployVetoSpoke(vetoHolder);

        AdminPool gated = new AdminPool(address(this));
        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(gated),
            delegate: address(hard),
            selector: AdminPool.withdrawTo.selector,
            authority: FunctionAuthority.Hard
        });
        Governor g = _deployGovernor(address(_deployOwned(admin)), registrations);
        gated.transferOwnership(address(g));

        (address[] memory rt, uint256[] memory rv, bytes[] memory rc) = _action(
            address(g),
            abi.encodeCall(
                Governor.setDelegateGovernance, (address(gated), AdminPool.withdrawTo.selector, address(0), FunctionAuthority.Soft)
            )
        );
        vm.prank(admin);
        vm.expectRevert("only the veto holder can move a hard veto");
        g.propose(rt, rv, rc, keccak256("try to drop the hard veto"));
    }
}
// ===================================================================
// What a veto actually covers
//
// A veto is keyed on (target, selector). Registering one on the selector that
// moves the money does not cover the selector that moves the *contract* -- so
// governance can hand the asset to an ungated governor and withdraw from there.
// Only a wildcard closes that, which is why every "hard veto" worth the name is
// registered on ANY_SELECTOR.
// ===================================================================
contract VetoScopeTest is OwnedGovernanceBase {
    bytes4 constant ANY_SELECTOR = 0xffffffff;

    address vetoHolder = makeAddr("vetoHolder");

    function _setup(bytes4 gatedSelector) internal returns (Governor hub, AdminPool pool, Governor veto) {
        veto = _deployVetoSpoke(vetoHolder);
        pool = new AdminPool(address(this));

        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(pool),
            delegate: address(veto),
            selector: gatedSelector,
            authority: FunctionAuthority.Hard
        });

        hub = _deployGovernor(address(_deployOwned(admin)), registrations);
        pool.transferOwnership(address(hub));
        vm.deal(address(pool), 10 ether);
    }

    // Documents the escape rather than endorsing it: a selector-specific veto
    // is only as strong as the selectors around it.
    function test_SelectorSpecificVetoIsEscapedByMovingOwnership() public {
        (Governor hub, AdminPool pool,) = _setup(AdminPool.withdrawTo.selector);

        Governor ungated = _deployGovernor(address(_deployOwned(admin)), new DelegateRegistration[](0));

        // transferOwnership is a different selector, so no veto is registered
        (address[] memory mt, uint256[] memory mv, bytes[] memory mc) =
            _action(address(pool), abi.encodeCall(Ownable.transferOwnership, (address(ungated))));
        vm.prank(admin);
        hub.propose(mt, mv, mc, keccak256("move the pool"));

        assertEq(pool.owner(), address(ungated), "ownership moved with no veto consulted");

        // and from there the withdrawal is unencumbered
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        ungated.propose(t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    // the wildcard is what makes a hard veto actually hard
    function test_WildcardVetoCoversTheOwnershipEscape() public {
        (Governor hub, AdminPool pool,) = _setup(ANY_SELECTOR);

        Governor ungated = _deployGovernor(address(_deployOwned(admin)), new DelegateRegistration[](0));

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(Ownable.transferOwnership, (address(ungated))));
        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("try to escape"));

        assertEq(pool.owner(), address(hub), "ownership must not move without the veto holder");
        vm.expectRevert("delegate approval missing");
        hub.execute(id, 0, t, v, c, keccak256("try to escape"));
    }
}
// ===================================================================
// Carving a selector out of a blanket veto
//
// The exemption is written into the same delagateGovernance mapping as every
// other rule: the governor registered as its own delegate for (target,
// selector) means "this selector is exempt from the wildcard on this target".
// One mapping, so a veto-holder auditing their target sees carve-outs in the
// same place they see vetoes.
// ===================================================================
contract ExemptionTest is OwnedGovernanceBase {
    bytes4 constant ANY_SELECTOR = 0xffffffff;

    address vetoAdmin = makeAddr("vetoAdmin");

    Governor hub;
    Governor spoke; // holds the hard blanket veto over the pool
    AdminPool pool;

    function setUp() public {
        spoke = _deployGovernor(address(_deployOwned(vetoAdmin)), new DelegateRegistration[](0));
        pool = new AdminPool(address(this));

        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(pool),
            delegate: address(spoke),
            selector: ANY_SELECTOR,
            authority: FunctionAuthority.Hard
        });

        hub = _deployGovernor(address(_deployOwned(admin)), registrations);
        pool.transferOwnership(address(hub));
        vm.deal(address(pool), 10 ether);
        vm.deal(address(hub), 10 ether);
    }

    // the blanket holder acts on the hub through its own governance
    function _blanketHolderCalls(bytes memory data, bytes32 tag) internal {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action(address(hub), data);
        vm.prank(vetoAdmin);
        spoke.propose(t, v, c, tag);
    }

    function _proposeFee(uint256 bps) internal returns (uint256 id) {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.setFeeBps, (bps)));
        vm.prank(admin);
        id = hub.propose(t, v, c, keccak256("set fee"));
    }

    function test_BlanketHolderCanCarveAnExemption() public {
        assertFalse(hub.isExempt(address(pool), AdminPool.setFeeBps.selector));

        _blanketHolderCalls(
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), AdminPool.setFeeBps.selector, address(hub), FunctionAuthority.Hard)
            ),
            keccak256("exempt setFeeBps")
        );

        assertTrue(hub.isExempt(address(pool), AdminPool.setFeeBps.selector));

        // the carved selector now runs with no sign-off at all
        _proposeFee(180);
        assertEq(pool.feeBps(), 180);
    }

    function test_ExemptionDoesNotLeakToOtherSelectors() public {
        _blanketHolderCalls(
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), AdminPool.setFeeBps.selector, address(hub), FunctionAuthority.Hard)
            ),
            keccak256("exempt setFeeBps")
        );

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("withdraw"));

        assertEq(hub.delegates(id, 0), address(spoke)); // still blanketed
        assertEq(treasury.balance, 0);
    }

    // the whole point of the authorization rule: the hub cannot carve its own
    // way out of a veto it is not allowed to revoke
    function test_RevertWhen_HubCarvesItsOwnExemption() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action(
            address(hub),
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), AdminPool.setFeeBps.selector, address(hub), FunctionAuthority.Hard)
            )
        );
        vm.prank(admin);
        vm.expectRevert("only the blanket veto holder can carve an exemption");
        hub.propose(t, v, c, keccak256("self exempt"));
    }

    function test_RevertWhen_ExemptingTheWildcardItself() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action(
            address(hub),
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), ANY_SELECTOR, address(hub), FunctionAuthority.Hard)
            )
        );
        vm.prank(vetoAdmin);
        vm.expectRevert("cannot exempt the wildcard itself");
        spoke.propose(t, v, c, keccak256("exempt everything"));
    }

    // a Hard sentinel belongs to the hub, so the hub can hand the exemption
    // back -- every move out of "exempt" only ever tightens
    function test_HubCanRetireAnExemptionItWasGranted() public {
        _blanketHolderCalls(
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), AdminPool.setFeeBps.selector, address(hub), FunctionAuthority.Hard)
            ),
            keccak256("exempt setFeeBps")
        );

        (address[] memory rt, uint256[] memory rv, bytes[] memory rc) = _action(
            address(hub),
            abi.encodeCall(
                Governor.setDelegateGovernance, (address(pool), AdminPool.setFeeBps.selector, address(0), FunctionAuthority.Soft)
            )
        );
        vm.prank(admin);
        hub.propose(rt, rv, rc, keccak256("hand it back"));

        assertFalse(hub.isExempt(address(pool), AdminPool.setFeeBps.selector));

        // the blanket veto covers the selector again
        uint256 id = _proposeFee(240);
        assertEq(pool.feeBps(), 0);
        assertEq(hub.delegates(id, 0), address(spoke));
    }

    function test_RevertWhen_HubRecreatesARetiredExemption() public {
        _blanketHolderCalls(
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), AdminPool.setFeeBps.selector, address(hub), FunctionAuthority.Hard)
            ),
            keccak256("exempt setFeeBps")
        );
        (address[] memory rt, uint256[] memory rv, bytes[] memory rc) = _action(
            address(hub),
            abi.encodeCall(
                Governor.setDelegateGovernance, (address(pool), AdminPool.setFeeBps.selector, address(0), FunctionAuthority.Soft)
            )
        );
        vm.prank(admin);
        hub.propose(rt, rv, rc, keccak256("hand it back"));

        // slot is empty again, so the blanket holder owns it once more
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action(
            address(hub),
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), AdminPool.setFeeBps.selector, address(hub), FunctionAuthority.Hard)
            )
        );
        vm.prank(admin);
        vm.expectRevert("only the blanket veto holder can carve an exemption");
        hub.propose(t, v, c, keccak256("re-exempt"));
    }

    // A slot holding address(0) with Hard authority -- how a holder stands down
    // without deleting the entry -- must still be tidy-away-able. restore keys
    // on the authority flag, so without a governer check it would demand
    // msg.sender == address(0) and strand the slot forever.
    function test_HubCanTidyAwayAZeroedHardSlot() public {
        _blanketHolderCalls(
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), ANY_SELECTOR, address(0), FunctionAuthority.Hard)
            ),
            keccak256("stand down")
        );

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action(
            address(hub),
            abi.encodeCall(
                Governor.setDelegateGovernance, (address(pool), ANY_SELECTOR, address(0), FunctionAuthority.Soft)
            )
        );
        vm.prank(admin);
        hub.propose(t, v, c, keccak256("tidy the slot away"));

        (address governer, FunctionAuthority authority) = hub.delagateGovernance(address(pool), ANY_SELECTOR);
        assertEq(governer, address(0));
        assertTrue(authority == FunctionAuthority.Soft, "slot is fully cleared");
    }

    // address(0) is the other special value in this mapping, and it means the
    // opposite of the sentinel: no delegate at all. An unregistered selector
    // must not read as exempt just because nothing is there.
    // the sentinel value an integrator has to pass to carve an exemption
    function test_ExemptSentinelIsTheGovernorItself() public {
        assertEq(hub.EXEMPT(), address(hub));
    }

    function test_AnEmptySlotIsNotExempt() public {
        assertFalse(hub.isExempt(address(pool), AdminPool.withdrawTo.selector));
        assertFalse(hub.isExempt(address(pool), bytes4(0xdeadbeef)));
        assertFalse(hub.isExempt(makeAddr("unrelated"), AdminPool.setFeeBps.selector));
    }

    // zeroing a slot is how a holder stands down
    function test_BlanketHolderCanStandDownByZeroingItsSlot() public {
        _blanketHolderCalls(
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), ANY_SELECTOR, address(0), FunctionAuthority.Hard)
            ),
            keccak256("stand down")
        );

        // no delegate is registered any more, so the pool is ungated
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(AdminPool.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("withdraw"));

        assertEq(treasury.balance, 1 ether);
        vm.expectRevert();
        hub.delegates(id, 0); // nobody was asked
    }

    // and the hub cannot zero someone else's hard veto to achieve the same
    function test_RevertWhen_HubZeroesAHardVeto() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action(
            address(hub),
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), ANY_SELECTOR, address(0), FunctionAuthority.Hard)
            )
        );
        vm.prank(admin);
        vm.expectRevert("only the veto holder can move a hard veto");
        hub.propose(t, v, c, keccak256("zero it out"));
    }

    // the blanket check keys on governer != address(0), so once the blanket is
    // zeroed the hub owns every slot on that target again
    function test_ZeroingTheBlanketReturnsEverySlotToTheHub() public {
        // while the blanket stands, the hub cannot write a specific slot
        (address[] memory bt, uint256[] memory bv, bytes[] memory bc) = _action(
            address(hub),
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), AdminPool.setFeeBps.selector, address(hub), FunctionAuthority.Hard)
            )
        );
        vm.prank(admin);
        vm.expectRevert("only the blanket veto holder can carve an exemption");
        hub.propose(bt, bv, bc, keccak256("carve"));

        _blanketHolderCalls(
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), ANY_SELECTOR, address(0), FunctionAuthority.Hard)
            ),
            keccak256("stand down")
        );

        // now it can
        vm.prank(admin);
        hub.propose(bt, bv, bc, keccak256("carve"));
        assertTrue(hub.isExempt(address(pool), AdminPool.setFeeBps.selector));
    }

    // no selector, nothing to exempt: treasury movement stays covered
    function test_BareValueTransferIsNeverExempt() public {
        _blanketHolderCalls(
            abi.encodeCall(
                Governor.setDelegateGovernance,
                (address(pool), AdminPool.setFeeBps.selector, address(hub), FunctionAuthority.Hard)
            ),
            keccak256("exempt setFeeBps")
        );

        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(pool);
        v[0] = 1 ether;
        c[0] = "";

        uint256 before = address(pool).balance;
        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("bare send"));

        assertEq(address(pool).balance, before);
        assertEq(hub.delegates(id, 0), address(spoke));
    }
}

// ===================================================================
// A failing action must say why
//
// _execute bubbles the target's own revert data rather than swallowing it,
// which is what makes a failed governance action debuggable at all.
// ===================================================================
contract ExecutionFailureTest is OwnedGovernanceBase {
    Governor governor;
    Reverter reverter;

    function setUp() public {
        governor = _deployGovernor(address(_deployOwned(admin)), new DelegateRegistration[](0));
        reverter = new Reverter();
    }

    function test_RevertReasonIsBubbledUp() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(reverter), abi.encodeCall(Reverter.failWithReason, ()));

        vm.prank(admin);
        vm.expectRevert("target said no");
        governor.propose(t, v, c, keccak256("will fail"));
    }

    function test_CustomErrorIsBubbledUp() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(reverter), abi.encodeCall(Reverter.failWithCustomError, ()));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Reverter.CustomFailure.selector, uint256(7)));
        governor.propose(t, v, c, keccak256("will fail"));
    }

    // no return data to bubble, so the governor supplies its own message
    function test_SilentRevertGetsAGovernorMessage() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(reverter), abi.encodeCall(Reverter.failSilently, ()));

        vm.prank(admin);
        vm.expectRevert("Governor: call reverted without reason");
        governor.propose(t, v, c, keccak256("will fail"));
    }

    // a failing action takes the whole proposal down with it, so nothing is
    // half-applied and the proposal is not left marked executed
    function test_AFailingActionRollsBackTheWholeProposal() public {
        AdminPool pool = new AdminPool(address(governor));
        address[] memory t = new address[](2);
        uint256[] memory v = new uint256[](2);
        bytes[] memory c = new bytes[](2);
        t[0] = address(pool);
        c[0] = abi.encodeCall(AdminPool.setFeeBps, (500));
        t[1] = address(reverter);
        c[1] = abi.encodeCall(Reverter.failWithReason, ());

        vm.prank(admin);
        vm.expectRevert("target said no");
        governor.propose(t, v, c, keccak256("two actions"));

        assertEq(pool.feeBps(), 0, "the first action must not survive");
    }
}
