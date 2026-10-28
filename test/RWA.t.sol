// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EAS} from "@eas/EAS.sol";
import {SchemaRegistry} from "@eas/SchemaRegistry.sol";
import {ISchemaRegistry} from "@eas/ISchemaRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {RWA} from "../src/token/RWA.sol";
import {IComplianceHub} from "../src/compliance/IComplianceHub.sol";
import {IERC7943Fungible} from "../src/interfaces/IERC7943.sol";
import {ComplianceHub} from "../src/compliance/ComplianceHub.sol";
import {KYC, KycTier} from "../src/compliance/rules/KYC.sol";
import {MaxTransferable} from "../src/compliance/rules/MaxTransferable.sol";

// Minimal concrete token for exercising the base: the owner mints, burns,
// freezes and forces. Real tokens choose their own issuance and access control.
contract RWAHarness is RWA, Ownable {
    constructor(IComplianceHub hub) RWA("Test RWA", "tRWA", hub) Ownable(msg.sender) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    function _checkFreezer(address, uint256) internal view override {
        _checkOwner();
    }

    function _checkEnforcer(address, address, uint256) internal view override {
        _checkOwner();
    }
}

contract RWATest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);

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

    // ------------------------------------------------------------- constructor

    function test_constructorStoresHub() public view {
        assertEq(address(token.complianceHub()), address(hub));
    }

    function test_constructorRejectsZeroHub() public {
        vm.expectRevert("zero compliance hub");
        new RWAHarness(IComplianceHub(address(0)));
    }

    // --------------------------------------------------------------- transfers

    function test_mintToKycd() public {
        token.mint(basic, 100);
        assertEq(token.balanceOf(basic), 100);
    }

    function test_RevertWhen_MintToNonKycd() public {
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, nobody));
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
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotSend.selector, basic));
        token.transfer(full, 1);
    }

    function test_RevertWhen_TransferFromIsNonCompliant() public {
        token.mint(full, 100);
        vm.prank(full);
        token.approve(address(this), 100);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, nobody));
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
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotTransfer.selector, full, basic, 51));
        token.transfer(basic, 51);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ ERC-7943 views

    function test_supportsERC7943() public view {
        assertEq(type(IERC7943Fungible).interfaceId, bytes4(0x3edbb4c4));
        assertTrue(token.supportsInterface(0x3edbb4c4));
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
        assertFalse(token.supportsInterface(0xffffffff));
    }

    function test_canSendAndReceiveFollowKyc() public view {
        assertTrue(token.canSend(full));
        assertFalse(token.canSend(basic));
        assertFalse(token.canSend(nobody));
        assertTrue(token.canReceive(full));
        assertTrue(token.canReceive(basic));
        assertFalse(token.canReceive(nobody));
    }

    function test_canTransfer() public {
        token.mint(full, 100);
        assertTrue(token.canTransfer(full, basic, 100));
        assertTrue(token.canTransfer(full, basic, 101));   // balance shortfall is ERC-20's to refuse
        assertFalse(token.canTransfer(full, nobody, 1));
        assertFalse(token.canTransfer(basic, full, 0));
    }

    function test_canTransferRespectsFrozen() public {
        token.mint(full, 100);
        token.setFrozenTokens(full, 30);
        assertTrue(token.canTransfer(full, basic, 70));
        assertFalse(token.canTransfer(full, basic, 71));
    }

    function test_viewsDontRevertWhenHubReverts() public {
        token.mint(full, 100);
        vm.mockCallRevert(address(hub), bytes(""), "boom");
        assertFalse(token.canSend(full));
        assertFalse(token.canReceive(full));
        assertFalse(token.canTransfer(full, basic, 1));
    }

    // ---------------------------------------------------------------- freezing

    function test_setFrozenTokens() public {
        vm.expectEmit(address(token));
        emit IERC7943Fungible.Frozen(full, 500);
        assertTrue(token.setFrozenTokens(full, 500));   // may exceed the balance
        assertEq(token.getFrozenTokens(full), 500);
    }

    function test_setFrozenTokensOnlyOwner() public {
        vm.prank(full);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, full));
        token.setFrozenTokens(full, 1);
    }

    function test_frozenTokensCantBeTransferred() public {
        token.mint(full, 100);
        token.setFrozenTokens(full, 30);

        vm.startPrank(full);
        token.transfer(basic, 70);
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, full, 1, 0)
        );
        token.transfer(basic, 1);
        vm.stopPrank();
    }

    function test_overFreezeLocksIncomingTokens() public {
        token.setFrozenTokens(full, 50);
        token.mint(full, 40);
        vm.prank(full);
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, full, 1, 0)
        );
        token.transfer(basic, 1);
    }

    function test_burnConsumesFrozenTokens() public {
        token.mint(full, 100);
        token.setFrozenTokens(full, 80);

        vm.expectEmit(address(token));
        emit IERC7943Fungible.Frozen(full, 50);   // 20 unfrozen + 30 of the frozen
        vm.expectEmit(address(token));
        emit Transfer(full, address(0), 50);
        token.burn(full, 50);
        assertEq(token.getFrozenTokens(full), 50);
    }

    // --------------------------------------------------------- forced transfer

    function test_forcedTransferFromIneligibleHolder() public {
        token.mint(full, 100);
        vm.prank(provider);
        kyc.revoke(full);   // can no longer send

        vm.expectEmit(address(token));
        emit Transfer(full, basic, 60);
        vm.expectEmit(address(token));
        emit IERC7943Fungible.ForcedTransfer(full, basic, 60);
        assertTrue(token.forcedTransfer(full, basic, 60));
        assertEq(token.balanceOf(basic), 60);
        assertEq(token.balanceOf(full), 40);
    }

    function test_forcedTransferBypassesTransferRules() public {
        token.mint(full, 100);
        maxRule = new MaxTransferable();
        hub.applyRule(address(token), hub.addRule(address(maxRule)), abi.encode(uint256(10)), 0);
        token.forcedTransfer(full, basic, 100);
        assertEq(token.balanceOf(basic), 100);
    }

    function test_forcedTransferReleasesFrozen() public {
        token.mint(full, 100);
        token.setFrozenTokens(full, 100);

        vm.expectEmit(address(token));
        emit IERC7943Fungible.Frozen(full, 60);
        vm.expectEmit(address(token));
        emit Transfer(full, basic, 40);
        token.forcedTransfer(full, basic, 40);
        assertEq(token.getFrozenTokens(full), 60);
    }

    function test_forcedTransferKeepsExcessFreeze() public {
        token.mint(full, 100);
        token.setFrozenTokens(full, 150);
        token.forcedTransfer(full, basic, 100);
        assertEq(token.getFrozenTokens(full), 50);
    }

    function test_RevertWhen_ForcedTransferToIneligible() public {
        token.mint(full, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, nobody));
        token.forcedTransfer(full, nobody, 1);
    }

    function test_RevertWhen_ForcedTransferExceedsBalance() public {
        token.mint(full, 100);
        token.setFrozenTokens(full, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, full, 100, 101));
        token.forcedTransfer(full, basic, 101);
    }

    function test_RevertWhen_ForcedTransferZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.forcedTransfer(address(0), basic, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.forcedTransfer(full, address(0), 1);
    }

    function test_forcedTransferOnlyOwner() public {
        token.mint(full, 100);
        vm.prank(full);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, full));
        token.forcedTransfer(full, basic, 1);
    }
}
