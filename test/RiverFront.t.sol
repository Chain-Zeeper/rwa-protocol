// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EAS} from "@eas/EAS.sol";
import {SchemaRegistry} from "@eas/SchemaRegistry.sol";
import {ISchemaRegistry} from "@eas/ISchemaRegistry.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RiverFront} from "../src/token/examples/RiverFront.sol";
import {IERC7943Fungible} from "../src/interfaces/IERC7943.sol";
import {ComplianceHub} from "../src/compliance/ComplianceHub.sol";
import {KYC, KycTier} from "../src/compliance/rules/KYC.sol";

// Supply and role wiring; the ERC-7943 behaviour itself is covered in RWA.t.sol.
contract RiverFrontTest is Test {
    uint256 constant SUPPLY = 1_000_000e18;

    ComplianceHub hub;
    KYC kyc;
    RiverFront token;

    address admin = makeAddr("admin");
    address agent = makeAddr("agent");
    address treasury = makeAddr("treasury");
    address provider = makeAddr("provider");
    address basic = makeAddr("basic");
    address nobody = makeAddr("nobody");

    function setUp() public {
        SchemaRegistry registry = new SchemaRegistry();
        kyc = new KYC(new EAS(ISchemaRegistry(address(registry))));
        kyc.grantRole(kyc.KYC_PROVIDER(), provider);
        vm.startPrank(provider);
        kyc.attest(basic, KycTier.Basic, bytes32(0), "NDI", 0);
        kyc.attest(treasury, KycTier.Full, bytes32(0), "NDI", 0);
        vm.stopPrank();

        hub = new ComplianceHub();
        hub.grantRole(hub.COMPLIANCE_AUDITOR(), address(this));
        hub.grantRole(hub.COMPLIANCE_OFFICER(), address(this));
        token = new RiverFront(hub, admin, treasury, SUPPLY);
        hub.applyRule(address(token), hub.addRule(address(kyc)), "", 0);
    }

    function _unauthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    // ------------------------------------------------------------------ supply

    function test_initialSupplyToTreasury() public view {
        assertEq(token.name(), "RiverFront");
        assertEq(token.symbol(), "RIVER");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(treasury), SUPPLY);
    }

    function test_treasuryDistributesToKycd() public {
        vm.startPrank(treasury);
        token.transfer(basic, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, nobody));
        token.transfer(nobody, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(basic), 1_000e18);
    }

    function test_mintAddsSupply() public {
        vm.prank(admin);
        token.mint(basic, 500e18);
        assertEq(token.totalSupply(), SUPPLY + 500e18);
    }

    function test_RevertWhen_MintToNonKycd() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, nobody));
        token.mint(nobody, 1);
    }

    function test_burnReducesSupply() public {
        vm.prank(admin);
        token.burn(treasury, 400_000e18);
        assertEq(token.totalSupply(), 600_000e18);
    }

    function test_constructorRejectsZeroTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        new RiverFront(hub, admin, address(0), SUPPLY);
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert("zero admin");
        new RiverFront(hub, address(0), treasury, SUPPLY);
    }

    // ------------------------------------------------------------------- roles

    function test_adminStartsWithEveryRole() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.MINTER_ROLE(), admin));
        assertTrue(token.hasRole(token.BURNER_ROLE(), admin));
        assertTrue(token.hasRole(token.FREEZER_ROLE(), admin));
        assertTrue(token.hasRole(token.FORCE_TRANSFER_ROLE(), admin));
    }

    function test_eachActionNeedsItsRole() public {
        vm.startPrank(agent);
        vm.expectRevert(_unauthorized(agent, token.MINTER_ROLE()));
        token.mint(basic, 1);
        vm.expectRevert(_unauthorized(agent, token.BURNER_ROLE()));
        token.burn(treasury, 1);
        vm.expectRevert(_unauthorized(agent, token.FREEZER_ROLE()));
        token.setFrozenTokens(treasury, 1);
        vm.expectRevert(_unauthorized(agent, token.FORCE_TRANSFER_ROLE()));
        token.forcedTransfer(treasury, basic, 1);
        vm.stopPrank();
    }

    // The issuer keeps issuance; a transfer agent takes over enforcement.
    function test_handEnforcementToTransferAgent() public {
        vm.startPrank(admin);
        token.grantRole(token.FREEZER_ROLE(), agent);
        token.grantRole(token.FORCE_TRANSFER_ROLE(), agent);
        token.revokeRole(token.FREEZER_ROLE(), admin);
        token.revokeRole(token.FORCE_TRANSFER_ROLE(), admin);

        vm.expectRevert(_unauthorized(admin, token.FREEZER_ROLE()));
        token.setFrozenTokens(treasury, 10);
        vm.stopPrank();

        vm.startPrank(agent);
        token.setFrozenTokens(treasury, 10);
        token.forcedTransfer(treasury, basic, 50);
        vm.expectRevert(_unauthorized(agent, token.MINTER_ROLE()));
        token.mint(basic, 1);
        vm.stopPrank();

        assertEq(token.getFrozenTokens(treasury), 10);
        assertEq(token.balanceOf(basic), 50);
    }

    function test_freezeAndForceRolesAreIndependent() public {
        bytes32 freezer = token.FREEZER_ROLE();
        vm.prank(admin);
        token.grantRole(freezer, agent);

        vm.startPrank(agent);
        token.setFrozenTokens(treasury, 10);
        vm.expectRevert(_unauthorized(agent, token.FORCE_TRANSFER_ROLE()));
        token.forcedTransfer(treasury, basic, 1);
        vm.stopPrank();
    }

    function test_roleMembersAreEnumerable() public {
        bytes32 freezer = token.FREEZER_ROLE();
        vm.prank(admin);
        token.grantRole(freezer, agent);
        assertEq(token.getRoleMemberCount(freezer), 2);
        assertEq(token.getRoleMember(freezer, 0), admin);
        assertEq(token.getRoleMember(freezer, 1), agent);
    }

    function test_supportsInterfaces() public view {
        assertTrue(token.supportsInterface(type(IERC7943Fungible).interfaceId));
        assertTrue(token.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertTrue(token.supportsInterface(type(IAccessControl).interfaceId));
    }
}
