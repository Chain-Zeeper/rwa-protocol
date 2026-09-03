// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Governor, DelegateRegistration} from "../src/governance/Governer.sol";
import {Proposal} from "../src/governance/interface/IGoverner.sol";
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
            (address(this), 6667, 6667, members) // ~2-of-3 threshold and quorum
        );
        council = Council(address(new ERC1967Proxy(address(councilImpl), councilInit)));

        // governor behind a proxy, constituted by the council above
        Governor governorImpl = new Governor();
        bytes memory governorInit = abi.encodeCall(
            Governor.initialize,
            (address(council), bytes32(0), new DelegateRegistration[](0))
        );
        governor = Governor(address(new ERC1967Proxy(address(governorImpl), governorInit)));

        // the village pool is owned by the governor: only an executed,
        // passed proposal can touch its admin functions
        pool = new MockVillagePool(address(governor));
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
}
