// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Governor, DelegateRegistration, FunctionAuthority, VotingParametersRegistration} from "../src/governance/Governer.sol";
import {Proposal, VotingParameters} from "../src/governance/interface/IGoverner.sol";
import {Council} from "../src/governance/constitution/council/council.sol";

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

// An unregistered intermediary, used to check whether a gate on the pool can
// be side-stepped by proposing a call to something else that calls the pool
contract PoolCaller {
    function drain(MockVillagePool pool, address payable to, uint256 amount) external {
        pool.withdrawTo(to, amount);
    }
}

// An ERC20 the governor holds in treasury, to exercise token-denominated
// payouts alongside raw ETH ones
contract MockTreasuryToken is ERC20 {
    constructor() ERC20("Treasury Token", "TT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
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

    // "Two thirds", expressed for a ceiling-rounded bps threshold. 6667 is
    // strictly MORE than two thirds, so it rounds up to unanimity on a
    // 3-member council (and to 5-of-6, 8-of-9, ...); 6666 is the largest bps
    // that still means 2-of-3. In general, to require M of N use
    // floor(M * 10000 / N).
    uint16 constant TWO_THIRDS_BPS = 6666;

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
            (address(this), TWO_THIRDS_BPS, TWO_THIRDS_BPS, VOTING_PERIOD, members) // 2-of-3 threshold and quorum
        );
        council = Council(address(new ERC1967Proxy(address(councilImpl), councilInit)));

        // governor behind a proxy, constituted by the council above
        Governor governorImpl = new Governor(address(0));
        bytes memory governorInit = abi.encodeCall(
            Governor.initialize,
            (address(council), new DelegateRegistration[](0), new VotingParametersRegistration[](0))
        );
        governor = Governor(payable(address(new ERC1967Proxy(address(governorImpl), governorInit))));

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
        bytes memory init = abi.encodeCall(Council.initialize, (address(this), TWO_THIRDS_BPS, TWO_THIRDS_BPS, VOTING_PERIOD, members));
        return Council(address(new ERC1967Proxy(address(impl), init)));
    }

    function _deploySpokeGovernor() internal returns (Governor) {
        address[] memory spokeMembers = new address[](3);
        spokeMembers[0] = dave;
        spokeMembers[1] = erin;
        spokeMembers[2] = frank;
        Council spokeCouncil = _deployCouncil(spokeMembers);

        Governor impl = new Governor(address(0));
        bytes memory init = abi.encodeCall(
            Governor.initialize,
            (address(spokeCouncil), new DelegateRegistration[](0), new VotingParametersRegistration[](0))
        );
        return Governor(payable(address(new ERC1967Proxy(address(impl), init))));
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
            authority: FunctionAuthority.Hard
        });

        Governor dGovernorImpl = new Governor(address(0));
        bytes memory dGovernorInit = abi.encodeCall(
            Governor.initialize,
            (address(dCouncil), registrations, new VotingParametersRegistration[](0))
        );
        dGovernor = Governor(payable(address(new ERC1967Proxy(address(dGovernorImpl), dGovernorInit))));

        dPool.transferOwnership(address(dGovernor));
    }

    // Same hub/spoke shape as _setupDelegatedHub, with the delegation keyed on
    // a caller-supplied target+selector.
    function _setupDelegatedTreasury(address target, bytes4 selector)
        internal
        returns (Governor dGovernor, Governor spokeGovernor)
    {
        spokeGovernor = _deploySpokeGovernor();

        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
        Council dCouncil = _deployCouncil(members);

        DelegateRegistration[] memory registrations = new DelegateRegistration[](1);
        registrations[0] = DelegateRegistration({
            target: target,
            delegate: address(spokeGovernor),
            selector: selector,
            authority: FunctionAuthority.Hard
        });

        Governor impl = new Governor(address(0));
        bytes memory init = abi.encodeCall(
            Governor.initialize,
            (address(dCouncil), registrations, new VotingParametersRegistration[](0))
        );
        dGovernor = Governor(payable(address(new ERC1967Proxy(address(impl), init))));
        vm.deal(address(dGovernor), 10 ether);
    }

    function _voteUnanimouslyOn(Governor g, uint256 proposalId, address[3] memory voters) internal {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(voters[i]);
            g.vote(proposalId, true);
        }
    }

    // Votes the spoke's mirrored approval proposal through. Must happen before
    // the voting period closes, i.e. before any warp.
    function _voteOnSpokeApproval(Governor spokeGovernor, address hub, uint256 hubProposalId) internal {
        uint256 spokeProposalId = spokeGovernor.approvalProposalId(hub, hubProposalId);
        require(spokeProposalId != 0, "no spoke approval proposal was created");
        _voteUnanimouslyOn(spokeGovernor, spokeProposalId, [dave, erin, frank]);
    }

    // Executes an already-voted spoke approval. Must happen after the warp.
    function _executeSpokeApproval(Governor spokeGovernor, address hub, uint256 hubProposalId) internal {
        uint256 spokeProposalId = spokeGovernor.approvalProposalId(hub, hubProposalId);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(spokeGovernor);
        calldatas[0] = abi.encodeWithSelector(spokeGovernor.approveProposal.selector, hub, hubProposalId);

        spokeGovernor.execute(
            spokeProposalId,
            0,
            targets,
            values,
            calldatas,
            keccak256(abi.encode("approval", hub, hubProposalId))
        );
    }

    // Single-spoke convenience: vote, warp past the voting period, execute.
    // Any hub votes must already be cast before calling this.
    function _approveViaSpoke(Governor spokeGovernor, address hub, uint256 hubProposalId) internal {
        _voteOnSpokeApproval(spokeGovernor, hub, hubProposalId);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _executeSpokeApproval(spokeGovernor, hub, hubProposalId);
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

    function test_GetVotingPowerMatchesMembership() public {
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
        council.initialize(address(this), TWO_THIRDS_BPS, TWO_THIRDS_BPS, VOTING_PERIOD, members);
    }

    function test_RevertWhen_GovernorDoubleInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        governor.initialize(address(council), new DelegateRegistration[](0), new VotingParametersRegistration[](0));
    }

    function test_RevertWhen_DuplicateCouncilMemberAtInit() public {
        Council councilImpl = new Council();
        address[] memory members = new address[](2);
        members[0] = alice;
        members[1] = alice;
        bytes memory init = abi.encodeCall(Council.initialize, (address(this), TWO_THIRDS_BPS, TWO_THIRDS_BPS, VOTING_PERIOD, members));

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
        bytes memory init = abi.encodeCall(Council.initialize, (address(this), TWO_THIRDS_BPS, TWO_THIRDS_BPS, VOTING_PERIOD, members));
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
        governor.setDelegateGovernance(address(pool), MockVillagePool.setFeeBps.selector, outsider, FunctionAuthority.Hard);
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

    function test_CouncilDefaultVotingParametersMatchInitialize() public  {
        VotingParameters memory params = council.getDefaultVotingParameters();
        assertEq(params.quorumBps, TWO_THIRDS_BPS);
        assertEq(params.thresholdBps, TWO_THIRDS_BPS);
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
        assertEq(p.quorumBps, TWO_THIRDS_BPS);
        assertEq(p.thresholdBps, TWO_THIRDS_BPS);
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

        Governor seededGovernorImpl = new Governor(address(0));
        bytes memory governorInit = abi.encodeCall(
            Governor.initialize,
            (address(council), new DelegateRegistration[](0), votingRegs)
        );
        Governor seededGovernor = Governor(payable(address(new ERC1967Proxy(address(seededGovernorImpl), governorInit))));
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

        Governor impl = new Governor(address(0));
        bytes memory init = abi.encodeCall(
            Governor.initialize,
            (address(council), new DelegateRegistration[](0), votingRegs)
        );
        Governor multiGovernor = Governor(payable(address(new ERC1967Proxy(address(impl), init))));
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

        Governor impl = new Governor(address(0));
        bytes memory init = abi.encodeCall(
            Governor.initialize,
            (address(council), new DelegateRegistration[](0), votingRegs)
        );
        Governor seededGovernor = Governor(payable(address(new ERC1967Proxy(address(impl), init))));
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
        assertEq(p.quorumBps, TWO_THIRDS_BPS, "quorum should fall back to the council default");
        assertEq(p.thresholdBps, TWO_THIRDS_BPS, "threshold should fall back to the council default");
        assertEq(p.voteEnd - p.voteStart, 5 hours, "voting period should use the registered override");
    }

    // ---------------------------------------------------------------
    // treasury outflows: raw ETH (no selector) and ERC20 transfers
    // ---------------------------------------------------------------

    function _ethPayout(uint256 amount)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = treasury;
        values[0] = amount;
        calldatas[0] = ""; // raw transfer: no selector, so no rule can key on it
        descriptionHash = keccak256(bytes("raw eth payout"));
    }

    function _tokenPayout(MockTreasuryToken token, uint256 amount)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(token);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (treasury, amount));
        descriptionHash = keccak256(bytes("token payout"));
    }

    // regression: an unregistered raw payout behaves exactly as before
    function test_UnregisteredRawEthPayoutStillUsesCouncilDefaults() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _ethPayout(1 ether);

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);

        Proposal memory p = governor.getProposal(proposalId);
        assertEq(p.quorumBps, TWO_THIRDS_BPS);
        assertEq(p.thresholdBps, TWO_THIRDS_BPS);
        assertEq(p.voteEnd - p.voteStart, VOTING_PERIOD);
        assertEq(governor.getProposal(proposalId).proposer, alice);
    }

    // ERC20 payouts need no special handling -- they are ordinary calls,
    // gated by (token address, transfer selector)
    function test_RevertWhen_HubExecutesTokenPayoutWithoutSpokeApproval() public {
        MockTreasuryToken token = new MockTreasuryToken();
        (Governor dGovernor, ) = _setupDelegatedTreasury(address(token), IERC20.transfer.selector);
        token.mint(address(dGovernor), 1_000e18);

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _tokenPayout(token, 250e18);

        vm.prank(alice);
        uint256 proposalId = dGovernor.propose(targets, values, calldatas, descriptionHash);
        _voteUnanimouslyOn(dGovernor, proposalId, [alice, bob, carol]);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("delegate approval missing");
        dGovernor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(token.balanceOf(treasury), 0);
    }

    function test_HubExecutesTokenPayoutAfterSpokeApproves() public {
        MockTreasuryToken token = new MockTreasuryToken();
        (Governor dGovernor, Governor spokeGovernor) =
            _setupDelegatedTreasury(address(token), IERC20.transfer.selector);
        token.mint(address(dGovernor), 1_000e18);

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _tokenPayout(token, 250e18);

        vm.prank(alice);
        uint256 proposalId = dGovernor.propose(targets, values, calldatas, descriptionHash);
        _voteUnanimouslyOn(dGovernor, proposalId, [alice, bob, carol]);

        _approveViaSpoke(spokeGovernor, address(dGovernor), proposalId);

        dGovernor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
        assertEq(token.balanceOf(treasury), 250e18);
        assertEq(token.balanceOf(address(dGovernor)), 750e18);
    }

    function test_TokenPayoutPicksUpVotingParameterOverrides() public {
        MockTreasuryToken token = new MockTreasuryToken();

        VotingParametersRegistration[] memory votingRegs = new VotingParametersRegistration[](1);
        votingRegs[0] = VotingParametersRegistration({
            target: address(token),
            selector: IERC20.transfer.selector,
            params: VotingParameters({quorumBps: 8000, thresholdBps: 8000, votingPeriod: 5 days})
        });

        Governor impl = new Governor(address(0));
        bytes memory init = abi.encodeCall(
            Governor.initialize,
            (address(council), new DelegateRegistration[](0), votingRegs)
        );
        Governor g = Governor(payable(address(new ERC1967Proxy(address(impl), init))));

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _tokenPayout(token, 100e18);

        vm.prank(alice);
        uint256 proposalId = g.propose(targets, values, calldatas, descriptionHash);

        Proposal memory p = g.getProposal(proposalId);
        assertEq(p.quorumBps, 8000);
        assertEq(p.thresholdBps, 8000);
        assertEq(p.voteEnd - p.voteStart, 5 days);
    }

    // ---------------------------------------------------------------
    // wildcard (target-wide) registration
    // ---------------------------------------------------------------

    // the enumeration hole closed: one wildcard registration covers approve
    // without anyone having had to think of approve
    function test_WildcardDelegateCoversAnUnenumeratedSelector() public {
        MockTreasuryToken token = new MockTreasuryToken();
        (Governor dGovernor, ) = _setupDelegatedTreasury(address(token), 0xffffffff);
        token.mint(address(dGovernor), 1_000e18);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(token);
        calldatas[0] = abi.encodeCall(IERC20.approve, (outsider, type(uint256).max));
        bytes32 descriptionHash = keccak256(bytes("unlimited approval, now gated"));

        vm.prank(alice);
        uint256 proposalId = dGovernor.propose(targets, values, calldatas, descriptionHash);
        _voteUnanimouslyOn(dGovernor, proposalId, [alice, bob, carol]);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("delegate approval missing");
        dGovernor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(token.allowance(address(dGovernor), outsider), 0);
    }

    function test_WildcardDelegateStillLetsApprovedCallsThrough() public {
        MockTreasuryToken token = new MockTreasuryToken();
        (Governor dGovernor, Governor spokeGovernor) = _setupDelegatedTreasury(address(token), 0xffffffff);
        token.mint(address(dGovernor), 1_000e18);

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _tokenPayout(token, 250e18);

        vm.prank(alice);
        uint256 proposalId = dGovernor.propose(targets, values, calldatas, descriptionHash);
        _voteUnanimouslyOn(dGovernor, proposalId, [alice, bob, carol]);

        _approveViaSpoke(spokeGovernor, address(dGovernor), proposalId);
        dGovernor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(token.balanceOf(treasury), 250e18);
    }

    // a wildcard is a floor: a narrower rule adds a second signature rather
    // than replacing the blanket one
    function test_WildcardAndSpecificDelegatesBothMustApprove() public {
        MockTreasuryToken token = new MockTreasuryToken();
        Governor wildcardSpoke = _deploySpokeGovernor();
        Governor specificSpoke = _deploySpokeGovernor();

        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
        Council dCouncil = _deployCouncil(members);

        DelegateRegistration[] memory registrations = new DelegateRegistration[](2);
        registrations[0] = DelegateRegistration({
            target: address(token),
            delegate: address(wildcardSpoke),
            selector: 0xffffffff,
            authority: FunctionAuthority.Hard
        });
        registrations[1] = DelegateRegistration({
            target: address(token),
            delegate: address(specificSpoke),
            selector: IERC20.transfer.selector,
            authority: FunctionAuthority.Hard
        });

        Governor impl = new Governor(address(0));
        Governor dGovernor = Governor(payable(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Governor.initialize, (address(dCouncil), registrations, new VotingParametersRegistration[](0)))
        ))));
        token.mint(address(dGovernor), 1_000e18);

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _tokenPayout(token, 100e18);

        vm.prank(alice);
        uint256 proposalId = dGovernor.propose(targets, values, calldatas, descriptionHash);
        _voteUnanimouslyOn(dGovernor, proposalId, [alice, bob, carol]);

        // both spokes vote while voting is still open
        _voteOnSpokeApproval(wildcardSpoke, address(dGovernor), proposalId);
        _voteOnSpokeApproval(specificSpoke, address(dGovernor), proposalId);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // only the wildcard spoke's approval lands -- the specific one still gates it
        _executeSpokeApproval(wildcardSpoke, address(dGovernor), proposalId);
        vm.expectRevert("delegate approval missing");
        dGovernor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        _executeSpokeApproval(specificSpoke, address(dGovernor), proposalId);
        dGovernor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
        assertEq(token.balanceOf(treasury), 100e18);
    }

    // parameters take the max across both rules, so a lenient specific
    // registration cannot undercut a strict blanket one
    function test_WildcardVotingParametersAreAFloorForSpecificOnes() public {
        MockTreasuryToken token = new MockTreasuryToken();

        VotingParametersRegistration[] memory votingRegs = new VotingParametersRegistration[](2);
        votingRegs[0] = VotingParametersRegistration({
            target: address(token),
            selector: 0xffffffff,
            params: VotingParameters({quorumBps: 9000, thresholdBps: 9000, votingPeriod: 10 days})
        });
        votingRegs[1] = VotingParametersRegistration({
            target: address(token),
            selector: IERC20.transfer.selector,
            params: VotingParameters({quorumBps: 1000, thresholdBps: 1000, votingPeriod: 1 hours})
        });

        Governor impl = new Governor(address(0));
        Governor g = Governor(payable(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Governor.initialize, (address(council), new DelegateRegistration[](0), votingRegs))
        ))));

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _tokenPayout(token, 1e18);

        vm.prank(alice);
        uint256 proposalId = g.propose(targets, values, calldatas, descriptionHash);

        Proposal memory p = g.getProposal(proposalId);
        assertEq(p.quorumBps, 9000, "the lenient specific rule must not undercut the wildcard");
        assertEq(p.thresholdBps, 9000);
        assertEq(p.voteEnd - p.voteStart, 10 days);
    }

    function test_UnrelatedTargetsAreUnaffectedByAWildcard() public {
        MockTreasuryToken token = new MockTreasuryToken();
        (Governor dGovernor, ) = _setupDelegatedTreasury(address(token), 0xffffffff);

        // a payout to `treasury`, which carries no registration of its own
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _ethPayout(1 ether);

        vm.prank(alice);
        uint256 proposalId = dGovernor.propose(targets, values, calldatas, descriptionHash);
        _voteUnanimouslyOn(dGovernor, proposalId, [alice, bob, carol]);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        dGovernor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
        assertEq(treasury.balance, 1 ether);
    }

    function test_ANY_SELECTOR_IsTheMaxSelector() public {
        assertEq(governor.ANY_SELECTOR(), bytes4(0xffffffff));
    }

    function _deployUngatedGovernor() internal returns (Governor) {
        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
        Council c = _deployCouncil(members);

        Governor impl = new Governor(address(0));
        return Governor(payable(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Governor.initialize, (address(c), new DelegateRegistration[](0), new VotingParametersRegistration[](0)))
        ))));
    }

    function _passProposal(Governor g, address target, bytes memory data, bytes32 descriptionHash)
        internal
        returns (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        calldatas[0] = data;

        vm.prank(alice);
        proposalId = g.propose(targets, values, calldatas, descriptionHash);
        _voteUnanimouslyOn(g, proposalId, [alice, bob, carol]);
    }

    // A per-selector delegation gates `withdrawTo` but not `transferOwnership`,
    // so the hub can hand the pool to a governor that has no delegation at all
    // and walk away from the spoke's veto entirely. The escape hatch and the
    // vulnerability are the same door.
    function test_PerSelectorDelegationIsEscapableViaTransferOwnership() public {
        (Governor dGovernor, , MockVillagePool dPool) = _setupDelegatedHub();
        vm.deal(address(dPool), 5 ether);
        Governor ungated = _deployUngatedGovernor();

        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas
        ) = _passProposal(
            dGovernor,
            address(dPool),
            abi.encodeCall(Ownable.transferOwnership, (address(ungated))),
            keccak256("hand the pool to an ungated governor")
        );

        // no spoke sign-off was ever required
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        dGovernor.execute(proposalId, 0, targets, values, calldatas, keccak256("hand the pool to an ungated governor"));
        assertEq(dPool.owner(), address(ungated));

        // and the spoke's veto over withdrawals is now worth nothing
        (proposalId, targets, values, calldatas) = _passProposal(
            ungated,
            address(dPool),
            abi.encodeCall(MockVillagePool.withdrawTo, (payable(treasury), 5 ether)),
            keccak256("drain it")
        );
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        ungated.execute(proposalId, 0, targets, values, calldatas, keccak256("drain it"));

        assertEq(treasury.balance, 5 ether, "spoke veto bypassed by moving ownership");
    }

    // With a wildcard the same escape is closed: transferOwnership is a call
    // to the pool like any other, so it needs the spoke's sign-off too.
    function test_WildcardDelegationBlocksTheTransferOwnershipEscape() public {
        MockVillagePool dPool = new MockVillagePool(address(this));
        (Governor dGovernor, ) = _setupDelegatedTreasury(address(dPool), 0xffffffff);
        dPool.transferOwnership(address(dGovernor));
        vm.deal(address(dPool), 5 ether);

        Governor ungated = _deployUngatedGovernor();

        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas
        ) = _passProposal(
            dGovernor,
            address(dPool),
            abi.encodeCall(Ownable.transferOwnership, (address(ungated))),
            keccak256("try to escape")
        );

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("delegate approval missing");
        dGovernor.execute(proposalId, 0, targets, values, calldatas, keccak256("try to escape"));

        assertEq(dPool.owner(), address(dGovernor), "ownership must not move without the spoke");
    }

    // The gate holds against indirection too, for an onlyOwner target: the
    // governor cannot route the call through a helper, because the pool checks
    // msg.sender and only the governor is the owner.
    function test_WildcardCannotBeRoutedAroundViaAHelperContract() public {
        MockVillagePool dPool = new MockVillagePool(address(this));
        (Governor dGovernor, ) = _setupDelegatedTreasury(address(dPool), 0xffffffff);
        dPool.transferOwnership(address(dGovernor));
        vm.deal(address(dPool), 5 ether);

        PoolCaller helper = new PoolCaller();

        // the helper is an unregistered target, so this proposal needs no
        // spoke approval -- but the pool rejects it, since the helper is not
        // the owner
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas
        ) = _passProposal(
            dGovernor,
            address(helper),
            abi.encodeCall(PoolCaller.drain, (dPool, payable(treasury), 5 ether)),
            keccak256("route around via helper")
        );

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(helper)));
        dGovernor.execute(proposalId, 0, targets, values, calldatas, keccak256("route around via helper"));

        assertEq(treasury.balance, 0);
    }

    // Gating `transfer` alone is not enough: an approval hands the tokens over
    // just as effectively, under a different selector. Registering only one of
    // them leaves the other ungated -- which is what ANY_SELECTOR is for.
    function test_ApproveIsGatedSeparatelyFromTransfer() public {
        MockTreasuryToken token = new MockTreasuryToken();
        (Governor dGovernor, ) = _setupDelegatedTreasury(address(token), IERC20.transfer.selector);
        token.mint(address(dGovernor), 1_000e18);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(token);
        calldatas[0] = abi.encodeCall(IERC20.approve, (outsider, type(uint256).max));
        bytes32 descriptionHash = keccak256(bytes("unlimited approval"));

        vm.prank(alice);
        uint256 proposalId = dGovernor.propose(targets, values, calldatas, descriptionHash);
        _voteUnanimouslyOn(dGovernor, proposalId, [alice, bob, carol]);

        // no spoke sign-off was required: `approve` is a different selector
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        dGovernor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(token.allowance(address(dGovernor), outsider), type(uint256).max);

        // ...and that allowance drains the treasury without governance again
        vm.prank(outsider);
        token.transferFrom(address(dGovernor), outsider, 1_000e18);
        assertEq(token.balanceOf(address(dGovernor)), 0);
    }

    // ---------------------------------------------------------------
    // delegate collection: dedup and multiple spokes
    // ---------------------------------------------------------------

    function _deployHubWith(DelegateRegistration[] memory registrations) internal returns (Governor) {
        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
        Council c = _deployCouncil(members);

        Governor impl = new Governor(address(0));
        return Governor(payable(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Governor.initialize, (address(c), registrations, new VotingParametersRegistration[](0)))
        ))));
    }

    function _delegateRegistration(address target, address spoke, bytes4 selector)
        internal
        pure
        returns (DelegateRegistration memory)
    {
        return DelegateRegistration({
            target: target,
            delegate: spoke,
            selector: selector,
            authority: FunctionAuthority.Hard
        });
    }

    // counts ProposalCreated events emitted by a specific governor since the
    // last vm.recordLogs()
    function _countProposalsCreatedBy(address governorAddr) internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == governorAddr && logs[i].topics[0] == Governor.ProposalCreated.selector) {
                count++;
            }
        }
    }

    // `delegates` is a public array getter, so an out-of-range index reverts;
    // that is how we assert the list is exactly `expected` long
    function _assertDelegateList(Governor g, uint256 proposalId, address[] memory expected) internal {
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(g.delegates(proposalId, i), expected[i], "unexpected delegate at index");
        }
        (bool ok, ) = address(g).staticcall(
            abi.encodeWithSignature("delegates(uint256,uint256)", proposalId, expected.length)
        );
        assertFalse(ok, "delegate list is longer than expected");
    }

    function _twoPoolWithdrawal(MockVillagePool poolA, MockVillagePool poolB)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](2);
        values = new uint256[](2);
        calldatas = new bytes[](2);
        targets[0] = address(poolA);
        targets[1] = address(poolB);
        calldatas[0] = abi.encodeCall(MockVillagePool.withdrawTo, (payable(treasury), 1 ether));
        calldatas[1] = abi.encodeCall(MockVillagePool.withdrawTo, (payable(treasury), 1 ether));
        descriptionHash = keccak256("drain both pools");
    }

    // two actions, both delegated to the same spoke: the spoke should be asked
    // once, not twice -- proposeApproval is idempotent per (hub, proposalId)
    // and _addDelegate dedupes the requirement list
    function test_OneSpokeAcrossTwoActionsCreatesASingleApprovalProposal() public {
        Governor spoke = _deploySpokeGovernor();
        MockVillagePool poolA = new MockVillagePool(address(this));
        MockVillagePool poolB = new MockVillagePool(address(this));

        DelegateRegistration[] memory regs = new DelegateRegistration[](2);
        regs[0] = _delegateRegistration(address(poolA), address(spoke), MockVillagePool.withdrawTo.selector);
        regs[1] = _delegateRegistration(address(poolB), address(spoke), MockVillagePool.withdrawTo.selector);

        Governor hub = _deployHubWith(regs);
        poolA.transferOwnership(address(hub));
        poolB.transferOwnership(address(hub));
        vm.deal(address(poolA), 1 ether);
        vm.deal(address(poolB), 1 ether);

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _twoPoolWithdrawal(poolA, poolB);

        vm.recordLogs();
        vm.prank(alice);
        uint256 proposalId = hub.propose(targets, values, calldatas, descriptionHash);

        assertEq(_countProposalsCreatedBy(address(spoke)), 1, "spoke must open exactly one approval proposal");

        address[] memory expected = new address[](1);
        expected[0] = address(spoke);
        _assertDelegateList(hub, proposalId, expected);

        // and a single approval unlocks both actions
        _voteUnanimouslyOn(hub, proposalId, [alice, bob, carol]);
        _approveViaSpoke(spoke, address(hub), proposalId);

        hub.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
        assertEq(treasury.balance, 2 ether);
    }

    // two actions delegated to two different spokes: both are recorded, and
    // both signatures are required
    function test_TwoSpokesAcrossTwoActionsBothMustApprove() public {
        Governor spokeA = _deploySpokeGovernor();
        Governor spokeB = _deploySpokeGovernor();
        MockVillagePool poolA = new MockVillagePool(address(this));
        MockVillagePool poolB = new MockVillagePool(address(this));

        DelegateRegistration[] memory regs = new DelegateRegistration[](2);
        regs[0] = _delegateRegistration(address(poolA), address(spokeA), MockVillagePool.withdrawTo.selector);
        regs[1] = _delegateRegistration(address(poolB), address(spokeB), MockVillagePool.withdrawTo.selector);

        Governor hub = _deployHubWith(regs);
        poolA.transferOwnership(address(hub));
        poolB.transferOwnership(address(hub));
        vm.deal(address(poolA), 1 ether);
        vm.deal(address(poolB), 1 ether);

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _twoPoolWithdrawal(poolA, poolB);

        vm.recordLogs();
        vm.prank(alice);
        uint256 proposalId = hub.propose(targets, values, calldatas, descriptionHash);

        assertEq(_countProposalsCreatedBy(address(spokeA)), 1);
        assertEq(_countProposalsCreatedBy(address(spokeB)), 0, "getRecordedLogs drains the buffer");

        address[] memory expected = new address[](2);
        expected[0] = address(spokeA);
        expected[1] = address(spokeB);
        _assertDelegateList(hub, proposalId, expected);

        _voteUnanimouslyOn(hub, proposalId, [alice, bob, carol]);
        _voteOnSpokeApproval(spokeA, address(hub), proposalId);
        _voteOnSpokeApproval(spokeB, address(hub), proposalId);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // only spokeA has signed: still blocked
        _executeSpokeApproval(spokeA, address(hub), proposalId);
        vm.expectRevert("delegate approval missing");
        hub.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        _executeSpokeApproval(spokeB, address(hub), proposalId);
        hub.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
        assertEq(treasury.balance, 2 ether);
    }

    // a wildcard and a specific rule that name the same spoke must also
    // collapse to one requirement, even though _applyRules runs twice
    function test_WildcardAndSpecificOnTheSameSpokeCountOnce() public {
        Governor spoke = _deploySpokeGovernor();
        MockTreasuryToken token = new MockTreasuryToken();

        DelegateRegistration[] memory regs = new DelegateRegistration[](2);
        regs[0] = _delegateRegistration(address(token), address(spoke), 0xffffffff);
        regs[1] = _delegateRegistration(address(token), address(spoke), IERC20.transfer.selector);

        Governor hub = _deployHubWith(regs);
        token.mint(address(hub), 1_000e18);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(token);
        calldatas[0] = abi.encodeCall(IERC20.transfer, (treasury, 100e18));
        bytes32 descriptionHash = keccak256("one spoke, two matching rules");

        vm.recordLogs();
        vm.prank(alice);
        uint256 proposalId = hub.propose(targets, values, calldatas, descriptionHash);

        assertEq(_countProposalsCreatedBy(address(spoke)), 1, "matched twice, asked once");

        address[] memory expected = new address[](1);
        expected[0] = address(spoke);
        _assertDelegateList(hub, proposalId, expected);

        _voteUnanimouslyOn(hub, proposalId, [alice, bob, carol]);
        _approveViaSpoke(spoke, address(hub), proposalId);

        hub.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
        assertEq(token.balanceOf(treasury), 100e18);
    }

    // ---------------------------------------------------------------
    // rescue
    // ---------------------------------------------------------------

    function test_RescueSweepsStrayEth() public {
        vm.deal(address(governor), 3 ether);

        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas
        ) = _passProposal(
            governor,
            address(governor),
            abi.encodeCall(Governor.rescue, (address(0), treasury, 1 ether)),
            keccak256("rescue some eth")
        );

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, keccak256("rescue some eth"));

        assertEq(treasury.balance, 1 ether);
        assertEq(address(governor).balance, 2 ether);
    }

    // the amount is fixed in the actionHash at propose time, so max means
    // "whatever is here when it executes"
    function test_RescueMaxSweepsWhateverArrivedLater() public {
        vm.deal(address(governor), 1 ether);

        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas
        ) = _passProposal(
            governor,
            address(governor),
            abi.encodeCall(Governor.rescue, (address(0), treasury, type(uint256).max)),
            keccak256("sweep it all")
        );

        // more shows up between proposing and executing
        vm.deal(address(governor), 4 ether);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, keccak256("sweep it all"));

        assertEq(treasury.balance, 4 ether);
        assertEq(address(governor).balance, 0);
    }

    function test_RescueSweepsStrayTokens() public {
        MockTreasuryToken token = new MockTreasuryToken();
        token.mint(address(governor), 500e18);

        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas
        ) = _passProposal(
            governor,
            address(governor),
            abi.encodeCall(Governor.rescue, (address(token), treasury, type(uint256).max)),
            keccak256("rescue tokens")
        );

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, keccak256("rescue tokens"));

        assertEq(token.balanceOf(treasury), 500e18);
        assertEq(token.balanceOf(address(governor)), 0);
    }

    function test_RevertWhen_RescueCalledDirectly() public {
        vm.deal(address(governor), 1 ether);

        vm.prank(alice); // a council member, still not governance
        vm.expectRevert("only via executed proposal");
        governor.rescue(address(0), alice, 1 ether);

        vm.prank(outsider);
        vm.expectRevert("only via executed proposal");
        governor.rescue(address(0), outsider, 1 ether);

        assertEq(address(governor).balance, 1 ether);
    }

    function test_RevertWhen_RescuingToZeroAddress() public {
        vm.deal(address(governor), 1 ether);

        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas
        ) = _passProposal(
            governor,
            address(governor),
            abi.encodeCall(Governor.rescue, (address(0), address(0), 1 ether)),
            keccak256("rescue to nowhere")
        );

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("cannot rescue to zero address");
        governor.execute(proposalId, 0, targets, values, calldatas, keccak256("rescue to nowhere"));
    }

    function test_RevertWhen_RescuingMoreEthThanHeld() public {
        vm.deal(address(governor), 1 ether);

        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas
        ) = _passProposal(
            governor,
            address(governor),
            abi.encodeCall(Governor.rescue, (address(0), treasury, 5 ether)),
            keccak256("rescue too much")
        );

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("insufficient balance");
        governor.execute(proposalId, 0, targets, values, calldatas, keccak256("rescue too much"));
    }
}
