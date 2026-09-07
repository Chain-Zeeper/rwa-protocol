// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Governor, DelegateRegistration, FunctionAuthority, VotingParametersRegistration} from "../src/governance/Governer.sol";
import {Proposal} from "../src/governance/interface/IGoverner.sol";
import {Council} from "../src/governance/constitution/council/council.sol";
import {Owned} from "../src/governance/constitution/owned/owned.sol";

contract LifecyclePool is Ownable {
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

abstract contract LifecycleBase is Test {
    uint16 constant TWO_THIRDS_BPS = 6666;
    uint256 constant GRACE = 30 days;

    function _deployCouncil(address[] memory members, uint256 votingPeriod) internal returns (Council) {
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

    function _deployOwned(address owner, uint256 votingPeriod) internal returns (Owned) {
        Owned impl = new Owned();
        return Owned(address(new ERC1967Proxy(address(impl), abi.encodeCall(Owned.initialize, (owner, votingPeriod)))));
    }

    function _deployGovernor(address constitution, DelegateRegistration[] memory registrations)
        internal
        returns (Governor)
    {
        Governor impl = new Governor(address(0));
        return Governor(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            Governor.initialize,
                            (constitution, registrations, new VotingParametersRegistration[](0))
                        )
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
// A passed proposal should lapse, not stand as an authorisation forever
// ===================================================================
contract ExecutionExpiryTest is LifecycleBase {
    uint256 constant VOTING_PERIOD = 3 days;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    Council council;
    Governor governor;
    LifecyclePool pool;

    // A council, not an owned governor: an owner's proposal is settled the
    // moment it is filed and executes on the spot, so it never sits around long
    // enough to expire. Expiry is about proposals that pass and are then
    // abandoned, which needs an electorate that votes over time.
    function setUp() public {
        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
        council = _deployCouncil(members, VOTING_PERIOD);
        governor = _deployGovernor(address(council), new DelegateRegistration[](0));
        pool = new LifecyclePool(address(governor));
    }

    function _proposeAndPass()
        internal
        returns (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c)
    {
        (t, v, c) = _action(address(pool), abi.encodeCall(LifecyclePool.setFeeBps, (250)));
        vm.prank(alice);
        id = governor.propose(t, v, c, keccak256("set fee"));
        vm.prank(alice);
        governor.vote(id, true);
        vm.prank(bob);
        governor.vote(id, true);
    }

    function test_GraceIsExposedByEveryConstitution() public {
        assertEq(council.executionGrace(), GRACE);
        assertEq(_deployOwned(admin, VOTING_PERIOD).executionGrace(), GRACE);
    }

    function test_StillExecutableInsideTheGraceWindow() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeAndPass();

        vm.warp(governor.getProposal(id).voteEnd + GRACE - 1);
        assertTrue(governor.canExecuteNow(id));
        governor.execute(id, 0, t, v, c, keccak256("set fee"));
        assertEq(pool.feeBps(), 250);
    }

    // the point: an abandoned proposal stops being a live authorisation
    function test_RevertWhen_ExecutingAfterTheGraceWindow() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeAndPass();

        vm.warp(governor.getProposal(id).voteEnd + GRACE + 1);
        assertFalse(governor.canExecuteNow(id));
        vm.expectRevert("proposal expired");
        governor.execute(id, 0, t, v, c, keccak256("set fee"));
        assertEq(pool.feeBps(), 0);
    }

    function test_ExpiryIsMeasuredFromTheStretchedDeadlineNotTheVoteStart() public {
        (uint256 id,,,) = _proposeAndPass();
        Proposal memory p = governor.getProposal(id);

        assertEq(p.voteEnd, p.voteStart + VOTING_PERIOD);
        vm.warp(p.voteStart + GRACE + 1); // past grace-from-start, not from voteEnd
        assertTrue(governor.canExecuteNow(id));
    }
}

// ===================================================================
// A proposal is judged by the rules it was created under, or not at all
// ===================================================================
contract ConstitutionPinningTest is LifecycleBase {
    uint256 constant VOTING_PERIOD = 3 days;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    Council council;
    Governor governor;
    LifecyclePool pool;

    function setUp() public {
        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
        council = _deployCouncil(members, VOTING_PERIOD);
        governor = _deployGovernor(address(council), new DelegateRegistration[](0));
        pool = new LifecyclePool(address(governor));
    }

    function test_ProposalRecordsTheConstitutionInForce() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(LifecyclePool.setFeeBps, (250)));
        vm.prank(alice);
        uint256 id = governor.propose(t, v, c, keccak256("set fee"));

        assertEq(governor.getProposal(id).constitution, address(council));
    }

    // an outgoing electorate must not be able to bank a passed proposal now and
    // fire it after governance has moved on
    function test_RevertWhen_ExecutingAProposalBankedUnderAnOldConstitution() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(LifecyclePool.setFeeBps, (900)));

        vm.prank(alice);
        uint256 banked = governor.propose(t, v, c, keccak256("back door"));
        vm.prank(alice);
        governor.vote(banked, true);
        vm.prank(bob);
        governor.vote(banked, true);

        // hand over to a constitution the old council does not control
        Owned successor = _deployOwned(admin, VOTING_PERIOD);
        (address[] memory st, uint256[] memory sv, bytes[] memory sc) =
            _action(address(governor), abi.encodeCall(Governor.changeConstitutionalStrategy, (address(successor))));

        vm.prank(alice);
        uint256 handover = governor.propose(st, sv, sc, keccak256("hand over"));
        vm.prank(alice);
        governor.vote(handover, true);
        vm.prank(bob);
        governor.vote(handover, true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(handover, 1, st, sv, sc, keccak256("hand over"));
        assertEq(governor.constitution(), address(successor));

        // the banked proposal passed, is inside its grace window, and would
        // otherwise be executable -- but not under rules it never faced
        assertFalse(governor.canExecuteNow(banked));
        vm.expectRevert("constitution changed");
        governor.execute(banked, 0, t, v, c, keccak256("back door"));
        assertEq(pool.feeBps(), 0);
    }

    function test_RevertWhen_InitializingOwnedWithZeroVotingPeriod() public {
        Owned impl = new Owned();
        vm.expectRevert("zero voting period");
        new ERC1967Proxy(address(impl), abi.encodeCall(Owned.initialize, (admin, 0)));
    }
}

// ===================================================================
// The hub stretches its deadline to cover a slower delegate
// ===================================================================
contract DelegateDeadlineTest is LifecycleBase {
    uint256 constant HUB_PERIOD = 1 days;
    uint256 constant SPOKE_PERIOD = 7 days;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank");
    address payable treasury = payable(makeAddr("treasury"));

    Governor hub;
    Governor spoke;
    LifecyclePool pool;

    function setUp() public {
        address[] memory spokeMembers = new address[](3);
        spokeMembers[0] = dave;
        spokeMembers[1] = erin;
        spokeMembers[2] = frank;
        spoke = _deployGovernor(
            address(_deployCouncil(spokeMembers, SPOKE_PERIOD)), new DelegateRegistration[](0)
        );

        address[] memory hubMembers = new address[](3);
        hubMembers[0] = alice;
        hubMembers[1] = bob;
        hubMembers[2] = carol;

        pool = new LifecyclePool(address(this));

        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(pool),
            delegate: address(spoke),
            selector: LifecyclePool.withdrawTo.selector,
            authority: FunctionAuthority.Hard
        });

        hub = _deployGovernor(address(_deployCouncil(hubMembers, HUB_PERIOD)), registrations);
        pool.transferOwnership(address(hub));
        vm.deal(address(pool), 10 ether);
    }

    function _proposeWithdrawal()
        internal
        returns (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c)
    {
        (t, v, c) = _action(address(pool), abi.encodeCall(LifecyclePool.withdrawTo, (treasury, 1 ether)));
        vm.prank(alice);
        id = hub.propose(t, v, c, keccak256("withdraw"));
    }

    // without this the hub would close voting on day 1 for a decision that
    // cannot resolve until day 7
    function test_HubDeadlineStretchesToCoverTheSlowerSpoke() public {
        uint256 start = block.timestamp;
        (uint256 id,,,) = _proposeWithdrawal();

        assertEq(hub.getProposal(id).voteEnd, start + SPOKE_PERIOD);

        uint256 spokeId = spoke.approvalProposalId(address(hub), id);
        assertEq(spoke.getProposal(spokeId).voteEnd, start + SPOKE_PERIOD);
    }

    // the practical consequence: hub voters are not cut off while the spoke
    // is still deliberating
    function test_HubVotersCanStillVoteBeyondTheHubsOwnPeriod() public {
        (uint256 id,,,) = _proposeWithdrawal();

        vm.warp(block.timestamp + HUB_PERIOD + 1 days); // past the hub's own 1 day
        vm.prank(alice);
        hub.vote(id, true);
        vm.prank(bob);
        hub.vote(id, true);

        assertEq(hub.getProposal(id).forVotes, 2);
    }

    function test_UndelegatedProposalKeepsTheHubsOwnDeadline() public {
        uint256 start = block.timestamp;
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _action(address(pool), abi.encodeCall(LifecyclePool.setFeeBps, (100)));

        vm.prank(alice);
        uint256 id = hub.propose(t, v, c, keccak256("set fee"));

        assertEq(hub.getProposal(id).voteEnd, start + HUB_PERIOD);
    }

    // end to end on the stretched clock
    function test_ExecutesOnceTheSpokeApprovesUnderTheStretchedDeadline() public {
        (uint256 id, address[] memory t, uint256[] memory v, bytes[] memory c) = _proposeWithdrawal();

        vm.prank(alice);
        hub.vote(id, true);
        vm.prank(bob);
        hub.vote(id, true);

        uint256 spokeId = spoke.approvalProposalId(address(hub), id);
        vm.prank(dave);
        spoke.vote(spokeId, true);
        vm.prank(erin);
        spoke.vote(spokeId, true);

        vm.warp(block.timestamp + SPOKE_PERIOD + 1);

        (address[] memory st, uint256[] memory sv, bytes[] memory sc) =
            _action(address(spoke), abi.encodeWithSelector(spoke.approveProposal.selector, address(hub), id));
        spoke.execute(spokeId, 0, st, sv, sc, keccak256(abi.encode("approval", address(hub), id)));

        assertTrue(spoke.hasApproved(address(hub), id));
        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }
}
