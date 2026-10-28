// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {ERC7821} from "@openzeppelin/contracts/account/extensions/draft-ERC7821.sol";
import {IEntryPoint} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {AbstractSigner} from "@openzeppelin/contracts/utils/cryptography/signers/AbstractSigner.sol";
import {ERC7739} from "@openzeppelin/contracts/utils/cryptography/signers/draft-ERC7739.sol";
import {SignerP256} from "@openzeppelin/contracts/utils/cryptography/signers/SignerP256.sol";
import {SignerWebAuthn} from "@openzeppelin/contracts/utils/cryptography/signers/SignerWebAuthn.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

// ERC-4337 smart account owned by a P-256 key living on the villager's phone
// (Secure Enclave / Android Keystore / passkey). Accepts either a WebAuthn
// assertion (passkeys) or a raw 64-byte P-256 signature (native keystore).
//
// The app uses the native keystore path: a device-bound key behind the phone's
// biometric, created after NDI onboarding, with NDI re-verification plus the
// guardian as recovery. The WebAuthn path is kept, unused, so passkeys stay an
// option later without a new implementation.
//
// A single implementation is deployed; users get EIP-1167 clones from
// NdiOnChainAccFactory. The entry point is an immutable of the
// implementation, so every clone shares it.
//
// Optional guardian (e.g. the co-op / governor) can rotate the device key when
// a phone is lost. address(0) disables recovery. The guardian can move funds
// indirectly by installing its own key, so it must be trusted accordingly.
contract NdiOnChainAcc is Account, SignerWebAuthn, ERC7739, ERC7821, ERC721Holder, ERC1155Holder, Initializable {
    IEntryPoint private immutable _entryPoint;

    address public guardian;

    event SignerChanged(bytes32 qx, bytes32 qy);
    event GuardianChanged(address guardian);

    error NotGuardian();

    // SignerP256 insists on a valid key at construction. The implementation's
    // own key is never used by clones, but it must not be signable: this point
    // has x = keccak256("NdiOnChainAcc.implementation") + 3 (the first x at
    // or after the hash that lies on P-256), so its private key is unknown to anyone.
    bytes32 private constant _IMPL_QX = bytes32(uint256(keccak256("NdiOnChainAcc.implementation")) + 3);
    bytes32 private constant _IMPL_QY = 0xbd15491b7f1fc86aaeed1c847f45d87670bd05ae7e30ae00d1598ebe3201baae;

    constructor(IEntryPoint entryPoint_) EIP712("NdiOnChainAcc", "1") SignerP256(_IMPL_QX, _IMPL_QY) {
        _entryPoint = entryPoint_;
        _disableInitializers();
    }

    function initialize(bytes32 qx, bytes32 qy, address guardian_) external initializer {
        _setSigner(qx, qy);
        guardian = guardian_;
        emit SignerChanged(qx, qy);
        emit GuardianChanged(guardian_);
    }

    function entryPoint() public view override returns (IEntryPoint) {
        return _entryPoint;
    }

    // Key rotation signed by the current device key (new phone, old phone still available).
    function setSigner(bytes32 qx, bytes32 qy) external onlyEntryPointOrSelf {
        _setSigner(qx, qy);
        emit SignerChanged(qx, qy);
    }

    function setGuardian(address guardian_) external onlyEntryPointOrSelf {
        guardian = guardian_;
        emit GuardianChanged(guardian_);
    }

    // Lost-phone recovery.
    function recover(bytes32 qx, bytes32 qy) external {
        if (guardian == address(0) || msg.sender != guardian) revert NotGuardian();
        _setSigner(qx, qy);
        emit SignerChanged(qx, qy);
    }

    // WebAuthn first; fall back to a raw P-256 (r, s) signature.
    function _rawSignatureValidation(bytes32 hash, bytes calldata signature)
        internal
        view
        override(AbstractSigner, SignerWebAuthn)
        returns (bool)
    {
        if (signature.length == 64) return SignerP256._rawSignatureValidation(hash, signature);
        return SignerWebAuthn._rawSignatureValidation(hash, signature);
    }

    // Lets the entry point call execute() directly (the usual userOp.callData).
    function _erc7821AuthorizedExecutor(address caller, bytes32 mode, bytes calldata executionData)
        internal
        view
        override
        returns (bool)
    {
        return caller == address(entryPoint()) || super._erc7821AuthorizedExecutor(caller, mode, executionData);
    }
}
