// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {EAS} from "@eas/EAS.sol";
import {SchemaRegistry} from "@eas/SchemaRegistry.sol";
import {ISchemaRegistry} from "@eas/ISchemaRegistry.sol";
import {Attestation} from "@eas/Common.sol";

import {KYC, KycTier, NOT_KYCD} from "../src/tokens/Rules.sol/KYC.sol";
import {ComplianceHub} from "../src/compliance/ComplianceHub.sol";

contract KYCTest is Test {
    SchemaRegistry registry;
    EAS eas;
    KYC kyc;

    address provider = makeAddr("provider");
    address outsider = makeAddr("outsider");
    address token = makeAddr("token");
    address basic = makeAddr("basic");
    address full = makeAddr("full");
    address nobody = makeAddr("nobody");

    bytes32 constant REF = keccak256("salt|record-42");
    bytes32 constant PROVIDER_ID = "NDI";

    function setUp() public {
        registry = new SchemaRegistry();
        eas = new EAS(ISchemaRegistry(address(registry)));
        kyc = new KYC(eas);
        kyc.grantRole(kyc.KYC_PROVIDER(), provider);

        vm.startPrank(provider);
        kyc.attest(basic, KycTier.Basic, REF, PROVIDER_ID, 0);
        kyc.attest(full, KycTier.Full, REF, PROVIDER_ID, 0);
        vm.stopPrank();
    }

    function _canTransfer(address from, address to) internal view returns (bool) {
        return kyc.check(token, from, to, 1, "");
    }

    // ------------------------------------------------------------------ schema

    function test_schemaRegistered() public view {
        assertEq(registry.getSchema(kyc.schemaUID()).schema, kyc.SCHEMA());
    }

    function test_redeployReusesSchema() public {
        KYC second = new KYC(eas);
        assertEq(second.schemaUID(), kyc.schemaUID());
    }

    // -------------------------------------------------------------- attest/EAS

    function test_attestWritesEASRecord() public view {
        (bytes32 uid,,) = kyc.records(full);
        Attestation memory a = eas.getAttestation(uid);

        assertEq(a.schema, kyc.schemaUID());
        assertEq(a.recipient, full);
        assertEq(a.attester, address(kyc));
        assertTrue(a.revocable);
        (uint8 tier, bytes32 ref, bytes32 providerId) = abi.decode(a.data, (uint8, bytes32, bytes32));
        assertEq(tier, uint8(KycTier.Full));
        assertEq(ref, REF);
        assertEq(providerId, PROVIDER_ID);
    }

    function test_reAttestRevokesPrevious() public {
        (bytes32 oldUid,,) = kyc.records(basic);
        vm.prank(provider);
        bytes32 newUid = kyc.attest(basic, KycTier.Full, REF, PROVIDER_ID, 0);

        assertTrue(eas.getAttestation(oldUid).revocationTime != 0);
        assertTrue(eas.isAttestationValid(newUid));
        (, KycTier tier) = kyc.kycOf(basic);
        assertEq(uint8(tier), uint8(KycTier.Full));
        assertTrue(_canTransfer(basic, nobody) == false);   // nobody still can't receive
        assertTrue(_canTransfer(basic, full));               // upgraded: can send now
    }

    function test_attestOnlyProvider() public {
        bytes32 role = kyc.KYC_PROVIDER();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role));
        kyc.attest(nobody, KycTier.Full, REF, PROVIDER_ID, 0);
    }

    // -------------------------------------------------------------------- tiers

    function test_fullToFull() public {
        address full2 = makeAddr("full2");
        vm.prank(provider);
        kyc.attest(full2, KycTier.Full, REF, PROVIDER_ID, 0);
        assertTrue(_canTransfer(full, full2));
    }

    function test_fullToBasic() public view {
        assertTrue(_canTransfer(full, basic));
    }

    function test_basicCannotSend() public view {
        assertFalse(_canTransfer(basic, full));
    }

    function test_notKycdCannotReceive() public view {
        assertFalse(_canTransfer(full, nobody));
    }

    function test_notKycdCannotSend() public view {
        assertFalse(_canTransfer(nobody, full));
    }

    function test_mintNeedsReceiver() public view {
        assertTrue(_canTransfer(address(0), basic));
        assertFalse(_canTransfer(address(0), nobody));
    }

    function test_burnAlwaysAllowed() public view {
        assertTrue(_canTransfer(basic, address(0)));
        assertTrue(_canTransfer(nobody, address(0)));
    }

    // ------------------------------------------------------------------- revoke

    function test_revokeBlocksAndRevokesOnEAS() public {
        (bytes32 uid,,) = kyc.records(full);
        vm.prank(provider);
        kyc.revoke(full);

        assertTrue(eas.getAttestation(uid).revocationTime != 0);
        (bool kycd,) = kyc.kycOf(full);
        assertFalse(kycd);
        assertFalse(_canTransfer(full, basic));
        assertFalse(_canTransfer(basic, full));
    }

    function test_revokeNotKycdReverts() public {
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(NOT_KYCD.selector, nobody));
        kyc.revoke(nobody);
    }

    function test_revokeOnlyProvider() public {
        bytes32 role = kyc.KYC_PROVIDER();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role));
        kyc.revoke(full);
    }

    // ------------------------------------------------------------------- expiry

    function test_expiredAttestationBlocks() public {
        address temp = makeAddr("temp");
        uint64 expiry = uint64(block.timestamp + 30 days);
        vm.prank(provider);
        kyc.attest(temp, KycTier.Full, REF, PROVIDER_ID, expiry);
        assertTrue(_canTransfer(temp, full));

        vm.warp(expiry);
        assertFalse(_canTransfer(temp, full));
        assertFalse(_canTransfer(full, temp));
    }

    // ---------------------------------------------------------- through the hub

    function test_enforcedThroughComplianceHub() public {
        ComplianceHub hub = new ComplianceHub();
        hub.grantRole(hub.COMPLIANCE_AUDITOR(), address(this));
        hub.grantRole(hub.COMPLIANCE_OFFICER(), address(this));
        uint8 idx = hub.addRule(address(kyc));
        hub.applyRule(token, idx, "", 0);

        assertTrue(hub.canTransfer(token, full, basic, 1));
        assertFalse(hub.canTransfer(token, basic, full, 1));
        assertFalse(hub.canTransfer(token, full, nobody, 1));
    }
}
