// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

import {Governor, DelegateRegistration, VotingParametersRegistration} from "../src/governance/Governer.sol";
import {Proposal} from "../src/governance/interface/IGoverner.sol";
import {Council} from "../src/governance/constitution/council/council.sol";
import {GovernerFactory} from "../src/governance/GovernerFactory.sol";
import {ConstitutionRegistry} from "../src/governance/constitution/ConstitutionRegistry.sol";

// Covers the new bootstrap path: ConstitutionRegistry + GovernerFactory clone a
// constitution and a governor together in one call, and the resulting governor
// accepts gasless (ERC-2771 relayed) propose/vote through a trusted forwarder.
contract GovernerFactoryTest is Test {
    bytes32 constant FORWARD_REQUEST_TYPEHASH =
        keccak256("ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)");

    uint256 constant VOTING_PERIOD = 3 days;

    ConstitutionRegistry registry;
    GovernerFactory factory;
    Council councilImpl;
    Governor governorImpl;
    ERC2771Forwarder forwarder;

    address alice;
    uint256 alicePk;
    address bob;
    uint256 bobPk;
    address carol = makeAddr("carol");
    address outsider = makeAddr("outsider");
    address treasury = makeAddr("treasury");

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");

        registry = new ConstitutionRegistry(address(this));
        councilImpl = new Council();
        registry.registerConstitution(1, address(councilImpl));

        forwarder = new ERC2771Forwarder("RWAGovForwarder");
        governorImpl = new Governor(address(forwarder));

        factory = new GovernerFactory(address(this), address(registry));
        factory.registerGovernance(1, address(governorImpl));
    }

    function _councilInitData(uint16 quorumBps, uint16 thresholdBps) internal view returns (bytes memory) {
        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
        return abi.encodeCall(Council.initialize, (address(this), quorumBps, thresholdBps, VOTING_PERIOD, members));
    }

    function _deployVillageGovernance() internal returns (Governor governor, Council council) {
        // 50/50 quorum+threshold so 2-of-3 passes cleanly
        (address g, address s) = factory.deployGovernance(
            1,
            1,
            _councilInitData(5000, 5000),
            new DelegateRegistration[](0),
            new VotingParametersRegistration[](0)
        );
        governor = Governor(payable(g));
        council = Council(s);
    }

    // ---------------------------------------------------------------
    // atomic governor + constitution bootstrap
    // ---------------------------------------------------------------

    function test_DeployGovernanceClonesGovernorAndConstitutionTogether() public {
        (Governor governor, Council council) = _deployVillageGovernance();

        assertEq(governor.constitution(), address(council));
        assertTrue(council.isCouncil(alice));
        assertTrue(council.isCouncil(bob));
        assertTrue(council.isCouncil(carol));
    }

    function test_ClonedGovernorAndConstitutionAreIndependentInstances() public {
        (Governor governorA, Council councilA) = _deployVillageGovernance();
        (Governor governorB, Council councilB) = _deployVillageGovernance();

        assertTrue(address(governorA) != address(governorB));
        assertTrue(address(councilA) != address(councilB));

        councilA.removeCouncilMember(alice);
        assertFalse(councilA.isCouncil(alice));
        assertTrue(councilB.isCouncil(alice), "clones must not share storage");
    }

    function test_RevertWhen_DeployingUnknownGovernanceVersion() public {
        vm.expectRevert("unknown governance version");
        factory.deployGovernance(
            99, 1, _councilInitData(5000, 5000),
            new DelegateRegistration[](0), new VotingParametersRegistration[](0)
        );
    }

    function test_RevertWhen_DeployingUnknownConstitutionVersion() public {
        vm.expectRevert("unknown constitution version");
        factory.deployGovernance(
            1, 99, _councilInitData(5000, 5000),
            new DelegateRegistration[](0), new VotingParametersRegistration[](0)
        );
    }

    function test_RevertWhen_RegisteringGovernanceVersionTwice() public {
        address newImpl = address(new Governor(address(forwarder)));
        vm.expectRevert("version already registered");
        factory.registerGovernance(1, newImpl);
    }

    // ---------------------------------------------------------------
    // deprecation
    // ---------------------------------------------------------------

    function test_RevertWhen_DeployingADeprecatedGovernanceVersion() public {
        factory.setDeprecated(1, true);
        assertTrue(factory.deprecated(1));

        vm.expectRevert("governance version deprecated");
        factory.deployGovernance(
            1, 1, _councilInitData(5000, 5000),
            new DelegateRegistration[](0), new VotingParametersRegistration[](0)
        );
    }

    // governors cloned before the deprecation keep working: the clone's
    // implementation address is immutable, deprecation only gates new deploys
    function test_DeprecationLeavesExistingGovernorsRunning() public {
        (Governor governor, ) = _deployVillageGovernance();
        factory.setDeprecated(1, true);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = treasury;
        calldatas[0] = "";

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, keccak256("still alive"));
        assertEq(governor.getProposal(proposalId).proposer, alice);
    }

    function test_UndeprecatingRestoresDeployability() public {
        factory.setDeprecated(1, true);
        factory.setDeprecated(1, false);

        (Governor governor, Council council) = _deployVillageGovernance();
        assertEq(governor.constitution(), address(council));
    }

    // the factory routes constitution deployment through the registry, so a
    // constitution retired there blocks new governors too
    function test_RevertWhen_ConstitutionVersionIsDeprecatedInTheRegistry() public {
        registry.setDeprecated(1, true);

        vm.expectRevert("constitution version deprecated");
        factory.deployGovernance(
            1, 1, _councilInitData(5000, 5000),
            new DelegateRegistration[](0), new VotingParametersRegistration[](0)
        );
    }

    function test_RevertWhen_DeprecatingUnknownGovernanceVersion() public {
        vm.expectRevert("unknown governance version");
        factory.setDeprecated(99, true);
    }

    function test_RevertWhen_NonOwnerDeprecatesGovernance() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        factory.setDeprecated(1, true);
    }

    // ---------------------------------------------------------------
    // treasury
    // ---------------------------------------------------------------

    // the proposal records amounts, it does not escrow them -- the ETH is
    // pulled from the governor's own balance at execution time
    function test_RevertWhen_ExecutingAValueProposalWithAnEmptyTreasury() public {
        (Governor governor, ) = _deployVillageGovernance();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = treasury;
        values[0] = 1 ether;
        calldatas[0] = "";
        bytes32 descriptionHash = keccak256("unfunded payout");

        // proposing costs nothing and moves no ETH
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);
        assertEq(address(governor).balance, 0, "proposing must not escrow value");

        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert("Governor: call reverted without reason");
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        // and the proposal is still executable once funded
        vm.deal(address(governor), 1 ether);
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
        assertEq(treasury.balance, 1 ether);
    }

    // a sponsor covers the shortfall in the same tx that executes, so their
    // ETH is only spent if the execution actually succeeds
    function test_SponsorCanFundAShortfallWhileExecuting() public {
        (Governor governor, ) = _deployVillageGovernance();
        vm.deal(address(governor), 0.4 ether);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = treasury;
        values[0] = 1 ether;
        calldatas[0] = "";
        bytes32 descriptionHash = keccak256("sponsored payout");

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);
        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        address sponsor = makeAddr("sponsor");
        vm.deal(sponsor, 1 ether);
        vm.prank(sponsor);
        governor.execute{value: 0.6 ether}(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(treasury.balance, 1 ether);
        assertEq(sponsor.balance, 0.4 ether);
        assertEq(address(governor).balance, 0);
    }

    // the sponsor's value is at risk only alongside the execution itself: a
    // reverting execution takes their transfer back with it
    function test_SponsorValueIsReturnedWhenExecutionReverts() public {
        (Governor governor, ) = _deployVillageGovernance();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = treasury;
        values[0] = 1 ether;
        calldatas[0] = "";
        bytes32 descriptionHash = keccak256("doomed payout");

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);
        vm.prank(alice);
        governor.vote(proposalId, true); // one vote only -- below threshold

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        address sponsor = makeAddr("sponsor");
        vm.deal(sponsor, 1 ether);
        vm.prank(sponsor);
        vm.expectRevert("Proposal did not pass");
        governor.execute{value: 1 ether}(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(sponsor.balance, 1 ether, "sponsor keeps their ETH when execution fails");
        assertEq(address(governor).balance, 0);
    }

    // attached value cannot change what a proposal sends -- amounts are fixed
    // in the actionHash, so a surplus just lands in the treasury
    function test_ExcessSponsorValueStaysInTheTreasury() public {
        (Governor governor, ) = _deployVillageGovernance();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = treasury;
        values[0] = 1 ether;
        calldatas[0] = "";
        bytes32 descriptionHash = keccak256("overfunded payout");

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);
        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        address sponsor = makeAddr("sponsor");
        vm.deal(sponsor, 3 ether);
        vm.prank(sponsor);
        governor.execute{value: 3 ether}(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(treasury.balance, 1 ether, "recipient gets exactly the proposed amount");
        assertEq(address(governor).balance, 2 ether, "surplus is absorbed, not refunded");
    }

    function test_GovernorAcceptsPlainTransfersAndCanSpendThem() public {
        (Governor governor, ) = _deployVillageGovernance();

        // a plain send, the way a treasury actually gets funded
        vm.deal(outsider, 5 ether);
        vm.prank(outsider);
        (bool ok, ) = address(governor).call{value: 5 ether}("");
        assertTrue(ok, "governor must accept a plain transfer");
        assertEq(address(governor).balance, 5 ether);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = treasury;
        values[0] = 2 ether;
        calldatas[0] = "";
        bytes32 descriptionHash = keccak256("pay out treasury");

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);
        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(treasury.balance, 2 ether);
        assertEq(address(governor).balance, 3 ether);
    }

    function test_RevertWhen_NonOwnerRegistersGovernance() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        factory.registerGovernance(2, address(governorImpl));
    }

    function test_RevertWhen_RegisteringConstitutionVersionTwice() public {
        vm.expectRevert("version already registered");
        registry.registerConstitution(1, address(councilImpl));
    }

    function test_RevertWhen_NonOwnerRegistersConstitution() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        registry.registerConstitution(2, address(councilImpl));
    }

    function test_AnyoneCanDeployFromARegisteredConstitutionTemplate() public {
        vm.prank(outsider);
        address instance = registry.deployConstitution(1, _councilInitData(5000, 5000));
        assertTrue(Council(instance).isCouncil(alice));
    }

    // ---------------------------------------------------------------
    // gasless (ERC-2771 relayed) propose + vote through the shared forwarder
    // ---------------------------------------------------------------

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract, , ) = forwarder.eip712Domain();
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes(version)),
            chainId,
            verifyingContract
        ));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    // relays `data` to `to` on behalf of `from`, paid for by this test
    // contract (the relayer) instead of `from` -- the gasless part
    function _relay(uint256 fromPk, address from, address to, bytes memory data) internal {
        uint256 nonce = forwarder.nonces(from);
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes32 structHash = keccak256(abi.encode(
            FORWARD_REQUEST_TYPEHASH, from, to, uint256(0), uint256(1_000_000), nonce, deadline, keccak256(data)
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fromPk, _hashTypedData(structHash));

        ERC2771Forwarder.ForwardRequestData memory request = ERC2771Forwarder.ForwardRequestData({
            from: from,
            to: to,
            value: 0,
            gas: 1_000_000,
            deadline: deadline,
            data: data,
            signature: abi.encodePacked(r, s, v)
        });
        forwarder.execute(request);
    }

    function test_GaslessProposeAndVoteResolveToRealSigner() public {
        (Governor governor, ) = _deployVillageGovernance();
        vm.deal(address(governor), 1 ether);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = treasury;
        values[0] = 1 ether;
        calldatas[0] = "";
        bytes32 descriptionHash = keccak256(bytes("gasless treasury transfer"));

        // alice never pays gas or sends the tx herself -- this test contract
        // (standing in for a relayer) submits the signed request instead
        _relay(alicePk, alice, address(governor), abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash)));

        bytes32 actionHash = keccak256(abi.encode(targets, values, calldatas, descriptionHash));
        uint256 proposalId = uint256(keccak256(abi.encode(address(governor), block.chainid, actionHash, uint256(0))));

        Proposal memory p = governor.getProposal(proposalId);
        assertEq(p.proposer, alice, "proposer must resolve to the signer, not the forwarder or relayer");

        _relay(alicePk, alice, address(governor), abi.encodeCall(Governor.vote, (proposalId, true)));
        _relay(bobPk, bob, address(governor), abi.encodeCall(Governor.vote, (proposalId, true)));

        assertTrue(governor.hasVoted(proposalId, alice));
        assertTrue(governor.hasVoted(proposalId, bob));
        p = governor.getProposal(proposalId);
        assertEq(p.forVotes, 2);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);

        assertEq(treasury.balance, 1 ether);
    }

    function test_RevertWhen_RelayedRequestSignedByWrongKey() public {
        (Governor governor, ) = _deployVillageGovernance();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = treasury;
        calldatas[0] = "";
        bytes32 descriptionHash = keccak256(bytes("bad signature"));
        bytes memory data = abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash));

        uint256 nonce = forwarder.nonces(alice);
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes32 structHash = keccak256(abi.encode(
            FORWARD_REQUEST_TYPEHASH, alice, address(governor), uint256(0), uint256(1_000_000), nonce, deadline, keccak256(data)
        ));
        // signed by bob but claims to be from alice
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, _hashTypedData(structHash));

        ERC2771Forwarder.ForwardRequestData memory request = ERC2771Forwarder.ForwardRequestData({
            from: alice,
            to: address(governor),
            value: 0,
            gas: 1_000_000,
            deadline: deadline,
            data: data,
            signature: abi.encodePacked(r, s, v)
        });

        vm.expectRevert();
        forwarder.execute(request);
    }

    function test_DirectCallBypassingForwarderStillUsesRealCaller() public {
        (Governor governor, ) = _deployVillageGovernance();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = treasury;
        calldatas[0] = "";
        bytes32 descriptionHash = keccak256(bytes("direct call"));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);

        assertEq(governor.getProposal(proposalId).proposer, alice);
    }
}
