// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRule} from "./IRule.sol";
import {IComplianceHub} from "./IComplianceHub.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

struct Rule {
    address ruleAddress;
    // No new adoptions; tokens already enforcing it keep running it until
    // their officer migrates. One-way.
    bool deprecated;
    // Emergency stop: canTransfer fails closed for every token enforcing it.
    bool suspended;
    bytes32 codeHash;
}
struct RuleParams {
    bytes params;
    bytes32 docHash;
}

error INVALID_RULE();
error RULE_CODE_CHANGED(uint8 index);
error RULE_LIMIT();
error RULE_NOT_ADOPTABLE(uint8 index);
error RULE_ALREADY_ON(uint8 index);
error RULE_NOT_ON(uint8 index);
error STALE_POLICY();

// Rules are registered globally and addressed by index (0-255). Each token's
// policy is a uint256 bitmask: bit i set => rule i is enforced on that token,
// with ruleParams[token][i] passed to the rule's check().
contract ComplianceHub is IComplianceHub, AccessControl {
    event RuleAdded(uint8 indexed index, address indexed ruleAddress, bytes32 codeHash);
    event PolicyUpdated(address indexed token, uint256 oldMask, uint256 newMask);
    event PolicyParametersApplied(address indexed token, uint8 indexed index, bytes32 docHash);
    event RuleDeprecated(uint8 indexed index);
    event RuleSuspended(uint8 indexed index, bool suspended);

    mapping(uint8 => Rule) public ruleByIndex;
    // uint16 so all 256 slots are usable: with a uint8 the increment after
    // registering index 255 overflows and reverts.
    uint16 public nextIndex;
    mapping(address => uint256) public policy;
    mapping(address => mapping(uint8 => RuleParams)) public ruleParams;

    bytes32 public constant COMPLIANCE_OFFICER = keccak256("COMPLIANCE_OFFICER");
    bytes32 public constant COMPLIANCE_AUDITOR = keccak256("COMPLIANCE_AUDITOR");

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    enum Query { Transfer, Send, Receive }

    function canTransfer(address token, address from, address to, uint256 amt)
        external view returns (bool)
    {
        return _evaluate(token, Query.Transfer, from, to, amt);
    }

    // Account-level eligibility for ERC-7943 canSend / canReceive: every rule
    // the token enforces must accept the account.
    function canSend(address token, address account) external view returns (bool) {
        return _evaluate(token, Query.Send, account, address(0), 0);
    }

    function canReceive(address token, address account) external view returns (bool) {
        return _evaluate(token, Query.Receive, address(0), account, 0);
    }

    function _evaluate(address token, Query query, address from, address to, uint256 amt)
        private view returns (bool)
    {
        uint256 remaining = policy[token];
        while (remaining != 0) {
            uint256 bit = remaining & (~remaining + 1);   // isolate lowest set bit
            uint8 i = _bitIndex(bit);                     // convert bit to rule index (0-255)

            Rule storage rule = ruleByIndex[i];
            if (rule.ruleAddress == address(0)) revert INVALID_RULE();
            if (rule.suspended) return false;
            // The audited code is what's registered; refuse to run anything else
            // (e.g. a metamorphic contract redeployed at the same address).
            if (rule.ruleAddress.codehash != rule.codeHash) revert RULE_CODE_CHANGED(i);

            IRule r = IRule(rule.ruleAddress);
            bytes memory params = ruleParams[token][i].params;
            bool ok = query == Query.Transfer ? r.check(token, from, to, amt, params)
                : query == Query.Send ? r.canSend(token, from, params)
                : r.canReceive(token, to, params);
            if (!ok) return false;
            remaining &= remaining - 1;   // clear lowest set bit, move to the next one
        }
        return true;
    }

    // Decodes a token's policy mask into the rules that are switched on, in
    // the order canTransfer runs them, so callers don't have to read the raw
    // integer.
    function policyRules(address token)
        external view returns (uint8[] memory indices, address[] memory rules)
    {
        uint256 mask = policy[token];
        uint256 count;
        for (uint256 m = mask; m != 0; m &= m - 1) count++;

        indices = new uint8[](count);
        rules = new address[](count);
        for (uint256 n; mask != 0; n++) {
            uint8 i = _bitIndex(mask & (~mask + 1));
            indices[n] = i;
            rules[n] = ruleByIndex[i].ruleAddress;
            mask &= mask - 1;
        }
    }

    function _bitIndex(uint256 bit) internal pure returns (uint8 r) {
        // bit has exactly one bit set, binary-search for its position
        if (bit & type(uint128).max == 0) { bit >>= 128; r += 128; }
        if (bit & type(uint64).max  == 0) { bit >>= 64;  r += 64;  }
        if (bit & type(uint32).max  == 0) { bit >>= 32;  r += 32;  }
        if (bit & type(uint16).max  == 0) { bit >>= 16;  r += 16;  }
        if (bit & type(uint8).max   == 0) { bit >>= 8;   r += 8;   }
        if (bit & 0xf == 0) { bit >>= 4; r += 4; }
        if (bit & 0x3 == 0) { bit >>= 2; r += 2; }
        if (bit & 0x1 == 0) { r += 1; }
    }

    function addRule(address ruleAddress) external onlyRole(COMPLIANCE_AUDITOR) returns (uint8 index) {
        if (ruleAddress.code.length == 0) revert INVALID_RULE();
        if (nextIndex > type(uint8).max) revert RULE_LIMIT();
        index = uint8(nextIndex);
        bytes32 codeHash = ruleAddress.codehash;
        ruleByIndex[index] = Rule(ruleAddress, false, false, codeHash);
        nextIndex++;
        emit RuleAdded(index, ruleAddress, codeHash);
    }

    function deprecateRule(uint8 index) external onlyRole(COMPLIANCE_AUDITOR) {
        if (index >= nextIndex) revert INVALID_RULE();
        ruleByIndex[index].deprecated = true;
        emit RuleDeprecated(index);
    }

    function suspendRule(uint8 index) external onlyRole(COMPLIANCE_AUDITOR) {
        _setSuspended(index, true);
    }

    function unsuspendRule(uint8 index) external onlyRole(COMPLIANCE_AUDITOR) {
        _setSuspended(index, false);
    }

    function _setSuspended(uint8 index, bool suspended) private {
        if (index >= nextIndex) revert INVALID_RULE();
        ruleByIndex[index].suspended = suspended;
        emit RuleSuspended(index, suspended);
    }

    // Switches one rule on for a token, writing its params in the same call so
    // the bit is never live without them.
    function applyRule(address token, uint8 index, bytes calldata params, bytes32 docHash)
        external onlyRole(COMPLIANCE_OFFICER)
    {
        uint256 oldMask = policy[token];
        if (oldMask & (uint256(1) << index) != 0) revert RULE_ALREADY_ON(index);
        uint256 mask = _adopt(token, index, params, docHash, oldMask);
        policy[token] = mask;
        emit PolicyUpdated(token, oldMask, mask);
    }

    // Switches one rule off for a token and deletes its params, so turning it
    // back on later can't pick up stale ones.
    function removeRule(address token, uint8 index) external onlyRole(COMPLIANCE_OFFICER) {
        uint256 oldMask = policy[token];
        uint256 bit = uint256(1) << index;
        if (oldMask & bit == 0) revert RULE_NOT_ON(index);
        delete ruleParams[token][index];
        policy[token] = oldMask & ~bit;
        emit PolicyUpdated(token, oldMask, oldMask & ~bit);
    }

    struct Op { uint8 index; bool adopt; bytes params; bytes32 docHash; }

    // Several switches in one atomic call, e.g. a migration that adopts v2 and
    // drops v1 together. Adopting a rule that's already on re-parameterises it;
    // dropping one that's off is a no-op. expectedMask guards against acting
    // on a policy that changed since the caller read it.
    function setRules(address token, Op[] calldata ops, uint256 expectedMask)
        external onlyRole(COMPLIANCE_OFFICER)
    {
        uint256 oldMask = policy[token];
        if (oldMask != expectedMask) revert STALE_POLICY();   // compare-and-swap
        uint256 mask = oldMask;
        for (uint256 i; i < ops.length; i++) {
            uint8 index = ops[i].index;
            if (ops[i].adopt) {
                mask = _adopt(token, index, ops[i].params, ops[i].docHash, mask);
            } else {
                delete ruleParams[token][index];
                mask &= ~(uint256(1) << index);
            }
        }
        policy[token] = mask;
        emit PolicyUpdated(token, oldMask, mask);
    }

    // Re-parameterises a rule the token already enforces. Allowed even if the
    // rule is deprecated, so officers can still tune it mid-migration.
    function applyPolicyParameters(address token, uint8 index, bytes calldata params, bytes32 docHash)
        external onlyRole(COMPLIANCE_OFFICER)
    {
        if (policy[token] & (uint256(1) << index) == 0) revert RULE_NOT_ON(index);
        _writeParams(token, index, params, docHash);
    }

    // Writes params for `index` and returns `mask` with its bit set. Turning a
    // switch on (bit not yet in `mask`) requires the rule to be adoptable;
    // re-parameterising one that's already on doesn't.
    function _adopt(address token, uint8 index, bytes calldata params, bytes32 docHash, uint256 mask)
        private returns (uint256)
    {
        if (index >= nextIndex) revert INVALID_RULE();
        uint256 bit = uint256(1) << index;
        if (mask & bit == 0) {
            Rule storage rule = ruleByIndex[index];
            if (rule.deprecated || rule.suspended) revert RULE_NOT_ADOPTABLE(index);
        }
        _writeParams(token, index, params, docHash);
        return mask | bit;
    }

    function _writeParams(address token, uint8 index, bytes calldata params, bytes32 docHash) private {
        ruleParams[token][index] = RuleParams(params, docHash);
        emit PolicyParametersApplied(token, index, docHash);
    }
}
