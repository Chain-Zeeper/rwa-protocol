// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {Governor, DelegateRegistration, FunctionAuthority, VotingParametersRegistration} from "../src/governance/Governer.sol";
import {Proposal, VotingParameters} from "../src/governance/interface/IGoverner.sol";
import {Council} from "../src/governance/VotingStrategies/council/council.sol";

// Stand-in for a cosmo-local-credit style pool (see SwapPool.sol): an Ownable
// contract whose admin surface (fee/withdrawal controls) is only reachable
// through whoever holds `owner` -- in this setup, the Governor.
contract MockVillagePool is Ownable {
    uint256 public feeBps;
    mapping(address => uint256) public balances;

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 10_000, "fee too high");
        feeBps = _feeBps;
    }

    function fund() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdrawTo(address payable to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }
}

// Governance over a community-owned pool: a council of villagers proposes and
// votes on admin actions against the pool, and only a passed proposal can
// execute them (the pool's `owner` is the Governor itself).
contract GovernanceTest is Test {
    Governor governor;
    Council council;
    MockVillagePool pool;

    address alice = makeAddr("alice");   // villager / council member
    address bob = makeAddr("bob");       // villager / council member
    address carol = makeAddr("carol");   // villager / council member
    address outsider = makeAddr("outsider");

    // spoke villagers, used by the delegated-governance tests only
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank");
    address treasury = makeAddr("treasury");

    uint256 constant VOTING_PERIOD = 3 days;

    function setUp() public {
        // council behind a proxy, owned by this test contract so membership
        // can be adjusted directly in tests
        Council councilImpl = new Council();
        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
        bytes memory councilInit = abi.encodeCall(
            Council.initialize,
            (address(this), 6667, 6667, VOTING_PERIOD, members) // ~2-of-3 threshold and quorum
        );
        council = Council(address(new ERC1967Proxy(address(councilImpl), councilInit)));

        // governor behind a proxy, constituted by the council above
        Governor governorImpl = new Governor();
        bytes memory governorInit = abi.encodeCall(
            Governor.initialize,
            (address(council), bytes32(0), new DelegateRegistration[](0), new VotingParametersRegistration[](0))
        );
        governor = Governor(address(new ERC1967Proxy(address(governorImpl), governorInit)));

        // the village pool is owned by the governor: only an executed,
        // passed proposal can touch its admin functions
        pool = new MockVillagePool(address(governor));
    }

    // Sets up a second hub/spoke pair for the delegated-governance tests:
    // withdrawals from `dPool` require sign-off from a separate spoke
    // council (dave/erin/frank) before the hub council can execute them.
    // Isolated from the main governor/council/pool so the simpler tests
    // above aren't affected by the extra delegation wiring.
    function _deployCouncil(address[] memory members) internal returns (Council) {
        Council impl = new Council();
        bytes memory init = abi.encodeCall(Council.initialize, (address(this), 6667, 6667, VOTING_PERIOD, members));
        return Council(address(new ERC1967Proxy(address(impl), init)));
    }

    function _deploySpokeGovernor() internal returns (Governor) {
        address[] memory spokeMembers = new address[](3);
        spokeMembers[0] = dave;
        spokeMembers[1] = erin;
        spokeMembers[2] = frank;
        Council spokeCouncil = _deployCouncil(spokeMembers);

        Governor impl = new Governor();
        bytes memory init = abi.encodeCall(
            Governor.initialize,
            (address(spokeCouncil), bytes32(0), new DelegateRegistration[](0), new VotingParametersRegistration[](0))
        );
        return Governor(address(new ERC1967Proxy(address(impl), init)));
    }

    function _setupDelegatedHub() internal returns (Governor dGovernor, Governor spokeGovernor, MockVillagePool dPool) {
        spokeGovernor = _deploySpokeGovernor();
        dPool = new MockVillagePool(address(this));

        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
        Council dCouncil = _deployCouncil(members);

        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: address(dPool),
            delegate: address(spokeGovernor),
            selector: MockVillagePool.withdrawTo.selector,
            authority: FunctionAuthority.Delegated
        });

        Governor dGovernorImpl = new Governor();
        bytes memory dGovernorInit = abi.encodeCall(
            Governor.initialize,
            (address(dCouncil), bytes32(0), registrations, new VotingParametersRegistration[](0))
        );
        dGovernor = Governor(address(new ERC1967Proxy(address(dGovernorImpl), dGovernorInit)));

        dPool.transferOwnership(address(dGovernor));
    }

    function _proposeSetFee(uint256 newFee)
        internal
        returns (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        )
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(pool);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(MockVillagePool.setFeeBps, (newFee));
        descriptionHash = keccak256(bytes("set pool fee"));

        vm.prank(alice);
        proposalId = governor.propose(targets, values, calldatas, descriptionHash);
    }

    function test_CouncilCanGovernPoolFee() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeSetFee(500);

        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);
        // carol abstains -- 2 of 3 villagers is enough to pass

        Proposal memory p = governor.getProposal(proposalId);
        assertEq(p.forVotes, 2, "vote weight should tally one per council member");

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(pool.feeBps(), 500);
        assertTrue(governor.getProposal(proposalId).executed);
    }

    function test_RevertWhen_NonCouncilProposes() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(pool);
        calldatas[0] = abi.encodeCall(MockVillagePool.setFeeBps, (100));

        vm.prank(outsider);
        vm.expectRevert("Proposer not eligible");
        governor.propose(targets, values, calldatas, keccak256("x"));
    }

    function test_RevertWhen_NonCouncilVotes() public {
        (uint256 proposalId, , , , ) = _proposeSetFee(500);

        vm.prank(outsider);
        vm.expectRevert("Cannot vote");
        governor.vote(proposalId, true);
    }

    function test_RevertWhen_VotingTwice() public {
        (uint256 proposalId, , , , ) = _proposeSetFee(500);

        vm.prank(alice);
        governor.vote(proposalId, true);

        vm.prank(alice);
        vm.expectRevert("Already voted");
        governor.vote(proposalId, true);
    }

    function test_RevertWhen_ExecutingBeforeVoteEnd() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeSetFee(500);

        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);

        vm.expectRevert("Voting still open");
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
    }

    function test_RevertWhen_ProposalDidNotPass() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeSetFee(500);

        vm.prank(alice);
        governor.vote(proposalId, true);
        // only 1 of 3 villagers voted for -- below the ~2-of-3 threshold

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("Proposal did not pass");
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
    }

    function test_RevertWhen_ExecutingTwice() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeSetFee(500);

        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        vm.expectRevert("Proposal already executed");
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
    }

    function test_RevertWhen_RemovedVillagerVotes() public {
        council.removeCouncilMember(carol);

        (uint256 proposalId, , , , ) = _proposeSetFee(500);

        vm.prank(carol);
        vm.expectRevert("Cannot vote");
        governor.vote(proposalId, true);
    }

    // ---------------------------------------------------------------
    // Council bug regressions
    // ---------------------------------------------------------------

    function test_RevertWhen_RemovingNonMember() public {
        vm.expectRevert("CouncilState: Not a council member");
        council.removeCouncilMember(outsider);
    }

    function test_RevertWhen_RemovingMemberTwice() public {
        council.removeCouncilMember(carol);

        vm.expectRevert("CouncilState: Not a council member");
        council.removeCouncilMember(carol);
    }

    function test_GetVotingPowerMatchesMembership() public view {
        assertEq(council.getVotingPower(alice), 1);
        assertEq(council.getVotingPower(outsider), 0);
    }

    function test_RevertWhen_EmptiedCouncilExecutes() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeSetFee(500);

        // council dissolved after the proposal was made, with no votes cast
        council.removeCouncilMember(alice);
        council.removeCouncilMember(bob);
        council.removeCouncilMember(carol);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("Proposal did not pass");
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
    }

    // ---------------------------------------------------------------
    // access control / lifecycle
    // ---------------------------------------------------------------

    function test_RevertWhen_NonOwnerAddsCouncilMember() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        council.addCouncilMember(outsider);
    }

    function test_RevertWhen_NonOwnerRemovesCouncilMember() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        council.removeCouncilMember(alice);
    }

    function test_RevertWhen_CouncilDoubleInitialized() public {
        address[] memory members = new address[](1);
        members[0] = outsider;

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        council.initialize(address(this), 6667, 6667, VOTING_PERIOD, members);
    }

    function test_RevertWhen_GovernorDoubleInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        governor.initialize(address(council), bytes32(0), new DelegateRegistration[](0), new VotingParametersRegistration[](0));
    }

    function test_RevertWhen_DuplicateCouncilMemberAtInit() public {
        Council councilImpl = new Council();
        address[] memory members = new address[](2);
        members[0] = alice;
        members[1] = alice;
        bytes memory init = abi.encodeCall(Council.initialize, (address(this), 6667, 6667, VOTING_PERIOD, members));

        vm.expectRevert("CouncilState: Already a council member");
        new ERC1967Proxy(address(councilImpl), init);
    }

    // ---------------------------------------------------------------
    // voting/execution boundaries
    // ---------------------------------------------------------------

    function test_CanVoteExactlyAtVoteEnd() public {
        (uint256 proposalId, , , , ) = _proposeSetFee(500);
        Proposal memory p = governor.getProposal(proposalId);

        vm.warp(p.voteEnd);
        vm.prank(alice);
        governor.vote(proposalId, true);

        assertTrue(governor.hasVoted(proposalId, alice));
    }

    function test_RevertWhen_ExecutingExactlyAtVoteEnd() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeSetFee(500);

        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);

        Proposal memory p = governor.getProposal(proposalId);
        vm.warp(p.voteEnd); // exactly at the boundary, not past it

        vm.expectRevert("Voting still open");
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
    }

    // ---------------------------------------------------------------
    // self-governance (onlyGovernance)
    // ---------------------------------------------------------------

    function test_GovernanceCanChangeOwnConstitution() public {
        Council newCouncilImpl = new Council();
        address[] memory members = new address[](1);
        members[0] = alice;
        bytes memory init = abi.encodeCall(Council.initialize, (address(this), 6667, 6667, VOTING_PERIOD, members));
        Council newCouncil = Council(address(new ERC1967Proxy(address(newCouncilImpl), init)));

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(governor);
        calldatas[0] = abi.encodeCall(Governor.changeConstitutionalStrategy, (address(newCouncil)));
        bytes32 descriptionHash = keccak256(bytes("swap constitution"));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);

        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(governor.constitution(), address(newCouncil));
    }

    // ---------------------------------------------------------------
    // delegated governance (hub requires spoke sign-off on a target+selector)
    // ---------------------------------------------------------------

    function test_HubExecutesAfterSpokeApproves() public {
        (Governor dGovernor, Governor spokeGovernor, MockVillagePool dPool) = _setupDelegatedHub();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(dPool);
        calldatas[0] = abi.encodeCall(MockVillagePool.withdrawTo, (payable(treasury), 0));
        bytes32 descriptionHash = keccak256(bytes("withdraw to treasury"));

        vm.prank(alice);
        uint256 hubProposalId = dGovernor.propose(targets, values, calldatas, descriptionHash);

        uint256 spokeProposalId = spokeGovernor.approvalProposalId(address(dGovernor), hubProposalId);

        // hub council votes on the withdrawal itself
        vm.prank(alice);
        dGovernor.vote(hubProposalId, true);
        vm.prank(bob);
        dGovernor.vote(hubProposalId, true);

        // spoke council votes on its mirrored "approve this hub proposal" proposal
        vm.prank(dave);
        spokeGovernor.vote(spokeProposalId, true);
        vm.prank(erin);
        spokeGovernor.vote(spokeProposalId, true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        address[] memory spokeTargets = new address[](1);
        uint256[] memory spokeValues = new uint256[](1);
        bytes[] memory spokeCalldatas = new bytes[](1);
        spokeTargets[0] = address(spokeGovernor);
        spokeCalldatas[0] = abi.encodeWithSelector(spokeGovernor.approveProposal.selector, address(dGovernor), hubProposalId);
        bytes32 spokeDescriptionHash = keccak256(abi.encode("approval", address(dGovernor), hubProposalId));

        spokeGovernor.execute(spokeProposalId, 0, spokeTargets, spokeValues, spokeCalldatas, spokeDescriptionHash);
        assertTrue(spokeGovernor.hasApproved(address(dGovernor), hubProposalId));

        dGovernor.execute(hubProposalId, 0, targets, values, calldatas, descriptionHash);
        assertTrue(dGovernor.getProposal(hubProposalId).executed);
    }

    function test_RevertWhen_HubExecutesWithoutSpokeApproval() public {
        (Governor dGovernor, , MockVillagePool dPool) = _setupDelegatedHub();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(dPool);
        calldatas[0] = abi.encodeCall(MockVillagePool.withdrawTo, (payable(treasury), 0));
        bytes32 descriptionHash = keccak256(bytes("withdraw to treasury"));

        vm.prank(alice);
        uint256 hubProposalId = dGovernor.propose(targets, values, calldatas, descriptionHash);

        vm.prank(alice);
        dGovernor.vote(hubProposalId, true);
        vm.prank(bob);
        dGovernor.vote(hubProposalId, true);
        // spoke council never votes / approves

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("delegate approval missing");
        dGovernor.execute(hubProposalId, 0, targets, values, calldatas, descriptionHash);
    }

    function test_RevertWhen_ApproveProposalCalledDirectly() public {
        (Governor dGovernor, Governor spokeGovernor, ) = _setupDelegatedHub();

        vm.expectRevert("only via executed proposal");
        spokeGovernor.approveProposal(address(dGovernor), 123);
    }

    function test_RevertWhen_SetDelegateGovernanceByOutsider() public {
        vm.prank(outsider);
        vm.expectRevert("only via executed proposal");
        governor.setDelegateGovernance(address(pool), MockVillagePool.setFeeBps.selector, outsider, FunctionAuthority.Delegated);
    }

    // ---------------------------------------------------------------
    // plain value transfers (empty calldata)
    // ---------------------------------------------------------------

    function test_CanProposeAndExecutePlainValueTransfer() public {
        vm.deal(address(governor), 1 ether);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = treasury;
        values[0] = 1 ether;
        calldatas[0] = "";
        bytes32 descriptionHash = keccak256(bytes("send treasury 1 eth"));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);

        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(treasury.balance, 1 ether);
    }

    // ---------------------------------------------------------------
    // voting parameters: council defaults, per-target overrides, seeding
    // ---------------------------------------------------------------

    // unanimous vote, independent of the 2-of-3 threshold rounding behavior,
    // so these tests aren't coupled to that separate open question
    function _voteUnanimously(uint256 proposalId) internal {
        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);
        vm.prank(carol);
        governor.vote(proposalId, true);
    }

    // proposes, unanimously passes, and executes a governor.setVotingParameters
    // call overriding the pool's setFeeBps voting parameters
    function _overridePoolFeeVotingParams(uint16 quorumBps, uint16 thresholdBps, uint256 votingPeriod) internal {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(governor);
        calldatas[0] = abi.encodeCall(
            Governor.setVotingParameters,
            (address(pool), MockVillagePool.setFeeBps.selector, quorumBps, thresholdBps, votingPeriod)
        );
        bytes32 descriptionHash = keccak256(abi.encode("override pool fee voting params", quorumBps, thresholdBps, votingPeriod));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);
        _voteUnanimously(proposalId);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
    }

    function test_CouncilDefaultVotingParametersMatchInitialize() public view {
        VotingParameters memory params = council.getDefaultVotingParameters();
        assertEq(params.quorumBps, 6667);
        assertEq(params.thresholdBps, 6667);
        assertEq(params.votingPeriod, VOTING_PERIOD);
    }

    function test_RevertWhen_NonOwnerSetsDefaultVotingParameters() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        council.setDefaultVotingParameters(5000, 5000, 1 days);
    }

    function test_ProposalUsesCouncilDefaultsWhenNoOverrideRegistered() public {
        (uint256 proposalId, , , , ) = _proposeSetFee(500);
        Proposal memory p = governor.getProposal(proposalId);
        assertEq(p.quorumBps, 6667);
        assertEq(p.thresholdBps, 6667);
        assertEq(p.voteEnd - p.voteStart, VOTING_PERIOD);
    }

    function test_UpdatingCouncilDefaultsChangesFutureProposals() public {
        council.setDefaultVotingParameters(5000, 4000, 1 days);

        (uint256 proposalId, , , , ) = _proposeSetFee(500);
        Proposal memory p = governor.getProposal(proposalId);
        assertEq(p.quorumBps, 5000);
        assertEq(p.thresholdBps, 4000);
        assertEq(p.voteEnd - p.voteStart, 1 days);
    }

    function test_PerTargetOverrideTakesPrecedenceOverCouncilDefault() public {
        _overridePoolFeeVotingParams(5000, 5000, 1 days);

        (uint16 quorumBps, uint16 thresholdBps, uint256 votingPeriod) =
            governor.votingParameters(address(pool), MockVillagePool.setFeeBps.selector);
        assertEq(quorumBps, 5000);
        assertEq(thresholdBps, 5000);
        assertEq(votingPeriod, 1 days);

        (uint256 proposalId, , , , ) = _proposeSetFee(750);
        Proposal memory p = governor.getProposal(proposalId);
        assertEq(p.quorumBps, 5000);
        assertEq(p.thresholdBps, 5000);
        assertEq(p.voteEnd - p.voteStart, 1 days);
    }

    function test_ShorterVotingPeriodOverrideAllowsEarlierExecution() public {
        _overridePoolFeeVotingParams(5000, 5000, 1 days);

        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _proposeSetFee(750);
        _voteUnanimously(proposalId);

        // past the 1-day override but still well within the council's 3-day default
        vm.warp(block.timestamp + 1 days + 1);
        uint256 nounce = governor.getProposal(proposalId).nounce;
        governor.execute(proposalId, nounce, targets, values, calldatas, descriptionHash);

        assertEq(pool.feeBps(), 750);
    }

    function test_InitializeSeedsPerTargetVotingParameters() public {
        MockVillagePool seededPool = new MockVillagePool(address(this));

        VotingParametersRegistration[] memory votingRegs = new VotingParametersRegistration[](1);
        votingRegs[0] = VotingParametersRegistration({
            target: address(seededPool),
            selector: MockVillagePool.setFeeBps.selector,
            params: VotingParameters({quorumBps: 3333, thresholdBps: 3333, votingPeriod: 12 hours})
        });

        Governor seededGovernorImpl = new Governor();
        bytes memory governorInit = abi.encodeCall(
            Governor.initialize,
            (address(council), bytes32(0), new DelegateRegistration[](0), votingRegs)
        );
        Governor seededGovernor = Governor(address(new ERC1967Proxy(address(seededGovernorImpl), governorInit)));
        seededPool.transferOwnership(address(seededGovernor));

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(seededPool);
        calldatas[0] = abi.encodeCall(MockVillagePool.setFeeBps, (250));
        bytes32 descriptionHash = keccak256(bytes("seeded params fee change"));

        vm.prank(alice);
        uint256 proposalId = seededGovernor.propose(targets, values, calldatas, descriptionHash);

        Proposal memory p = seededGovernor.getProposal(proposalId);
        assertEq(p.quorumBps, 3333);
        assertEq(p.thresholdBps, 3333);
        assertEq(p.voteEnd - p.voteStart, 12 hours);
    }

    function test_MultiTargetProposalTakesMaxVotingParametersAcrossTargets() public {
        MockVillagePool poolA = new MockVillagePool(address(this));
        MockVillagePool poolB = new MockVillagePool(address(this));

        VotingParametersRegistration[] memory votingRegs = new VotingParametersRegistration[](2);
        votingRegs[0] = VotingParametersRegistration({
            target: address(poolA),
            selector: MockVillagePool.setFeeBps.selector,
            params: VotingParameters({quorumBps: 2000, thresholdBps: 2000, votingPeriod: 6 hours})
        });
        votingRegs[1] = VotingParametersRegistration({
            target: address(poolB),
            selector: MockVillagePool.setFeeBps.selector,
            params: VotingParameters({quorumBps: 4000, thresholdBps: 4000, votingPeriod: 2 days})
        });

        Governor impl = new Governor();
        bytes memory init = abi.encodeCall(
            Governor.initialize,
            (address(council), bytes32(0), new DelegateRegistration[](0), votingRegs)
        );
        Governor multiGovernor = Governor(address(new ERC1967Proxy(address(impl), init)));
        poolA.transferOwnership(address(multiGovernor));
        poolB.transferOwnership(address(multiGovernor));

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        targets[0] = address(poolA);
        targets[1] = address(poolB);
        calldatas[0] = abi.encodeCall(MockVillagePool.setFeeBps, (100));
        calldatas[1] = abi.encodeCall(MockVillagePool.setFeeBps, (200));
        bytes32 descriptionHash = keccak256(bytes("multi target fee update"));

        vm.prank(alice);
        uint256 proposalId = multiGovernor.propose(targets, values, calldatas, descriptionHash);

        Proposal memory p = multiGovernor.getProposal(proposalId);
        assertEq(p.quorumBps, 4000, "quorum should take the max across targets");
        assertEq(p.thresholdBps, 4000, "threshold should take the max across targets");
        assertEq(p.voteEnd - p.voteStart, 2 days, "voting period should take the max across targets");
    }

    function test_PerFieldFallbackIsIndependent() public {
        MockVillagePool seededPool = new MockVillagePool(address(this));

        // only the voting period is overridden; quorum/threshold are left at
        // their zero value and should each fall back to the council default
        // independently, not as an all-or-nothing pair
        VotingParametersRegistration[] memory votingRegs = new VotingParametersRegistration[](1);
        votingRegs[0] = VotingParametersRegistration({
            target: address(seededPool),
            selector: MockVillagePool.setFeeBps.selector,
            params: VotingParameters({quorumBps: 0, thresholdBps: 0, votingPeriod: 5 hours})
        });

        Governor impl = new Governor();
        bytes memory init = abi.encodeCall(
            Governor.initialize,
            (address(council), bytes32(0), new DelegateRegistration[](0), votingRegs)
        );
        Governor seededGovernor = Governor(address(new ERC1967Proxy(address(impl), init)));
        seededPool.transferOwnership(address(seededGovernor));

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(seededPool);
        calldatas[0] = abi.encodeCall(MockVillagePool.setFeeBps, (10));
        bytes32 descriptionHash = keccak256(bytes("independent field fallback"));

        vm.prank(alice);
        uint256 proposalId = seededGovernor.propose(targets, values, calldatas, descriptionHash);

        Proposal memory p = seededGovernor.getProposal(proposalId);
        assertEq(p.quorumBps, 6667, "quorum should fall back to the council default");
        assertEq(p.thresholdBps, 6667, "threshold should fall back to the council default");
        assertEq(p.voteEnd - p.voteStart, 5 hours, "voting period should use the registered override");
    }
}
