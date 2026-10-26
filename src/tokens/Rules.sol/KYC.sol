// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IEAS, AttestationRequest, AttestationRequestData, RevocationRequest, RevocationRequestData} from "@eas/IEAS.sol";
import {ISchemaRegistry} from "@eas/ISchemaRegistry.sol";
import {ISchemaResolver} from "@eas/resolver/ISchemaResolver.sol";
import {IRule} from "../../token policy/IRule.sol";

// Basic: can hold and receive.  Full: can hold, receive and send.
// Not KYC'd (no attestation, or revoked / expired): can't receive or send.
enum KycTier { Basic, Full }

error NOT_KYCD(address account);

// KYC rule backed by the Ethereum Attestation Service. This contract is the
// sole attester for its schema: KYC providers call attest/revoke here, which
// writes the public EAS record and a local copy that check() reads cheaply.
// The copy can't drift from EAS, since only the attester (this contract) can
// revoke its attestations there.
//
// Only verified KYC is attested. Subject, verification time, expiry and
// revocation are EAS's own attestation fields (recipient, time,
// expirationTime, revocationTime), so the schema carries just the rest.
contract KYC is IRule, AccessControl {
    event KYCAttested(address indexed account, bytes32 indexed uid, KycTier tier, uint64 expirationTime);
    event KYCRevoked(address indexed account, bytes32 indexed uid);

    struct Record {
        bytes32 uid;             // 0 = not KYC'd
        uint64 expirationTime;   // 0 = never expires
        KycTier tier;
    }

    bytes32 public constant KYC_PROVIDER = keccak256("KYC_PROVIDER");

    // tier:       KycTier as uint8
    // kycRef:     keccak256(secret salt, off-chain KYC record id) -- links to
    //             the provider's database without putting PII or a raw,
    //             correlatable id on-chain
    // providerId: which verifier did the check (e.g. NDI, manual, partner)
    // A new layout means a new schema string, and so a new schema UID: the UID
    // is the version.
    string public constant SCHEMA = "uint8 tier,bytes32 kycRef,bytes32 providerId";

    IEAS public immutable eas;
    bytes32 public immutable schemaUID;

    mapping(address => Record) public records;

    constructor(IEAS _eas) {
        eas = _eas;
        ISchemaRegistry registry = _eas.getSchemaRegistry();
        // Same derivation as SchemaRegistry._getUID. A schema can only be
        // registered once, so a redeployed rule reuses the existing one.
        bytes32 uid = keccak256(abi.encodePacked(SCHEMA, ISchemaResolver(address(0)), true));
        if (registry.getSchema(uid).uid == bytes32(0)) {
            uid = registry.register(SCHEMA, ISchemaResolver(address(0)), true);
        }
        schemaUID = uid;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // Attests `account` at `tier`. An existing attestation is revoked first,
    // so this also handles tier changes and renewals.
    function attest(address account, KycTier tier, bytes32 kycRef, bytes32 providerId, uint64 expirationTime)
        external onlyRole(KYC_PROVIDER) returns (bytes32 uid)
    {
        if (records[account].uid != bytes32(0)) _revoke(account);

        uid = eas.attest(AttestationRequest({
            schema: schemaUID,
            data: AttestationRequestData({
                recipient: account,
                expirationTime: expirationTime,
                revocable: true,
                refUID: bytes32(0),
                data: abi.encode(uint8(tier), kycRef, providerId),
                value: 0
            })
        }));
        records[account] = Record(uid, expirationTime, tier);
        emit KYCAttested(account, uid, tier, expirationTime);
    }

    function revoke(address account) external onlyRole(KYC_PROVIDER) {
        if (records[account].uid == bytes32(0)) revert NOT_KYCD(account);
        _revoke(account);
    }

    function _revoke(address account) private {
        bytes32 uid = records[account].uid;
        eas.revoke(RevocationRequest({schema: schemaUID, data: RevocationRequestData({uid: uid, value: 0})}));
        delete records[account];
        emit KYCRevoked(account, uid);
    }

    // Whether `account` has a live attestation, and at which tier.
    function kycOf(address account) public view returns (bool kycd, KycTier tier) {
        Record storage r = records[account];
        kycd = r.uid != bytes32(0) && (r.expirationTime == 0 || r.expirationTime > block.timestamp);
        tier = r.tier;
    }

    // Mint (from == 0) only needs the recipient to be able to receive; burn
    // (to == 0) needs nothing, so a holder who can't send can still be redeemed.
    function check(address, address _from, address _to, uint256, bytes memory) external view returns (bool) {
        if (_to == address(0)) return true;   // burn
        (bool toKycd,) = kycOf(_to);
        if (!toKycd) return false;
        if (_from == address(0)) return true;   // mint
        (bool fromKycd, KycTier fromTier) = kycOf(_from);
        return fromKycd && fromTier == KycTier.Full;
    }

    function name() external pure returns (string memory) {
        return "KYC";
    }

    function ruleReference() external pure returns (string memory) {
        return "KYC";
    }
}
