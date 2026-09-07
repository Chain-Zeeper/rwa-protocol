// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Governor, DelegateRegistration, VotingParametersRegistration} from "../src/governance/Governer.sol";
import {Proposal, VotingParameters} from "../src/governance/interface/IGoverner.sol";
import {RWAHolder} from "../src/governance/constitution/RWAHolder/RWAHolder.sol";

contract MockRWA is ERC20 {
    constructor() ERC20("RWA", "RWA") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract HolderPool is Ownable {
    uint256 public feeBps;
    constructor(address o) Ownable(o) {}
    function setFeeBps(uint256 b) external onlyOwner { feeBps = b; }
}

// Token-weighted governance. This constitution is marked a draft in its own
// header, and these tests hold it to what it currently claims -- including the
// snapshot flaw it documents, so the day RWA.sol moves to ERC20Votes the fix
// shows up as a failing test rather than going unnoticed.
contract RWAHolderTest is Test {
    uint256 constant PERIOD = 3 days;
    uint256 constant THRESHOLD_BPS = 5000;
    uint256 constant QUORUM_BPS = 4000;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address outsider = makeAddr("outsider");

    MockRWA token;
    RWAHolder constitution;
    Governor governor;
    HolderPool pool;

    function setUp() public {
        token = new MockRWA();
        token.mint(alice, 600e18);
        token.mint(bob, 400e18); // 1000e18 total supply

        constitution = RWAHolder(address(new ERC1967Proxy(
            address(new RWAHolder()),
            abi.encodeCall(RWAHolder.initialize, (address(token), THRESHOLD_BPS, QUORUM_BPS, PERIOD))
        )));

        governor = Governor(payable(address(new ERC1967Proxy(
            address(new Governor(address(0))),
            abi.encodeCall(
                Governor.initialize,
                (address(constitution), new DelegateRegistration[](0), new VotingParametersRegistration[](0))
            )
        ))));
        pool = new HolderPool(address(governor));
    }

    function _action() internal view returns (address[] memory t, uint256[] memory v, bytes[] memory c) {
        t = new address[](1); v = new uint256[](1); c = new bytes[](1);
        t[0] = address(pool);
        c[0] = abi.encodeCall(HolderPool.setFeeBps, (250));
    }

    function test_Identity() public {
        assertEq(constitution.name(), "RWAHolder");
        assertEq(constitution.rwaToken(), address(token));
        assertEq(constitution.thresholdBps(), THRESHOLD_BPS);
        assertEq(constitution.quorumBps(), QUORUM_BPS);
    }

    function test_EligibilityFollowsTheTokenBalance() public {
        assertTrue(constitution.canPropose(alice));
        assertTrue(constitution.canVote(bob));
        assertFalse(constitution.canPropose(outsider));
        assertFalse(constitution.canVote(outsider));
    }

    function test_WeightIsTheBalance() public {
        assertEq(constitution.getVotingPower(alice), 600e18);
        assertEq(constitution.getVotes(address(governor), 0, bob), 400e18);
        assertEq(constitution.getVotingPower(outsider), 0);
    }

    function test_ThresholdsScaleWithSupply() public {
        assertEq(constitution.getExecuteThreshold(), 500e18); // 50% of 1000e18
        assertEq(constitution.getQuorum(), 400e18); // 40%

        token.mint(outsider, 1000e18); // supply doubles
        assertEq(constitution.getExecuteThreshold(), 1000e18);
        assertEq(constitution.getQuorum(), 800e18);
    }

    function test_DefaultVotingParameters() public {
        VotingParameters memory p = constitution.getDefaultVotingParameters();
        assertEq(p.quorumBps, QUORUM_BPS);
        assertEq(p.thresholdBps, THRESHOLD_BPS);
        assertEq(p.votingPeriod, PERIOD);
    }

    // token holders need the full window to turn out
    function test_NoEarlyExecutionAndAThirtyDayGrace() public {
        assertFalse(constitution.canExecuteEarly(address(governor), 0));
        assertEq(constitution.executionGrace(), 30 days);
    }

    function test_AMajorityHolderCarriesTheVote() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action();
        vm.prank(alice);
        uint256 id = governor.propose(t, v, c, keccak256("set fee"));

        vm.prank(alice);
        governor.vote(id, true); // 600e18 >= 500e18 threshold, and >= 400e18 quorum

        assertTrue(constitution.hasPassed(address(governor), id));
        vm.warp(block.timestamp + PERIOD + 1);
        governor.execute(id, 0, t, v, c, keccak256("set fee"));
        assertEq(pool.feeBps(), 250);
    }

    function test_RevertWhen_AMinorityHolderActsAlone() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action();
        vm.prank(bob);
        uint256 id = governor.propose(t, v, c, keccak256("set fee"));

        vm.prank(bob);
        governor.vote(id, true); // 400e18 < 500e18 threshold

        assertFalse(constitution.hasPassed(address(governor), id));
        vm.warp(block.timestamp + PERIOD + 1);
        vm.expectRevert("Proposal did not pass");
        governor.execute(id, 0, t, v, c, keccak256("set fee"));
    }

    function test_RevertWhen_ANonHolderVotes() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action();
        vm.prank(alice);
        uint256 id = governor.propose(t, v, c, keccak256("set fee"));

        vm.prank(outsider);
        vm.expectRevert("Cannot vote");
        governor.vote(id, true);
    }

    function test_NothingPassesAgainstAnEmptySupply() public {
        MockRWA empty = new MockRWA();
        RWAHolder c = RWAHolder(address(new ERC1967Proxy(
            address(new RWAHolder()),
            abi.encodeCall(RWAHolder.initialize, (address(empty), THRESHOLD_BPS, QUORUM_BPS, PERIOD))
        )));
        assertFalse(c.hasPassed(address(governor), 0));
    }

    function test_RevertWhen_InitializedWithBpsAbove10000() public {
        RWAHolder impl = new RWAHolder();
        vm.expectRevert("bps must be <= 10000");
        new ERC1967Proxy(address(impl), abi.encodeCall(RWAHolder.initialize, (address(token), 10001, 1, PERIOD)));
    }

    // KNOWN FLAW, asserted so it cannot change silently. getVotes reads the
    // balance at the moment of voting rather than at proposal creation, so one
    // holder can vote, move the tokens, and vote again from a second address --
    // spending the same weight twice. The header calls this out; the fix is
    // RWA.sol on ERC20Votes plus getPastVotes here, and that fix should make
    // this test fail.
    function test_KNOWN_FLAW_BalanceCanBeRecycledToVoteTwice() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _action();
        vm.prank(bob);
        uint256 id = governor.propose(t, v, c, keccak256("set fee"));

        vm.prank(bob);
        governor.vote(id, true); // 400e18
        assertEq(governor.getProposal(id).forVotes, 400e18);

        // same tokens, second address, second ballot
        address bobAlt = makeAddr("bobAlt");
        vm.prank(bob);
        token.transfer(bobAlt, 400e18);
        vm.prank(bobAlt);
        governor.vote(id, true);

        assertEq(governor.getProposal(id).forVotes, 800e18, "the same 400e18 counted twice");
        assertTrue(constitution.hasPassed(address(governor), id), "a minority holder passed it alone");
    }
}
