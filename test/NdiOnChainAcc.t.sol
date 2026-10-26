// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Account as OZAccount} from "@openzeppelin/contracts/account/Account.sol";
import {SignerP256} from "@openzeppelin/contracts/utils/cryptography/signers/SignerP256.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {NdiOnChainAcc} from "../src/account/NdiOnChainAcc.sol";
import {NdiOnChainAccFactory} from "../src/account/NdiOnChainAccFactory.sol";

// The villager's phone key is simulated with forge's native P-256 cheatcodes;
// the entry point is an EOA we prank as, so validation and execution are
// exercised without a full bundler / EntryPoint deployment.
contract NdiOnChainAccTest is Test {
    uint256 constant P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    bytes32 constant MODE_BATCH = bytes32(uint256(0x01) << 248);

    address entryPoint = makeAddr("entryPoint");
    address guardian = makeAddr("guardian");
    address outsider = makeAddr("outsider");
    address shop = makeAddr("shop");

    uint256 constant PHONE_KEY = 0xA11CE;
    uint256 constant NEW_PHONE_KEY = 0xB0B;
    bytes32 qx;
    bytes32 qy;

    NdiOnChainAcc impl;
    NdiOnChainAccFactory factory;
    ERC20Mock token;

    function setUp() public {
        impl = new NdiOnChainAcc(IEntryPoint(entryPoint));
        factory = new NdiOnChainAccFactory(address(impl));
        token = new ERC20Mock();
        (qx, qy) = _pub(PHONE_KEY);
    }

    // ---------- factory ----------

    function test_createAccount_matchesPrediction_andIsIdempotent() public {
        address predicted = factory.predictAddress(qx, qy, guardian, 0);
        assertEq(predicted.code.length, 0);

        // funds can land before deployment
        token.mint(predicted, 100e18);

        address account = factory.createAccount(qx, qy, guardian, 0);
        assertEq(account, predicted);
        assertEq(factory.createAccount(qx, qy, guardian, 0), account);

        NdiOnChainAcc a = NdiOnChainAcc(payable(account));
        (bytes32 x, bytes32 y) = a.signer();
        assertEq(x, qx);
        assertEq(y, qy);
        assertEq(a.guardian(), guardian);
        assertEq(address(a.entryPoint()), entryPoint);
        assertEq(token.balanceOf(account), 100e18);
    }

    function test_addressCommitsToKey() public {
        (bytes32 ox, bytes32 oy) = _pub(0xBAD);
        assertTrue(factory.predictAddress(qx, qy, guardian, 0) != factory.predictAddress(ox, oy, guardian, 0));
        assertTrue(factory.predictAddress(qx, qy, guardian, 0) != factory.predictAddress(qx, qy, address(0), 0));
        assertTrue(factory.predictAddress(qx, qy, guardian, 0) != factory.predictAddress(qx, qy, guardian, 1));
    }

    function test_createAccount_rejectsInvalidKey() public {
        vm.expectRevert(abi.encodeWithSelector(SignerP256.SignerP256InvalidPublicKey.selector, bytes32(0), bytes32(0)));
        factory.createAccount(0, 0, guardian, 0);
    }

    function test_cannotReinitialize() public {
        NdiOnChainAcc a = _create(guardian);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        a.initialize(qx, qy, outsider);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(qx, qy, outsider);
    }

    // ---------- userOp validation ----------

    function test_validateUserOp_rawP256() public {
        NdiOnChainAcc a = _create(guardian);
        bytes32 userOpHash = keccak256("userOp");

        vm.prank(entryPoint);
        assertEq(a.validateUserOp(_op(address(a), _sign(PHONE_KEY, userOpHash)), userOpHash, 0), 0);
    }

    function test_validateUserOp_wrongKeyFails() public {
        NdiOnChainAcc a = _create(guardian);
        bytes32 userOpHash = keccak256("userOp");

        vm.prank(entryPoint);
        assertEq(a.validateUserOp(_op(address(a), _sign(0xBAD, userOpHash)), userOpHash, 0), 1);
    }

    // UP | UV: user present and verified (biometric / PIN), as phones send.
    bytes1 constant FLAGS_UP_UV = 0x05;

    function test_validateUserOp_webAuthn() public {
        NdiOnChainAcc a = _create(guardian);
        bytes32 userOpHash = keccak256("userOp");

        bytes memory sig = _signWebAuthn(PHONE_KEY, userOpHash, FLAGS_UP_UV);

        vm.prank(entryPoint);
        assertEq(a.validateUserOp(_op(address(a), sig), userOpHash, 0), 0);
    }

    function test_validateUserOp_webAuthnWrongKeyFails() public {
        NdiOnChainAcc a = _create(guardian);
        bytes32 userOpHash = keccak256("userOp");

        bytes memory sig = _signWebAuthn(0xBAD, userOpHash, FLAGS_UP_UV);

        vm.prank(entryPoint);
        assertEq(a.validateUserOp(_op(address(a), sig), userOpHash, 0), 1);
    }

    // An assertion for one userOp can't be replayed to authorize another.
    function test_validateUserOp_webAuthnWrongChallengeFails() public {
        NdiOnChainAcc a = _create(guardian);
        bytes memory sig = _signWebAuthn(PHONE_KEY, keccak256("other userOp"), FLAGS_UP_UV);

        vm.prank(entryPoint);
        assertEq(a.validateUserOp(_op(address(a), sig), keccak256("userOp"), 0), 1);
    }

    // Presence alone (no biometric / PIN) is not enough.
    function test_validateUserOp_webAuthnRequiresUserVerification() public {
        NdiOnChainAcc a = _create(guardian);
        bytes32 userOpHash = keccak256("userOp");

        bytes memory sig = _signWebAuthn(PHONE_KEY, userOpHash, 0x01);

        vm.prank(entryPoint);
        assertEq(a.validateUserOp(_op(address(a), sig), userOpHash, 0), 1);
    }

    function test_validateUserOp_malformedSignatureFails() public {
        NdiOnChainAcc a = _create(guardian);
        bytes32 userOpHash = keccak256("userOp");

        vm.prank(entryPoint);
        assertEq(a.validateUserOp(_op(address(a), hex"deadbeef"), userOpHash, 0), 1);
    }

    function test_validateUserOp_onlyEntryPoint() public {
        NdiOnChainAcc a = _create(guardian);
        bytes32 userOpHash = keccak256("userOp");
        PackedUserOperation memory op = _op(address(a), _sign(PHONE_KEY, userOpHash));

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, outsider));
        a.validateUserOp(op, userOpHash, 0);
    }

    function test_validateUserOp_paysPrefund() public {
        NdiOnChainAcc a = _create(guardian);
        vm.deal(address(a), 1 ether);
        bytes32 userOpHash = keccak256("userOp");

        vm.prank(entryPoint);
        a.validateUserOp(_op(address(a), _sign(PHONE_KEY, userOpHash)), userOpHash, 0.1 ether);
        assertEq(entryPoint.balance, 0.1 ether);
    }

    // ---------- execution ----------

    function test_execute_batchFromEntryPoint() public {
        NdiOnChainAcc a = _create(guardian);
        token.mint(address(a), 100e18);

        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(token), 0, abi.encodeCall(token.transfer, (shop, 30e18)));
        calls[1] = Execution(address(token), 0, abi.encodeCall(token.transfer, (outsider, 20e18)));

        vm.prank(entryPoint);
        a.execute(MODE_BATCH, abi.encode(calls));

        assertEq(token.balanceOf(shop), 30e18);
        assertEq(token.balanceOf(outsider), 20e18);
        assertEq(token.balanceOf(address(a)), 50e18);
    }

    function test_execute_rejectsOutsider() public {
        NdiOnChainAcc a = _create(guardian);
        token.mint(address(a), 100e18);

        Execution[] memory calls = new Execution[](1);
        calls[0] = Execution(address(token), 0, abi.encodeCall(token.transfer, (outsider, 100e18)));

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, outsider));
        a.execute(MODE_BATCH, abi.encode(calls));
    }

    function test_receivesEth() public {
        NdiOnChainAcc a = _create(guardian);
        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        (bool ok,) = address(a).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(a).balance, 1 ether);
    }

    // ---------- key rotation / recovery ----------

    function test_setSigner_viaEntryPoint() public {
        NdiOnChainAcc a = _create(guardian);
        (bytes32 nx, bytes32 ny) = _pub(NEW_PHONE_KEY);

        vm.prank(entryPoint);
        a.setSigner(nx, ny);

        bytes32 userOpHash = keccak256("after rotation");
        vm.startPrank(entryPoint);
        assertEq(a.validateUserOp(_op(address(a), _sign(NEW_PHONE_KEY, userOpHash)), userOpHash, 0), 0);
        assertEq(a.validateUserOp(_op(address(a), _sign(PHONE_KEY, userOpHash)), userOpHash, 0), 1);
        vm.stopPrank();
    }

    function test_setSigner_rejectsOutsider() public {
        NdiOnChainAcc a = _create(guardian);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, outsider));
        a.setSigner(qx, qy);
    }

    function test_guardianRecoversLostPhone() public {
        NdiOnChainAcc a = _create(guardian);
        (bytes32 nx, bytes32 ny) = _pub(NEW_PHONE_KEY);

        vm.prank(guardian);
        a.recover(nx, ny);

        bytes32 userOpHash = keccak256("recovered");
        vm.prank(entryPoint);
        assertEq(a.validateUserOp(_op(address(a), _sign(NEW_PHONE_KEY, userOpHash)), userOpHash, 0), 0);
    }

    function test_recover_rejectsNonGuardian() public {
        NdiOnChainAcc a = _create(guardian);
        vm.prank(outsider);
        vm.expectRevert(NdiOnChainAcc.NotGuardian.selector);
        a.recover(qx, qy);
    }

    function test_recover_disabledWithoutGuardian() public {
        NdiOnChainAcc a = _create(address(0));
        vm.prank(address(0));
        vm.expectRevert(NdiOnChainAcc.NotGuardian.selector);
        a.recover(qx, qy);
    }

    function test_setGuardian_viaEntryPoint() public {
        NdiOnChainAcc a = _create(guardian);
        vm.prank(entryPoint);
        a.setGuardian(outsider);
        assertEq(a.guardian(), outsider);

        vm.prank(guardian);
        vm.expectRevert(NdiOnChainAcc.NotGuardian.selector);
        a.recover(qx, qy);
    }

    // ---------- helpers ----------

    function _create(address guardian_) internal returns (NdiOnChainAcc) {
        return NdiOnChainAcc(payable(factory.createAccount(qx, qy, guardian_, 0)));
    }

    function _pub(uint256 pk) internal pure returns (bytes32, bytes32) {
        (uint256 x, uint256 y) = vm.publicKeyP256(pk);
        return (bytes32(x), bytes32(y));
    }

    // OZ P256.verify rejects high-s (malleable) signatures.
    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (bytes32 r, bytes32 s) = vm.signP256(pk, digest);
        if (uint256(s) > P256_N / 2) s = bytes32(P256_N - uint256(s));
        return abi.encodePacked(r, s);
    }

    // A passkey assertion as the phone's authenticator would produce it:
    // flags in authenticatorData[32], the userOp hash as the base64url
    // challenge in clientDataJSON, and a P-256 signature over
    // sha256(authenticatorData || sha256(clientDataJSON)).
    function _signWebAuthn(uint256 pk, bytes32 challenge, bytes1 flags) internal pure returns (bytes memory) {
        bytes memory authData = abi.encodePacked(keccak256("ndi.bt"), flags, uint32(1));
        string memory prefix = '{"type":"webauthn.get",';
        string memory clientData = string.concat(
            prefix, '"challenge":"', Base64.encodeURL(abi.encodePacked(challenge)), '","origin":"https://ndi.bt"}'
        );
        bytes memory sig = _sign(pk, sha256(abi.encodePacked(authData, sha256(bytes(clientData)))));
        (bytes32 r, bytes32 s) = abi.decode(sig, (bytes32, bytes32));
        // WebAuthn.tryDecodeAuth reads the WebAuthnAuth fields as a flat tuple,
        // without the leading offset abi.encode(struct) would add.
        return abi.encode(r, s, bytes(prefix).length, uint256(1), authData, clientData);
    }

    function _op(address sender, bytes memory signature) internal pure returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.signature = signature;
    }
}
