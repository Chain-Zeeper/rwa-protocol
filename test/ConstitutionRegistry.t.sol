// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ConstitutionRegistry} from "../src/governance/VotingStrategies/ConstitutionRegistry.sol";
import {IConstitutionRegistry} from "../src/governance/VotingStrategies/interface/IConstitutionRegistry.sol";
import {Council} from "../src/governance/VotingStrategies/council/council.sol";
import {RWAHolder} from "../src/governance/VotingStrategies/council/RWAHolder.sol";
import {VotingParameters} from "../src/governance/interface/IGoverner.sol";

// Plain mintable ERC20 stand-in for RWA.sol, which can't be minted without a
// ComplianceHub wired up
contract MockRWAToken is ERC20 {
    constructor() ERC20("Mock RWA", "mRWA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ConstitutionRegistryTest is Test {
    uint256 constant VOTING_PERIOD = 3 days;
    uint256 constant COUNCIL_VERSION = 1;
    uint256 constant RWA_HOLDER_VERSION = 2;

    ConstitutionRegistry registry;
    Council councilImpl;
    RWAHolder rwaHolderImpl;
    MockRWAToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address outsider = makeAddr("outsider");

    function setUp() public {
        registry = new ConstitutionRegistry(address(this));

        councilImpl = new Council();
        rwaHolderImpl = new RWAHolder();
        token = new MockRWAToken();

        registry.registerConstitution(COUNCIL_VERSION, address(councilImpl));
        registry.registerConstitution(RWA_HOLDER_VERSION, address(rwaHolderImpl));
    }

    function _councilInit(address owner) internal view returns (bytes memory) {
        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
        return abi.encodeCall(Council.initialize, (owner, 5000, 5000, VOTING_PERIOD, members));
    }

    // ---------------------------------------------------------------
    // registration
    // ---------------------------------------------------------------

    function test_RegisterStoresImplPerVersion() public view {
        assertEq(registry.constitutionImpl(COUNCIL_VERSION), address(councilImpl));
        assertEq(registry.constitutionImpl(RWA_HOLDER_VERSION), address(rwaHolderImpl));
        assertEq(registry.constitutionImpl(999), address(0));
    }

    function test_RevertWhen_RegisteringZeroImpl() public {
        vm.expectRevert("zero impl");
        registry.registerConstitution(3, address(0));
    }

    function test_RegisterEmitsEvent() public {
        Council freshImpl = new Council();
        vm.expectEmit(false, false, false, true, address(registry));
        emit IConstitutionRegistry.ConstitutionRegistered(3, address(freshImpl));
        registry.registerConstitution(3, address(freshImpl));
    }

    function test_RegisteredVersionsAreImmutableOnceSet() public {
        Council rogueImpl = new Council();
        vm.expectRevert("version already registered");
        registry.registerConstitution(COUNCIL_VERSION, address(rogueImpl));

        // the original template is untouched
        assertEq(registry.constitutionImpl(COUNCIL_VERSION), address(councilImpl));
    }

    // ---------------------------------------------------------------
    // cloning
    // ---------------------------------------------------------------

    function test_DeployedInstanceIsAMinimalProxyNotACopy() public {
        address instance = registry.deployConstitution(COUNCIL_VERSION, _councilInit(address(this)));

        assertTrue(instance != address(councilImpl));
        // EIP-1167 minimal proxy runtime is exactly 45 bytes
        assertEq(instance.code.length, 45, "expected an EIP-1167 clone");
        assertTrue(address(councilImpl).code.length > 45, "template should be the full implementation");
    }

    function test_DeployedCloneIsInitializedAtomically() public {
        address instance = registry.deployConstitution(COUNCIL_VERSION, _councilInit(address(this)));
        Council council = Council(instance);

        assertEq(council.owner(), address(this));
        assertEq(council.totalCouncilMembers(), 3);
        assertTrue(council.isCouncil(alice));

        VotingParameters memory params = council.getDefaultVotingParameters();
        assertEq(params.quorumBps, 5000);
        assertEq(params.thresholdBps, 5000);
        assertEq(params.votingPeriod, VOTING_PERIOD);
    }

    // the whole point of initializing inside deployConstitution: there is no
    // window in which someone else can claim the fresh clone
    function test_RevertWhen_ReinitializingADeployedClone() public {
        address instance = registry.deployConstitution(COUNCIL_VERSION, _councilInit(address(this)));

        address[] memory members = new address[](1);
        members[0] = outsider;

        vm.prank(outsider);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Council(instance).initialize(outsider, 1, 1, VOTING_PERIOD, members);
    }

    function test_RevertWhen_DeployingWithoutInitData() public {
        vm.expectRevert("init data required");
        registry.deployConstitution(COUNCIL_VERSION, "");
    }

    function test_RevertWhen_DeployingUnknownVersion() public {
        vm.expectRevert("unknown constitution version");
        registry.deployConstitution(42, _councilInit(address(this)));
    }

    // a failing initializer must not leave a half-built constitution behind
    function test_RevertWhen_InitializerReverts_BubblesReason() public {
        address[] memory members = new address[](2);
        members[0] = alice;
        members[1] = alice; // duplicate
        bytes memory badInit = abi.encodeCall(Council.initialize, (address(this), 5000, 5000, VOTING_PERIOD, members));

        vm.expectRevert("CouncilState: Already a council member");
        registry.deployConstitution(COUNCIL_VERSION, badInit);
    }

    function test_RevertWhen_InitDataSelectorIsUnknown() public {
        // no such function on Council -> clone has no fallback -> revert
        vm.expectRevert();
        registry.deployConstitution(COUNCIL_VERSION, abi.encodeWithSignature("notAFunction(uint256)", 1));
    }

    function test_DeployEmitsEventWithTemplateAndInstance() public {
        vm.recordLogs();
        address instance = registry.deployConstitution(COUNCIL_VERSION, _councilInit(address(this)));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IConstitutionRegistry.ConstitutionDeployed.selector) {
                assertEq(uint256(logs[i].topics[1]), COUNCIL_VERSION);
                (address impl, address emitted) = abi.decode(logs[i].data, (address, address));
                assertEq(impl, address(councilImpl));
                assertEq(emitted, instance);
                found = true;
            }
        }
        assertTrue(found, "ConstitutionDeployed not emitted");
    }

    // ---------------------------------------------------------------
    // instance isolation
    // ---------------------------------------------------------------

    function test_ClonesOfSameVersionHaveIndependentState() public {
        Council a = Council(registry.deployConstitution(COUNCIL_VERSION, _councilInit(address(this))));
        Council b = Council(registry.deployConstitution(COUNCIL_VERSION, _councilInit(outsider)));

        assertTrue(address(a) != address(b));
        assertEq(a.owner(), address(this));
        assertEq(b.owner(), outsider);

        a.removeCouncilMember(carol);
        assertEq(a.totalCouncilMembers(), 2);
        assertEq(b.totalCouncilMembers(), 3, "clones must not share storage");
    }

    function test_CloningDoesNotTouchTheTemplate() public {
        registry.deployConstitution(COUNCIL_VERSION, _councilInit(address(this)));

        assertEq(councilImpl.totalCouncilMembers(), 0);
        assertFalse(councilImpl.isCouncil(alice));
    }

    function test_RevertWhen_InitializingTheTemplateDirectly() public {
        address[] memory members = new address[](1);
        members[0] = outsider;

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        councilImpl.initialize(outsider, 5000, 5000, VOTING_PERIOD, members);
    }

    // ---------------------------------------------------------------
    // multiple constitution types behind one registry
    // ---------------------------------------------------------------

    function test_DifferentVersionsDeployDifferentConstitutionTypes() public {
        Council council = Council(registry.deployConstitution(COUNCIL_VERSION, _councilInit(address(this))));
        RWAHolder holder = RWAHolder(
            registry.deployConstitution(
                RWA_HOLDER_VERSION,
                abi.encodeCall(RWAHolder.initialize, (address(token), 5000, 5000, 1 days))
            )
        );

        assertEq(council.name(), "Council");
        assertEq(holder.name(), "RWAHolder");
        assertEq(holder.rwaToken(), address(token));
    }

    function test_ClonedRWAHolderReadsTokenBalances() public {
        RWAHolder holder = RWAHolder(
            registry.deployConstitution(
                RWA_HOLDER_VERSION,
                abi.encodeCall(RWAHolder.initialize, (address(token), 5000, 5000, 1 days))
            )
        );

        assertFalse(holder.canVote(alice));

        token.mint(alice, 100e18);
        assertTrue(holder.canVote(alice));
        assertTrue(holder.canPropose(alice));
        assertEq(holder.getVotingPower(alice), 100e18);
        assertEq(holder.getQuorum(), 50e18);
    }

    function test_RevertWhen_RWAHolderInitializedWithOutOfRangeBps() public {
        vm.expectRevert("bps must be <= 10000");
        registry.deployConstitution(
            RWA_HOLDER_VERSION,
            abi.encodeCall(RWAHolder.initialize, (address(token), 10_001, 5000, 1 days))
        );
    }

    // ---------------------------------------------------------------
    // deprecation
    // ---------------------------------------------------------------

    function test_DeprecatedVersionCannotBeDeployedAgain() public {
        registry.setDeprecated(COUNCIL_VERSION, true);
        assertTrue(registry.deprecated(COUNCIL_VERSION));

        vm.expectRevert("constitution version deprecated");
        registry.deployConstitution(COUNCIL_VERSION, _councilInit(address(this)));
    }

    // retiring a template must not disturb constitutions already cloned from
    // it -- their implementation pointer is baked into their bytecode
    function test_DeprecationLeavesExistingClonesRunning() public {
        Council council = Council(registry.deployConstitution(COUNCIL_VERSION, _councilInit(address(this))));

        registry.setDeprecated(COUNCIL_VERSION, true);

        assertTrue(council.isCouncil(alice));
        assertEq(council.totalCouncilMembers(), 3);
        council.addCouncilMember(outsider); // still fully operational
        assertTrue(council.isCouncil(outsider));
    }

    function test_DeprecationIsReversible() public {
        registry.setDeprecated(COUNCIL_VERSION, true);
        registry.setDeprecated(COUNCIL_VERSION, false);

        assertFalse(registry.deprecated(COUNCIL_VERSION));
        address instance = registry.deployConstitution(COUNCIL_VERSION, _councilInit(address(this)));
        assertTrue(Council(instance).isCouncil(alice));
    }

    function test_DeprecatingOneVersionLeavesOthersDeployable() public {
        registry.setDeprecated(COUNCIL_VERSION, true);

        address instance = registry.deployConstitution(
            RWA_HOLDER_VERSION,
            abi.encodeCall(RWAHolder.initialize, (address(token), 5000, 5000, 1 days))
        );
        assertEq(RWAHolder(instance).rwaToken(), address(token));
    }

    function test_RevertWhen_DeprecatingUnknownVersion() public {
        vm.expectRevert("unknown constitution version");
        registry.setDeprecated(999, true);
    }

    function test_RevertWhen_NonOwnerDeprecates() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        registry.setDeprecated(COUNCIL_VERSION, true);
    }

    function test_DeprecationEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IConstitutionRegistry.ConstitutionDeprecationSet(COUNCIL_VERSION, true);
        registry.setDeprecated(COUNCIL_VERSION, true);
    }

    // ---------------------------------------------------------------
    // access control
    // ---------------------------------------------------------------

    function test_RevertWhen_NonOwnerRegisters() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        registry.registerConstitution(3, address(councilImpl));
    }

    function test_DeploymentIsPermissionless() public {
        vm.prank(outsider);
        address instance = registry.deployConstitution(COUNCIL_VERSION, _councilInit(outsider));
        assertEq(Council(instance).owner(), outsider);
    }

    function test_OwnershipCanBeTransferred() public {
        registry.transferOwnership(alice);
        assertEq(registry.owner(), alice);

        vm.prank(alice);
        registry.registerConstitution(3, address(councilImpl));
        assertEq(registry.constitutionImpl(3), address(councilImpl));
    }
}
