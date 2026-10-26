// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Governor, DelegateRegistration, VotingParametersRegistration} from "../src/governance/Governer.sol";
import {Council} from "../src/governance/constitution/council/council.sol";
import {RWAHolder} from "../src/governance/constitution/RWAHolder/RWAHolder.sol";

contract VoteToken is ERC20 {
    constructor() ERC20("Vote", "V") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract Noop {
    function ping() external {}
}

// Fuzzes the pass/fail decision end to end (propose -> vote -> hasPassed)
// against the rule each constitution states, in plain integer arithmetic:
//   Council:   for * 10000 >= thresholdBps * members   (ceiling-rounded bps)
//              (for + against) * 10000 >= quorumBps * members
//   RWAHolder: for >= floor(thresholdBps * supply / 10000)
//              for + against >= floor(quorumBps * supply / 10000)
contract VotingMathTest is Test {
    uint256 constant PERIOD = 3 days;
    Noop target = new Noop();

    function _governor(address constitution) internal returns (Governor) {
        return Governor(payable(address(new ERC1967Proxy(
            address(new Governor(address(0))),
            abi.encodeCall(
                Governor.initialize, (constitution, new DelegateRegistration[](0), new VotingParametersRegistration[](0))
            )
        ))));
    }

    function _propose(Governor g, address proposer) internal returns (uint256) {
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(target);
        c[0] = abi.encodeCall(Noop.ping, ());
        vm.prank(proposer);
        return g.propose(t, v, c, keccak256("fuzz"));
    }

    function testFuzz_CouncilPassesExactlyAtTheBpsLine(
        uint8 members,
        uint8 forVotes,
        uint8 againstVotes,
        uint16 thresholdBps,
        uint16 quorumBps
    ) public {
        uint256 n = bound(members, 1, 25);
        uint256 yes = bound(forVotes, 0, n);
        uint256 no = bound(againstVotes, 0, n - yes);
        thresholdBps = uint16(bound(thresholdBps, 0, 10_000));
        quorumBps = uint16(bound(quorumBps, 0, 10_000));

        address[] memory m = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            m[i] = vm.addr(i + 1);
        }
        Council council = Council(address(new ERC1967Proxy(
            address(new Council()),
            abi.encodeCall(Council.initialize, (address(this), quorumBps, thresholdBps, PERIOD, m))
        )));
        Governor g = _governor(address(council));

        vm.warp(block.timestamp + 1); // membership checkpoint strictly in the past
        uint256 id = _propose(g, m[0]);
        for (uint256 i = 0; i < yes + no; i++) {
            vm.prank(m[i]);
            g.vote(id, i < yes);
        }
        vm.warp(block.timestamp + PERIOD + 1);

        bool expected =
            yes * 10_000 >= uint256(thresholdBps) * n && (yes + no) * 10_000 >= uint256(quorumBps) * n;
        assertEq(council.hasPassed(address(g), id), expected);
    }

    function testFuzz_RWAHolderPassesExactlyAtTheBpsLine(
        uint96 forBalance,
        uint96 againstBalance,
        uint96 abstainBalance,
        uint16 thresholdBps,
        uint16 quorumBps
    ) public {
        thresholdBps = uint16(bound(thresholdBps, 0, 10_000));
        quorumBps = uint16(bound(quorumBps, 0, 10_000));
        address yes = makeAddr("yes");
        address no = makeAddr("no");
        address abstain = makeAddr("abstain");

        VoteToken token = new VoteToken();
        token.mint(yes, forBalance);
        token.mint(no, againstBalance);
        token.mint(abstain, abstainBalance);
        uint256 supply = token.totalSupply();
        vm.assume(supply > 0);

        RWAHolder holder = RWAHolder(address(new ERC1967Proxy(
            address(new RWAHolder()),
            abi.encodeCall(RWAHolder.initialize, (address(token), quorumBps, thresholdBps, PERIOD))
        )));
        Governor g = _governor(address(holder));

        // whoever holds tokens can propose; pick one that does
        address proposer = forBalance > 0 ? yes : againstBalance > 0 ? no : abstain;
        uint256 id = _propose(g, proposer);
        if (forBalance > 0) {
            vm.prank(yes);
            g.vote(id, true);
        }
        if (againstBalance > 0) {
            vm.prank(no);
            g.vote(id, false);
        }
        vm.warp(block.timestamp + PERIOD + 1);

        uint256 total = uint256(forBalance) + againstBalance;
        bool expected = forBalance >= uint256(thresholdBps) * supply / 10_000
            && total >= uint256(quorumBps) * supply / 10_000;
        assertEq(holder.hasPassed(address(g), id), expected);
    }

    // One address, one vote: however a voter retries, their weight counts once.
    function testFuzz_CouncilMemberCannotVoteTwice(bool first, bool second) public {
        address[] memory m = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            m[i] = vm.addr(i + 1);
        }
        Council council = Council(address(new ERC1967Proxy(
            address(new Council()), abi.encodeCall(Council.initialize, (address(this), 5000, 5000, PERIOD, m))
        )));
        Governor g = _governor(address(council));
        vm.warp(block.timestamp + 1);
        uint256 id = _propose(g, m[0]);

        vm.prank(m[0]);
        g.vote(id, first);
        vm.prank(m[0]);
        vm.expectRevert("Already voted");
        g.vote(id, second);

        assertEq(g.getProposal(id).forVotes + g.getProposal(id).againstVotes, 1);
    }
}
