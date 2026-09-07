// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Governor, DelegateRegistration, FunctionAuthority, VotingParametersRegistration} from "../src/governance/Governer.sol";
import {Owned} from "../src/governance/constitution/owned/owned.sol";
import {MockSafe} from "./mocks/MockSafe.sol";

contract Vault is Ownable {
    constructor(address o) Ownable(o) {}
    function withdrawTo(address payable to, uint256 a) external onlyOwner {
        (bool ok,) = to.call{value: a}(""); require(ok, "fail");
    }
}

// Can a single-owner veto holder approve in ONE call, with no new Governor
// code? The spoke cannot vote as itself -- Owned.canVote(spoke) is false, the
// owner is the holder -- but approveProposal is onlyGovernance, so the spoke
// reaches it by executing a proposal of its own. And because Owned settles on
// propose, that whole thing happens inside the holder's single call.
contract DirectApprovalTest is Test {
    address admin = makeAddr("admin");
    address holder = makeAddr("holder");
    address payable treasury = payable(makeAddr("treasury"));

    Governor hub;
    Governor spoke;
    Vault vault;

    function _owned(address o) internal returns (Owned) {
        return Owned(address(new ERC1967Proxy(
            address(new Owned()), abi.encodeCall(Owned.initialize, (o, 3 days)))));
    }
    function _gov(address c, DelegateRegistration[] memory r) internal returns (Governor) {
        return Governor(payable(address(new ERC1967Proxy(address(new Governor(address(0))),
            abi.encodeCall(Governor.initialize, (c, r, new VotingParametersRegistration[](0)))))));
    }
    function _one(address t, bytes memory d)
        internal pure returns (address[] memory ts, uint256[] memory vs, bytes[] memory cs)
    { ts = new address[](1); vs = new uint256[](1); cs = new bytes[](1); ts[0] = t; cs[0] = d; }

    function setUp() public {
        spoke = _gov(address(_owned(holder)), new DelegateRegistration[](0));
        vault = new Vault(address(this));

        DelegateRegistration[] memory r = new DelegateRegistration[](1);
        r[0] = DelegateRegistration({
            target: address(vault), delegate: address(spoke),
            selector: Vault.withdrawTo.selector, authority: FunctionAuthority.Hard
        });
        hub = _gov(address(_owned(admin)), r);
        vault.transferOwnership(address(hub));
        vm.deal(address(vault), 10 ether);
    }

    function test_TheSpokeCannotVoteAsItself() public {
        assertFalse(Owned(spoke.constitution()).canVote(address(spoke)));
        assertTrue(Owned(spoke.constitution()).canVote(holder));
    }

    // the whole veto, exercised in one call from the holder
    function test_HolderApprovesInASingleCall() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(vault), abi.encodeCall(Vault.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("withdraw"));
        assertFalse(hub.canExecuteNow(id));

        // ONE call: propose settles (proposer == owner) and executes, and the
        // action it executes is approveProposal on the spoke itself
        (address[] memory at, uint256[] memory av, bytes[] memory ac) =
            _one(address(spoke), abi.encodeCall(Governor.approveProposal, (address(hub), id)));
        vm.prank(holder);
        spoke.propose(at, av, ac, keccak256("approve the withdrawal"));

        assertTrue(spoke.hasApproved(address(hub), id));
        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    function test_RevertWhen_AnOutsiderTriesTheSameCall() public {
        (address[] memory at, uint256[] memory av, bytes[] memory ac) =
            _one(address(spoke), abi.encodeCall(Governor.approveProposal, (address(hub), 1)));
        vm.prank(makeAddr("outsider"));
        vm.expectRevert("Proposer not eligible");
        spoke.propose(at, av, ac, keccak256("sneak"));
    }

    // The shortcut skips the mirrored request, so nothing shows the holder the
    // actions. It must at least not let them approve a proposal that does not
    // exist -- ids are precomputable, so pre-approval would be a blank cheque.
    function test_RevertWhen_DirectlyApprovingAnIdThatDoesNotExist() public {
        uint256 imaginary = 999999;

        (address[] memory at, uint256[] memory av, bytes[] memory ac) =
            _one(address(spoke), abi.encodeCall(Governor.approveProposal, (address(hub), imaginary)));
        vm.prank(holder);
        vm.expectRevert("no such hub proposal");
        spoke.propose(at, av, ac, keccak256("blind"));

        assertFalse(spoke.hasApproved(address(hub), imaginary));
    }

    // The shortcut bypasses the mirrored request entirely, leaving it open.
    function test_ShortcutBypassesTheMirroredRequest() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(vault), abi.encodeCall(Vault.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("withdraw"));

        uint256 childId = spoke.approvalProposalId(address(hub), id);
        assertTrue(childId != 0);
        assertFalse(spoke.getProposal(childId).executed);

        // approve the short way, which bypasses that request entirely
        (address[] memory at, uint256[] memory av, bytes[] memory ac) =
            _one(address(spoke), abi.encodeCall(Governor.approveProposal, (address(hub), id)));
        vm.prank(holder);
        spoke.propose(at, av, ac, keccak256("approve"));

        assertTrue(spoke.hasApproved(address(hub), id));

        // the cost of this route: the mirrored request is bypassed, so it sits
        // open and unvoted. Harmless -- hasApproved is the authoritative answer
        // and approveProposal is idempotent -- but it is why batching through
        // the request (see BatchedApprovalTest) is the better route.
        assertFalse(spoke.getProposal(childId).executed, "request left open");
        assertEq(spoke.getProposal(childId).forVotes, 0);

        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    // Approving twice must not rewrite when the veto was granted -- the
    // timestamp is the audit record of the decision.
    function test_ApprovalIsIdempotentAndKeepsItsOriginalTimestamp() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(vault), abi.encodeCall(Vault.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("withdraw"));

        (address[] memory at, uint256[] memory av, bytes[] memory ac) =
            _one(address(spoke), abi.encodeCall(Governor.approveProposal, (address(hub), id)));

        vm.prank(holder);
        spoke.propose(at, av, ac, keccak256("approve once"));
        (bool approvedFirst, uint256 firstTimestamp) = spoke.approvals(address(hub), id);
        assertTrue(approvedFirst);

        vm.warp(block.timestamp + 3 hours);
        vm.prank(holder);
        spoke.propose(at, av, ac, keccak256("approve again"));

        (bool approvedAgain, uint256 secondTimestamp) = spoke.approvals(address(hub), id);
        assertTrue(approvedAgain);
        assertEq(secondTimestamp, firstTimestamp, "the original decision time must stand");
    }

    // the ordinary route runs the request itself, so it closes properly
    function test_OrdinaryRouteRunsTheRequestItself() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(vault), abi.encodeCall(Vault.withdrawTo, (treasury, 1 ether)));
        vm.prank(admin);
        uint256 id = hub.propose(t, v, c, keccak256("withdraw"));

        uint256 childId = spoke.approvalProposalId(address(hub), id);
        vm.prank(holder);
        spoke.vote(childId, true);

        (address[] memory ct, uint256[] memory cv, bytes[] memory cc) =
            _one(address(spoke), abi.encodeWithSelector(spoke.approveProposal.selector, address(hub), id));
        spoke.execute(childId, spoke.getProposal(childId).nounce, ct, cv, cc,
            keccak256(abi.encode("approval", address(hub), id)));

        assertTrue(spoke.hasApproved(address(hub), id));
        assertTrue(spoke.getProposal(childId).executed);

        hub.execute(id, 0, t, v, c, keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }
}

// ===================================================================
// What a veto holder that can batch would actually do
//
// Any external protocol able to bundle calls -- a Safe via MultiSend, a DAO
// whose proposals are already multicalls -- does vote and execute in one
// transaction, needing no contract support whatsoever. Unlike a direct call to
// approveProposal it goes through the mirrored request, so the holder stays
// bound to the actions the hub really proposed, a real ballot is recorded, and
// nothing is left dangling.
// ===================================================================
contract BatchedApprovalTest is Test {
    address admin = makeAddr("admin");
    address payable treasury = payable(makeAddr("treasury"));

    address ownerA;
    uint256 pkA;
    address ownerB;
    uint256 pkB;

    MockSafe safe;
    Governor hub;
    Governor spoke;
    Vault vault;

    uint256 hubId;
    uint256 childId;

    function _owned(address o) internal returns (Owned) {
        return Owned(address(new ERC1967Proxy(
            address(new Owned()), abi.encodeCall(Owned.initialize, (o, 3 days)))));
    }

    function _gov(address c, DelegateRegistration[] memory r) internal returns (Governor) {
        return Governor(payable(address(new ERC1967Proxy(address(new Governor(address(0))),
            abi.encodeCall(Governor.initialize, (c, r, new VotingParametersRegistration[](0)))))));
    }

    function setUp() public {
        (ownerA, pkA) = makeAddrAndKey("ownerA");
        (ownerB, pkB) = makeAddrAndKey("ownerB");

        address[] memory owners = new address[](2);
        owners[0] = ownerA;
        owners[1] = ownerB;
        safe = new MockSafe(owners, 2);

        spoke = _gov(address(_owned(address(safe))), new DelegateRegistration[](0));
        vault = new Vault(address(this));

        DelegateRegistration[] memory r = new DelegateRegistration[](1);
        r[0] = DelegateRegistration({
            target: address(vault), delegate: address(spoke),
            selector: Vault.withdrawTo.selector, authority: FunctionAuthority.Hard
        });
        hub = _gov(address(_owned(admin)), r);
        vault.transferOwnership(address(hub));
        vm.deal(address(vault), 5 ether);

        vm.prank(admin);
        hubId = hub.propose(_t(), _v(), _c(), keccak256("withdraw"));
        childId = spoke.approvalProposalId(address(hub), hubId);
    }

    function _t() internal view returns (address[] memory a) { a = new address[](1); a[0] = address(vault); }
    function _v() internal pure returns (uint256[] memory a) { a = new uint256[](1); }
    function _c() internal view returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = abi.encodeCall(Vault.withdrawTo, (treasury, 1 ether));
    }

    // the spoke's own approval action, which its execute() needs passed back in
    function _approvalArgs() internal view returns (address[] memory t, uint256[] memory v, bytes[] memory c) {
        t = new address[](1);
        v = new uint256[](1);
        c = new bytes[](1);
        t[0] = address(spoke);
        c[0] = abi.encodeWithSelector(spoke.approveProposal.selector, address(hub), hubId);
    }

    function _batch() internal view returns (address[] memory to, uint256[] memory val, bytes[] memory data) {
        (address[] memory at, uint256[] memory av, bytes[] memory ac) = _approvalArgs();
        to = new address[](2);
        val = new uint256[](2);
        data = new bytes[](2);
        to[0] = address(spoke);
        data[0] = abi.encodeCall(Governor.vote, (childId, true));
        to[1] = address(spoke);
        data[1] = abi.encodeCall(
            Governor.execute,
            (childId, spoke.getProposal(childId).nounce, at, av, ac,
             keccak256(abi.encode("approval", address(hub), hubId)))
        );
    }

    // Safe wants signatures ordered by ascending signer address
    function _sign(bytes32 txHash) internal view returns (bytes memory) {
        uint256 first = ownerA < ownerB ? pkA : pkB;
        uint256 second = ownerA < ownerB ? pkB : pkA;
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(first, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(second, txHash);
        return abi.encodePacked(r1, s1, v1, r2, s2, v2);
    }

    function test_OneSafeTransactionVotesAndExecutes() public {
        assertTrue(childId != 0);
        assertFalse(hub.canExecuteNow(hubId));

        (address[] memory to, uint256[] memory val, bytes[] memory data) = _batch();
        bytes32 txHash = safe.getTransactionHash(address(safe), 0, abi.encode(to, val, data), safe.nonce());
        safe.execTransactions(to, val, data, _sign(txHash));

        assertTrue(spoke.hasApproved(address(hub), hubId));
        assertTrue(spoke.getProposal(childId).executed, "nothing left dangling");
        assertEq(spoke.getProposal(childId).forVotes, 1, "a real ballot was cast");

        hub.execute(hubId, 0, _t(), _v(), _c(), keccak256("withdraw"));
        assertEq(treasury.balance, 1 ether);
    }

    // below threshold the batch never runs, so neither half lands
    function test_RevertWhen_TheBatchIsUnderThreshold() public {
        (address[] memory to, uint256[] memory val, bytes[] memory data) = _batch();
        bytes32 txHash = safe.getTransactionHash(address(safe), 0, abi.encode(to, val, data), safe.nonce());
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pkA, txHash);

        vm.expectRevert(bytes("GS020"));
        safe.execTransactions(to, val, data, abi.encodePacked(r1, s1, v1));

        assertFalse(spoke.hasApproved(address(hub), hubId));
        assertEq(spoke.getProposal(childId).forVotes, 0);
    }
}
