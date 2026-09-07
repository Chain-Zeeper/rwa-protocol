// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Governor, DelegateRegistration, FunctionAuthority, VotingParametersRegistration} from "../src/governance/Governer.sol";
import {IGoverner, Proposal, VotingParameters} from "../src/governance/interface/IGoverner.sol";
import {Owned} from "../src/governance/constitution/owned/owned.sol";
import {Council} from "../src/governance/constitution/council/council.sol";
import {RWAHolder} from "../src/governance/constitution/RWAHolder/RWAHolder.sol";

contract Pool is Ownable {
    uint256 public feeBps;
    constructor(address o) Ownable(o) {}
    function setFeeBps(uint256 b) external onlyOwner { feeBps = b; }
}

// A delegate is arbitrary code the hub calls in the middle of building a
// proposal. This one just looks at the hub's counter at that moment, which is
// exactly what a re-entrant attacker would be racing.
contract ObservingDelegate is IGoverner {
    uint256 public observedNounce;
    bool public wasCalled;

    function proposeApproval(address hub, uint256, address[] calldata, uint256[] calldata, bytes[] calldata, bytes32)
        external
        returns (uint256)
    {
        observedNounce = Governor(payable(hub)).nounce();
        wasCalled = true;
        return 1;
    }

    function hasApproved(address, uint256) external pure returns (bool) { return true; }

    function propose(address[] calldata, uint256[] calldata, bytes[] calldata, bytes32)
        external pure returns (uint256) { revert("no"); }

    function getProposal(uint256) external view returns (Proposal memory p) {
        p.voteStart = block.timestamp;
        p.voteEnd = block.timestamp + 1 days;
    }
}

// A delegate that tries to re-enter the hub while the hub is mid-proposal.
// It catches the failure rather than propagating it, so the test can assert
// what the guard did instead of just seeing the outer call die.
contract ReentrantDelegate is IGoverner {
    bytes public reentryRevertData;
    bool public reentryAttempted;

    function proposeApproval(
        address hub,
        uint256 hubProposalId,
        address[] calldata t,
        uint256[] calldata v,
        bytes[] calldata c,
        bytes32 d
    ) external returns (uint256) {
        reentryAttempted = true;
        try Governor(payable(hub)).proposeApproval(hub, hubProposalId, t, v, c, d) returns (uint256) {
            reentryRevertData = "";
        } catch (bytes memory reason) {
            reentryRevertData = reason;
        }
        return 1;
    }

    function hasApproved(address, uint256) external pure returns (bool) { return true; }

    function propose(address[] calldata, uint256[] calldata, bytes[] calldata, bytes32)
        external pure returns (uint256) { revert("no"); }

    function getProposal(uint256) external view returns (Proposal memory p) {
        p.voteStart = block.timestamp;
        p.voteEnd = block.timestamp + 1 days;
    }
}

contract GovernorHardeningTest is Test {
    uint256 constant PERIOD = 3 days;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    function _owned(address o, uint256 period) internal returns (Owned) {
        return Owned(address(new ERC1967Proxy(
            address(new Owned()), abi.encodeCall(Owned.initialize, (o, period)))));
    }

    function _gov(address c, DelegateRegistration[] memory r) internal returns (Governor) {
        return Governor(payable(address(new ERC1967Proxy(address(new Governor(address(0))),
            abi.encodeCall(Governor.initialize, (c, r, new VotingParametersRegistration[](0)))))));
    }

    // ---------------------------------------------------------------
    // the nounce must be consumed before any delegate is called
    // ---------------------------------------------------------------

    // Otherwise a re-entrant delegate could mint a proposal under the same
    // nounce, producing the same id and overwriting the record being built.
    function test_NounceIsConsumedBeforeDelegatesAreCalled() public {
        ObservingDelegate spy = new ObservingDelegate();
        Pool pool = new Pool(address(this));

        DelegateRegistration[] memory r = new DelegateRegistration[](1);
        r[0] = DelegateRegistration({
            target: address(pool), delegate: address(spy),
            selector: Pool.setFeeBps.selector, authority: FunctionAuthority.Hard
        });
        Governor g = _gov(address(_owned(admin, PERIOD)), r);
        pool.transferOwnership(address(g));

        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(pool);
        c[0] = abi.encodeCall(Pool.setFeeBps, (100));

        assertEq(g.nounce(), 0);
        vm.prank(admin);
        uint256 id = g.propose(t, v, c, keccak256("set fee"));

        assertTrue(spy.wasCalled());
        assertEq(g.getProposal(id).nounce, 0, "this proposal owns nounce 0");
        assertEq(spy.observedNounce(), 1, "the counter had already moved on when the delegate ran");
        assertEq(g.nounce(), 1, "and it was not double-incremented afterwards");
    }

    // ---------------------------------------------------------------
    // a governor with no constitution is unrecoverable, so refuse it
    // ---------------------------------------------------------------

    function test_RevertWhen_InitializedWithoutAConstitution() public {
        Governor impl = new Governor(address(0));
        vm.expectRevert("cannot set to zero address");
        new ERC1967Proxy(address(impl), abi.encodeCall(
            Governor.initialize,
            (address(0), new DelegateRegistration[](0), new VotingParametersRegistration[](0))
        ));
    }

    // ---------------------------------------------------------------
    // an out-of-range bps would strand a selector permanently
    // ---------------------------------------------------------------

    function test_RevertWhen_VotingParametersExceedTenThousandBps() public {
        Pool pool = new Pool(address(this));
        Governor g = _gov(address(_owned(admin, PERIOD)), new DelegateRegistration[](0));
        pool.transferOwnership(address(g));

        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(g);
        c[0] = abi.encodeCall(
            Governor.setVotingParameters, (address(pool), Pool.setFeeBps.selector, 10001, 5000, PERIOD)
        );

        vm.prank(admin);
        vm.expectRevert("bps must be <= 10000");
        g.propose(t, v, c, keccak256("bad quorum"));

        c[0] = abi.encodeCall(
            Governor.setVotingParameters, (address(pool), Pool.setFeeBps.selector, 5000, 10001, PERIOD)
        );
        vm.prank(admin);
        vm.expectRevert("bps must be <= 10000");
        g.propose(t, v, c, keccak256("bad threshold"));
    }

    function test_VotingParametersAtExactlyTenThousandAreFine() public {
        Pool pool = new Pool(address(this));
        Governor g = _gov(address(_owned(admin, PERIOD)), new DelegateRegistration[](0));
        pool.transferOwnership(address(g));

        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(g);
        c[0] = abi.encodeCall(
            Governor.setVotingParameters, (address(pool), Pool.setFeeBps.selector, 10000, 10000, PERIOD)
        );
        vm.prank(admin);
        g.propose(t, v, c, keccak256("unanimity"));

        (uint16 q, uint16 th,) = g.votingParameters(address(pool), Pool.setFeeBps.selector);
        assertEq(q, 10000);
        assertEq(th, 10000);
    }

    // ---------------------------------------------------------------
    // every constitution must refuse a zero voting period
    // ---------------------------------------------------------------

    function test_RevertWhen_AnyConstitutionGetsAZeroVotingPeriod() public {
        // implementations hoisted: vm.expectRevert binds to the next call, and
        // `new Impl()` inside the argument list would consume it
        address ownedImpl = address(new Owned());
        address councilImpl = address(new Council());
        address rwaImpl = address(new RWAHolder());

        address[] memory members = new address[](1);
        members[0] = alice;
        vm.expectRevert("zero voting period");
        new ERC1967Proxy(ownedImpl, abi.encodeCall(Owned.initialize, (admin, 0)));

        vm.expectRevert("zero voting period");
        new ERC1967Proxy(councilImpl, abi.encodeCall(Council.initialize, (address(this), 5000, 5000, 0, members)));

        vm.expectRevert("zero voting period");
        new ERC1967Proxy(rwaImpl, abi.encodeCall(RWAHolder.initialize, (makeAddr("token"), 5000, 5000, 0)));
    }

    // ---------------------------------------------------------------
    // and the guard itself
    // ---------------------------------------------------------------

    function test_ADelegateCannotReEnterTheHubMidProposal() public {
        ReentrantDelegate attacker = new ReentrantDelegate();
        Pool pool = new Pool(address(this));

        DelegateRegistration[] memory r = new DelegateRegistration[](1);
        r[0] = DelegateRegistration({
            target: address(pool), delegate: address(attacker),
            selector: Pool.setFeeBps.selector, authority: FunctionAuthority.Hard
        });
        Governor g = _gov(address(_owned(admin, PERIOD)), r);
        pool.transferOwnership(address(g));

        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(pool);
        c[0] = abi.encodeCall(Pool.setFeeBps, (100));

        vm.prank(admin);
        g.propose(t, v, c, keccak256("set fee"));

        assertTrue(attacker.reentryAttempted(), "the attacker got its callback");
        assertEq(
            attacker.reentryRevertData(),
            abi.encodeWithSignature("ReentrancyGuardReentrantCall()"),
            "re-entry must be refused by the guard"
        );
    }

    // ---------------------------------------------------------------
    // the governor's own selectors, seeded at deploy
    // ---------------------------------------------------------------

    // changeConstitutionalStrategy is the most powerful action in the system --
    // whoever installs a constitution decides who governs. Gating it only by a
    // later proposal leaves a window where a fresh owner can swap it freely, so
    // the veto has to be seedable at deployment.
    function test_TheConstitutionSwapCanBeVetoedFromBlockOne() public {
        address vetoHolder = makeAddr("vetoHolder");
        Governor spoke = _gov(address(_owned(vetoHolder, PERIOD)), new DelegateRegistration[](0));

        // a governor's address is deterministic, so it can be wired to gate its
        // own selectors in the very transaction that creates it
        address constitutionAddr = address(_owned(admin, PERIOD));
        Governor impl = new Governor(address(0));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        DelegateRegistration[] memory r = new DelegateRegistration[](1);
        r[0] = DelegateRegistration({
            target: predicted,
            delegate: address(spoke),
            selector: Governor.changeConstitutionalStrategy.selector,
            authority: FunctionAuthority.Hard
        });
        Governor g = Governor(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(
            Governor.initialize, (constitutionAddr, r, new VotingParametersRegistration[](0))
        )))));
        assertEq(address(g), predicted, "prediction held");

        // the owner tries to swap the constitution out from under everyone
        Owned successor = _owned(admin, PERIOD);
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(g);
        c[0] = abi.encodeCall(Governor.changeConstitutionalStrategy, (address(successor)));

        vm.prank(admin);
        uint256 id = g.propose(t, v, c, keccak256("swap the constitution"));

        assertEq(g.delegates(id, 0), address(spoke), "the veto was consulted");
        assertFalse(g.canExecuteNow(id));
        vm.expectRevert("delegate approval missing");
        g.execute(id, 0, t, v, c, keccak256("swap the constitution"));

        // and it only goes through once the veto holder agrees
        uint256 childId = spoke.approvalProposalId(address(g), id);
        vm.prank(vetoHolder);
        spoke.vote(childId, true);
        address[] memory at = new address[](1);
        uint256[] memory av = new uint256[](1);
        bytes[] memory ac = new bytes[](1);
        at[0] = address(spoke);
        ac[0] = abi.encodeWithSelector(spoke.approveProposal.selector, address(g), id);
        spoke.execute(childId, spoke.getProposal(childId).nounce, at, av, ac,
            keccak256(abi.encode("approval", address(g), id)));

        g.execute(id, 0, t, v, c, keccak256("swap the constitution"));
        assertEq(g.constitution(), address(successor));
    }

    // voting parameters on the governor's own selectors are seedable too
    function test_TheGovernorsOwnSelectorsCanCarrySeededVotingParameters() public {
        address constitutionAddr = address(_owned(admin, PERIOD));
        Governor impl = new Governor(address(0));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        VotingParametersRegistration[] memory vp = new VotingParametersRegistration[](1);
        vp[0] = VotingParametersRegistration({
            target: predicted,
            selector: Governor.rescue.selector,
            params: VotingParameters({quorumBps: 9000, thresholdBps: 9000, votingPeriod: 14 days})
        });

        Governor g = Governor(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(
            Governor.initialize, (constitutionAddr, new DelegateRegistration[](0), vp)
        )))));
        assertEq(address(g), predicted, "prediction held");

        (uint16 q, uint16 th, uint256 period) = g.votingParameters(address(g), Governor.rescue.selector);
        assertEq(q, 9000);
        assertEq(th, 9000);
        assertEq(period, 14 days);
    }

    // seeding still cannot write what setDelegateGovernance refuses
    function test_RevertWhen_SeedingASentinelOnAWildcardSlot() public {
        address constitutionAddr = address(_owned(admin, PERIOD));
        Governor impl = new Governor(address(0));

        DelegateRegistration[] memory r = new DelegateRegistration[](1);
        r[0] = DelegateRegistration({
            target: makeAddr("pool"),
            delegate: vm.computeCreateAddress(address(this), vm.getNonce(address(this))),
            selector: 0xffffffff,
            authority: FunctionAuthority.Hard
        });
        vm.expectRevert("cannot exempt the wildcard itself");
        new ERC1967Proxy(address(impl), abi.encodeCall(
            Governor.initialize, (constitutionAddr, r, new VotingParametersRegistration[](0))
        ));
    }

    function test_RevertWhen_SeedingOutOfRangeVotingParameters() public {
        VotingParametersRegistration[] memory vp = new VotingParametersRegistration[](1);
        vp[0] = VotingParametersRegistration({
            target: makeAddr("pool"),
            selector: bytes4(0x12345678),
            params: VotingParameters({quorumBps: 10001, thresholdBps: 5000, votingPeriod: PERIOD})
        });
        Governor impl = new Governor(address(0));
        address constitutionAddr = address(_owned(admin, PERIOD));
        vm.expectRevert("bps must be <= 10000");
        new ERC1967Proxy(address(impl), abi.encodeCall(
            Governor.initialize, (constitutionAddr, new DelegateRegistration[](0), vp)
        ));
    }
}
