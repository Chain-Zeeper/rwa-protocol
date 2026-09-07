// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

import {Governor, DelegateRegistration, VotingParametersRegistration} from "../src/governance/Governer.sol";
import {Proposal} from "../src/governance/interface/IGoverner.sol";
import {Council} from "../src/governance/VotingStrategies/council/council.sol";
import {GovernerFactory} from "../src/governance/GovernerFactory.sol";
import {ConstitutionRegistry} from "../src/governance/VotingStrategies/ConstitutionRegistry.sol";

// Meta-transaction (ERC-2771) behaviour of a factory-deployed Governor: who
// the governor believes the caller is, and what a forwarder can and cannot do.
contract ForwarderTest is Test {
    bytes32 constant FORWARD_REQUEST_TYPEHASH =
        keccak256("ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)");

    uint256 constant VOTING_PERIOD = 3 days;

    ConstitutionRegistry registry;
    GovernerFactory factory;
    ERC2771Forwarder forwarder;
    Governor governor;
    Council council;

    address alice;
    uint256 alicePk;
    address bob;
    uint256 bobPk;
    address outsider;
    uint256 outsiderPk;
    address carol = makeAddr("carol");
    address relayer = makeAddr("relayer");
    address treasury = makeAddr("treasury");

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        (outsider, outsiderPk) = makeAddrAndKey("outsider");

        registry = new ConstitutionRegistry(address(this));
        registry.registerConstitution(1, address(new Council()));

        forwarder = new ERC2771Forwarder("RWAGovForwarder");

        factory = new GovernerFactory(address(this), address(registry));
        factory.registerGovernance(1, address(new Governor(address(forwarder))));

        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;

        (address g, address c) = factory.deployGovernance(
            1,
            1,
            abi.encodeCall(Council.initialize, (address(this), 5000, 5000, VOTING_PERIOD, members)),
            new DelegateRegistration[](0),
            new VotingParametersRegistration[](0)
        );
        governor = Governor(payable(g));
        council = Council(c);
    }

    // ---------------------------------------------------------------
    // signing helpers
    // ---------------------------------------------------------------

    function _domainSeparator(ERC2771Forwarder f) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract, , ) = f.eip712Domain();
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes(version)),
            chainId,
            verifyingContract
        ));
    }

    function _buildRequest(
        ERC2771Forwarder f,
        uint256 signerPk,
        address from,
        address to,
        bytes memory data,
        uint48 deadline
    ) internal view returns (ERC2771Forwarder.ForwardRequestData memory) {
        bytes32 structHash = keccak256(abi.encode(
            FORWARD_REQUEST_TYPEHASH, from, to, uint256(0), uint256(1_000_000), f.nonces(from), deadline, keccak256(data)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(f), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        return ERC2771Forwarder.ForwardRequestData({
            from: from,
            to: to,
            value: 0,
            gas: 1_000_000,
            deadline: deadline,
            data: data,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function _request(uint256 signerPk, address from, bytes memory data)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory)
    {
        return _buildRequest(forwarder, signerPk, from, address(governor), data, uint48(block.timestamp + 1 days));
    }

    function _proposalActions()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = treasury;
        values[0] = 1 ether;
        calldatas[0] = "";
        descriptionHash = keccak256(bytes("relayed treasury transfer"));
    }

    function _proposalId(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash,
        uint256 nounce
    ) internal view returns (uint256) {
        bytes32 actionHash = keccak256(abi.encode(targets, values, calldatas, descriptionHash));
        return uint256(keccak256(abi.encode(address(governor), block.chainid, actionHash, nounce)));
    }

    // ---------------------------------------------------------------
    // wiring
    // ---------------------------------------------------------------

    function test_CloneInheritsTrustedForwarderFromImplementation() public view {
        assertEq(governor.trustedForwarder(), address(forwarder));
        assertTrue(governor.isTrustedForwarder(address(forwarder)));
        assertFalse(governor.isTrustedForwarder(relayer));
        assertFalse(governor.isTrustedForwarder(address(0)));
    }

    function test_EveryCloneOfAnImplementationSharesTheForwarder() public {
        (address second, ) = factory.deployGovernance(
            1,
            1,
            abi.encodeCall(Council.initialize, (address(this), 5000, 5000, VOTING_PERIOD, new address[](0))),
            new DelegateRegistration[](0),
            new VotingParametersRegistration[](0)
        );
        assertEq(Governor(payable(second)).trustedForwarder(), address(forwarder));
    }

    // ---------------------------------------------------------------
    // relayed calls resolve to the signer
    // ---------------------------------------------------------------

    function test_RelayedProposeIsAttributedToSignerNotRelayer() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();
        bytes memory data = abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash));

        vm.prank(relayer); // a random EOA pays the gas
        forwarder.execute(_request(alicePk, alice, data));

        uint256 proposalId = _proposalId(targets, values, calldatas, descriptionHash, 0);
        Proposal memory p = governor.getProposal(proposalId);
        assertEq(p.proposer, alice);
        assertTrue(p.proposer != relayer);
        assertTrue(p.proposer != address(forwarder));
    }

    function test_RelayedVoteIsCreditedToSigner() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);

        vm.prank(relayer);
        forwarder.execute(_request(alicePk, alice, abi.encodeCall(Governor.vote, (proposalId, true))));

        assertTrue(governor.hasVoted(proposalId, alice));
        assertFalse(governor.hasVoted(proposalId, relayer));
        assertEq(governor.getProposal(proposalId).forVotes, 1);
    }

    function test_MixedRelayedAndDirectVotesTallyTogether() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();
        vm.deal(address(governor), 1 ether);

        vm.prank(relayer);
        forwarder.execute(_request(alicePk, alice, abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash))));

        uint256 proposalId = _proposalId(targets, values, calldatas, descriptionHash, 0);

        // alice votes gaslessly, bob pays his own gas
        vm.prank(relayer);
        forwarder.execute(_request(alicePk, alice, abi.encodeCall(Governor.vote, (proposalId, true))));
        vm.prank(bob);
        governor.vote(proposalId, true);

        assertEq(governor.getProposal(proposalId).forVotes, 2);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
        assertEq(treasury.balance, 1 ether);
    }

    // ---------------------------------------------------------------
    // the forwarder grants no privileges of its own
    // ---------------------------------------------------------------

    function test_RevertWhen_RelayingForANonMember() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();
        bytes memory data = abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash));

        // outsider signs for themselves: relaying does not launder eligibility
        ERC2771Forwarder.ForwardRequestData memory request = _request(outsiderPk, outsider, data);

        vm.prank(relayer);
        vm.expectRevert();
        forwarder.execute(request);
    }

    function test_RevertWhen_RelayedVoterVotesTwice() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);
        bytes memory voteData = abi.encodeCall(Governor.vote, (proposalId, true));

        vm.prank(relayer);
        forwarder.execute(_request(alicePk, alice, voteData));

        // fresh nonce, same voter -> the governor's own double-vote guard trips
        ERC2771Forwarder.ForwardRequestData memory secondVote = _request(alicePk, alice, voteData);

        vm.prank(relayer);
        vm.expectRevert();
        forwarder.execute(secondVote);
    }

    function test_RevertWhen_RelayerForgesAnotherMembersVote() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);

        // outsider signs but claims the request comes from bob
        ERC2771Forwarder.ForwardRequestData memory forged =
            _buildRequest(forwarder, outsiderPk, bob, address(governor), abi.encodeCall(Governor.vote, (proposalId, true)), uint48(block.timestamp + 1 days));

        vm.prank(relayer);
        vm.expectRevert();
        forwarder.execute(forged);

        assertFalse(governor.hasVoted(proposalId, bob));
    }

    // an untrusted forwarder cannot append a spoofed sender, because the
    // governor only strips the suffix for the one forwarder it trusts
    function test_RevertWhen_AnUntrustedForwarderRelays() public {
        ERC2771Forwarder rogue = new ERC2771Forwarder("RogueForwarder");
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();

        ERC2771Forwarder.ForwardRequestData memory request = _buildRequest(
            rogue,
            alicePk,
            alice,
            address(governor),
            abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash)),
            uint48(block.timestamp + 1 days)
        );

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ERC2771Forwarder.ERC2771UntrustfulTarget.selector, address(governor), address(rogue))
        );
        rogue.execute(request);
    }

    function test_GovernorWithoutForwarderRejectsAllRelayedCalls() public {
        factory.registerGovernance(2, address(new Governor(address(0))));
        (address g, ) = factory.deployGovernance(
            2,
            1,
            abi.encodeCall(Council.initialize, (address(this), 5000, 5000, VOTING_PERIOD, new address[](0))),
            new DelegateRegistration[](0),
            new VotingParametersRegistration[](0)
        );

        assertEq(Governor(payable(g)).trustedForwarder(), address(0));

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();
        ERC2771Forwarder.ForwardRequestData memory request = _buildRequest(
            forwarder,
            alicePk,
            alice,
            g,
            abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash)),
            uint48(block.timestamp + 1 days)
        );

        vm.expectRevert(abi.encodeWithSelector(ERC2771Forwarder.ERC2771UntrustfulTarget.selector, g, address(forwarder)));
        forwarder.execute(request);
    }

    // ---------------------------------------------------------------
    // direct calls to a forwarder-enabled governor
    // ---------------------------------------------------------------

    // The suffix only means something when the caller IS the trusted
    // forwarder. Anyone else appending 20 bytes is just sending junk calldata,
    // and must still be judged as themselves.
    function test_DirectCallCannotSpoofSenderByAppendingAnAddress() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);

        // outsider forges the ERC-2771 calldata layout by hand, claiming alice
        bytes memory spoofed = abi.encodePacked(abi.encodeCall(Governor.vote, (proposalId, true)), alice);

        vm.prank(outsider);
        (bool ok, bytes memory ret) = address(governor).call(spoofed);

        assertFalse(ok, "spoofed direct call must not succeed");
        assertEq(ret, abi.encodeWithSignature("Error(string)", "Cannot vote"), "judged as outsider, not alice");
        assertFalse(governor.hasVoted(proposalId, alice), "alice must not be recorded as having voted");
        assertEq(governor.getProposal(proposalId).forVotes, 0);
    }

    // the same forged suffix from a legitimate member: the vote lands as the
    // caller's, and the appended address is simply ignored
    function test_DirectCallWithSuffixIsCreditedToTheActualCaller() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);

        bytes memory suffixed = abi.encodePacked(abi.encodeCall(Governor.vote, (proposalId, true)), carol);

        vm.prank(bob);
        (bool ok, ) = address(governor).call(suffixed);

        assertTrue(ok);
        assertTrue(governor.hasVoted(proposalId, bob), "vote belongs to the caller");
        assertFalse(governor.hasVoted(proposalId, carol), "appended address must be ignored");
        assertEq(governor.getProposal(proposalId).forVotes, 1);
    }

    function test_DirectProposeAndVoteWorkAlongsideAConfiguredForwarder() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();
        vm.deal(address(governor), 1 ether);

        // nothing relayed at all -- every call is a plain EOA transaction
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, descriptionHash);
        assertEq(governor.getProposal(proposalId).proposer, alice);

        vm.prank(alice);
        governor.vote(proposalId, true);
        vm.prank(bob);
        governor.vote(proposalId, true);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.execute(proposalId, 0, targets, values, calldatas, descriptionHash);
        assertEq(treasury.balance, 1 ether);
    }

    // ---------------------------------------------------------------
    // request lifecycle: nonces and deadlines
    // ---------------------------------------------------------------

    function test_RevertWhen_ReplayingAnAlreadyExecutedRequest() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();
        ERC2771Forwarder.ForwardRequestData memory request =
            _request(alicePk, alice, abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash)));

        vm.prank(relayer);
        forwarder.execute(request);
        assertEq(forwarder.nonces(alice), 1);

        // same signed payload, nonce already burned
        vm.prank(relayer);
        vm.expectRevert();
        forwarder.execute(request);
    }

    function test_RevertWhen_RequestDeadlineHasPassed() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();
        uint48 deadline = uint48(block.timestamp + 1 hours);
        ERC2771Forwarder.ForwardRequestData memory request = _buildRequest(
            forwarder,
            alicePk,
            alice,
            address(governor),
            abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash)),
            deadline
        );

        vm.warp(block.timestamp + 2 hours);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ERC2771Forwarder.ERC2771ForwarderExpiredRequest.selector, deadline));
        forwarder.execute(request);
    }

    function test_VerifyReflectsRequestValidity() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) =
            _proposalActions();
        ERC2771Forwarder.ForwardRequestData memory request =
            _request(alicePk, alice, abi.encodeCall(Governor.propose, (targets, values, calldatas, descriptionHash)));

        assertTrue(forwarder.verify(request));

        vm.prank(relayer);
        forwarder.execute(request);

        assertFalse(forwarder.verify(request), "nonce consumed, request no longer valid");
    }

    // ---------------------------------------------------------------
    // self-governance is unaffected by the forwarder
    // ---------------------------------------------------------------

    // onlyGovernance checks raw msg.sender, so a relayed call can never
    // satisfy it -- these stay reachable only through an executed proposal
    function test_RevertWhen_RelayingAnOnlyGovernanceCall() public {
        bytes memory data = abi.encodeCall(Governor.setVotingParameters, (treasury, bytes4(0x12345678), 1, 1, 1 days));
        ERC2771Forwarder.ForwardRequestData memory request = _request(alicePk, alice, data);

        vm.prank(relayer);
        vm.expectRevert();
        forwarder.execute(request);

        (uint16 quorumBps, , ) = governor.votingParameters(treasury, bytes4(0x12345678));
        assertEq(quorumBps, 0);
    }
}
