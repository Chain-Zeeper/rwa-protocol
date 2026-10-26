// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EAS} from "@eas/EAS.sol";
import {SchemaRegistry} from "@eas/SchemaRegistry.sol";
import {ISchemaRegistry} from "@eas/ISchemaRegistry.sol";

import {RWA} from "../src/tokens/RWA.sol";
import {IComplianceHub} from "../src/token policy/IComplianceHub.sol";
import {ComplianceHub} from "../src/compliance/ComplianceHub.sol";
import {KYC, KycTier} from "../src/tokens/Rules.sol/KYC.sol";
import {MaxTransferable} from "../src/tokens/Rules.sol/MaxTransferable.sol";

// RWA has no issuance of its own; expose _mint/_burn to drive _update.
contract RWAHarness is RWA {
    constructor(IComplianceHub hub) RWA("Test RWA", "tRWA", hub) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract RWATest is Test {
    ComplianceHub hub;
    KYC kyc;
    MaxTransferable maxRule;
    RWAHarness token;

    address provider = makeAddr("provider");
    address basic = makeAddr("basic");
    address full = makeAddr("full");
    address nobody = makeAddr("nobody");

    function setUp() public {
        SchemaRegistry registry = new SchemaRegistry();
        kyc = new KYC(new EAS(ISchemaRegistry(address(registry))));
        kyc.grantRole(kyc.KYC_PROVIDER(), provider);
        vm.startPrank(provider);
        kyc.attest(basic, KycTier.Basic, bytes32(0), "NDI", 0);
        kyc.attest(full, KycTier.Full, bytes32(0), "NDI", 0);
        vm.stopPrank();

        hub = new ComplianceHub();
        hub.grantRole(hub.COMPLIANCE_AUDITOR(), address(this));
        hub.grantRole(hub.COMPLIANCE_OFFICER(), address(this));
        token = new RWAHarness(hub);
        hub.applyRule(address(token), hub.addRule(address(kyc)), "", 0);
    }

    function test_constructorStoresHub() public view {
        assertEq(address(token.complianceHub()), address(hub));
    }

    function test_constructorRejectsZeroHub() public {
        vm.expectRevert("zero compliance hub");
        new RWAHarness(IComplianceHub(address(0)));
    }

    function test_mintToKycd() public {
        token.mint(basic, 100);
        assertEq(token.balanceOf(basic), 100);
    }

    function test_RevertWhen_MintToNonKycd() public {
        vm.expectRevert("transfer not compliant");
        token.mint(nobody, 100);
    }

    function test_fullCanTransfer() public {
        token.mint(full, 100);
        vm.prank(full);
        token.transfer(basic, 40);
        assertEq(token.balanceOf(basic), 40);
        assertEq(token.balanceOf(full), 60);
    }

    function test_RevertWhen_BasicTransfers() public {
        token.mint(basic, 100);
        vm.prank(basic);
        vm.expectRevert("transfer not compliant");
        token.transfer(full, 1);
    }

    function test_RevertWhen_TransferFromIsNonCompliant() public {
        token.mint(full, 100);
        vm.prank(full);
        token.approve(address(this), 100);
        vm.expectRevert("transfer not compliant");
        token.transferFrom(full, nobody, 1);
    }

    function test_burnAllowedAfterKycRevoked() public {
        token.mint(full, 100);
        vm.prank(provider);
        kyc.revoke(full);

        token.burn(full, 100);
        assertEq(token.balanceOf(full), 0);
    }

    function test_maxTransferableEnforced() public {
        token.mint(full, 100);   // before the cap: it applies to mints too
        maxRule = new MaxTransferable();
        hub.applyRule(address(token), hub.addRule(address(maxRule)), abi.encode(uint256(50)), 0);

        vm.startPrank(full);
        token.transfer(basic, 50);   // at the cap
        vm.expectRevert("transfer not compliant");
        token.transfer(basic, 51);
        vm.stopPrank();
    }
}
