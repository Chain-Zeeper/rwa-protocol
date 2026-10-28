// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {
    ComplianceHub,
    INVALID_RULE,
    RULE_CODE_CHANGED,
    RULE_LIMIT,
    RULE_NOT_ADOPTABLE,
    RULE_ALREADY_ON,
    RULE_NOT_ON,
    STALE_POLICY
} from "../src/compliance/ComplianceHub.sol";
import {IRule} from "../src/compliance/IRule.sol";
import {MaxTransferable} from "../src/compliance/rules/MaxTransferable.sol";

// Exposes the internal bit-position search for direct fuzzing.
contract ComplianceHubHarness is ComplianceHub {
    function bitIndex(uint256 bit) external pure returns (uint8) {
        return _bitIndex(bit);
    }
}

// Passes unless the token's params for this index decode to `false`, so one
// deployment registered at every index lets a test pick exactly which rules fail.
contract ParamRule is IRule {
    function check(address, address, address, uint256, bytes memory params) external pure returns (bool) {
        return _pass(params);
    }
    function canSend(address, address, bytes memory params) external pure returns (bool) { return _pass(params); }
    function canReceive(address, address, bytes memory params) external pure returns (bool) { return _pass(params); }
    function _pass(bytes memory params) private pure returns (bool) {
        return params.length == 0 || abi.decode(params, (bool));
    }
    function name() external pure returns (string memory) { return "ParamRule"; }
    function ruleReference() external pure returns (string memory) { return "ParamRule"; }
}

// Passes only for the token address it was given in params, to prove the hub
// forwards the token being transferred.
contract TokenEchoRule is IRule {
    function check(address token, address, address, uint256, bytes memory params) external pure returns (bool) {
        return token == abi.decode(params, (address));
    }
    function canSend(address, address, bytes memory) external pure returns (bool) { return true; }
    function canReceive(address, address, bytes memory) external pure returns (bool) { return true; }
    function name() external pure returns (string memory) { return "TokenEchoRule"; }
    function ruleReference() external pure returns (string memory) { return "TokenEchoRule"; }
}

contract ComplianceHubTest is Test {
    ComplianceHubHarness hub;
    ParamRule paramRule;

    address auditor = makeAddr("auditor");
    address officer = makeAddr("officer");
    address outsider = makeAddr("outsider");
    address token = makeAddr("token");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        hub = new ComplianceHubHarness();
        hub.grantRole(hub.COMPLIANCE_AUDITOR(), auditor);
        hub.grantRole(hub.COMPLIANCE_OFFICER(), officer);
        paramRule = new ParamRule();
    }

    function _registerParamRule(uint256 count) internal {
        vm.startPrank(auditor);
        for (uint256 i; i < count; i++) hub.addRule(address(paramRule));
        vm.stopPrank();
    }

    function _apply(uint8 index, bytes memory params) internal {
        vm.prank(officer);
        hub.applyRule(token, index, params, keccak256(params));
    }

    function _op(uint8 index, bool adopt, bytes memory params) internal pure returns (ComplianceHub.Op[] memory ops) {
        ops = new ComplianceHub.Op[](1);
        ops[0] = ComplianceHub.Op(index, adopt, params, keccak256(params));
    }

    // Adopt ops for every rule in `mask`, in one setRules call; rules also in
    // failMask get abi.encode(false).
    function _setMask(uint256 mask, uint256 failMask) internal {
        uint256 count;
        for (uint256 m = mask; m != 0; m &= m - 1) count++;
        ComplianceHub.Op[] memory ops = new ComplianceHub.Op[](count);
        uint256 n;
        for (uint256 i; i < 256; i++) {
            uint256 bit = uint256(1) << i;
            if (mask & bit == 0) continue;
            bytes memory p = failMask & bit != 0 ? abi.encode(false) : bytes("");
            ops[n++] = ComplianceHub.Op(uint8(i), true, p, keccak256(p));
        }
        uint256 expected = hub.policy(token);
        vm.prank(officer);
        hub.setRules(token, ops, expected);
    }

    // ---------------------------------------------------------------- bit index

    function testFuzz_bitIndexMatchesShift(uint8 pos) public view {
        assertEq(hub.bitIndex(uint256(1) << pos), pos);
    }

    function test_bitIndexEdges() public view {
        assertEq(hub.bitIndex(1), 0);
        assertEq(hub.bitIndex(uint256(1) << 255), 255);
    }

    // ------------------------------------------------------------- canTransfer

    function test_emptyPolicyAllows() public view {
        assertTrue(hub.canTransfer(token, alice, bob, 1));
    }

    // canTransfer must visit every set bit and nothing else: it fails iff some
    // enforced rule is configured to fail.
    function testFuzz_canTransferMatchesReference(uint256 mask, uint256 failMask) public {
        _registerParamRule(256);
        _setMask(mask, failMask);
        assertEq(hub.policy(token), mask);
        assertEq(hub.canTransfer(token, alice, bob, 1), mask & failMask == 0);
    }

    // canSend / canReceive walk the same rules: they fail iff some enforced
    // rule is configured to fail.
    function testFuzz_canSendReceiveMatchReference(uint256 mask, uint256 failMask) public {
        _registerParamRule(256);
        _setMask(mask, failMask);
        assertEq(hub.canSend(token, alice), mask & failMask == 0);
        assertEq(hub.canReceive(token, alice), mask & failMask == 0);
    }

    function test_suspendedRuleFailsSendAndReceive() public {
        _registerParamRule(1);
        _apply(0, "");
        vm.prank(auditor);
        hub.suspendRule(0);
        assertFalse(hub.canSend(token, alice));
        assertFalse(hub.canReceive(token, alice));
    }

    function test_maxTransferableEndToEnd() public {
        MaxTransferable maxRule = new MaxTransferable();
        vm.prank(auditor);
        uint8 idx = hub.addRule(address(maxRule));
        _apply(idx, abi.encode(uint256(100)));

        assertTrue(hub.canTransfer(token, alice, bob, 100));
        assertFalse(hub.canTransfer(token, alice, bob, 101));
    }

    function test_ruleReceivesToken() public {
        TokenEchoRule echo = new TokenEchoRule();
        vm.prank(auditor);
        uint8 idx = hub.addRule(address(echo));
        address otherToken = makeAddr("otherToken");

        vm.startPrank(officer);
        hub.applyRule(token, idx, abi.encode(token), 0);
        // Same params on another token: the rule sees otherToken, not `token`.
        hub.applyRule(otherToken, idx, abi.encode(token), 0);
        vm.stopPrank();

        assertTrue(hub.canTransfer(token, alice, bob, 1));
        assertFalse(hub.canTransfer(otherToken, alice, bob, 1));
    }

    function test_changedRuleCodeReverts() public {
        _registerParamRule(1);
        _apply(0, "");

        vm.etch(address(paramRule), address(new MaxTransferable()).code);
        vm.expectRevert(abi.encodeWithSelector(RULE_CODE_CHANGED.selector, uint8(0)));
        hub.canTransfer(token, alice, bob, 1);
    }

    // ------------------------------------------------------------- policyRules

    function test_policyRulesEmpty() public view {
        (uint8[] memory indices, address[] memory rules) = hub.policyRules(token);
        assertEq(indices.length, 0);
        assertEq(rules.length, 0);
    }

    function test_policyRulesListsSwitchedOnRules() public {
        _registerParamRule(4);
        _setMask((1 << 1) | (1 << 3), 0);

        (uint8[] memory indices, address[] memory rules) = hub.policyRules(token);
        assertEq(indices.length, 2);
        assertEq(indices[0], 1);
        assertEq(indices[1], 3);
        assertEq(rules[0], address(paramRule));
        assertEq(rules[1], address(paramRule));
    }

    function testFuzz_policyRulesRoundTrips(uint256 mask) public {
        _registerParamRule(256);
        _setMask(mask, 0);

        (uint8[] memory indices,) = hub.policyRules(token);
        uint256 rebuilt;
        for (uint256 n; n < indices.length; n++) {
            if (n > 0) assertGt(indices[n], indices[n - 1]);   // ascending = execution order
            rebuilt |= uint256(1) << indices[n];
        }
        assertEq(rebuilt, mask);
    }

    // ---------------------------------------------------------------- applyRule

    function test_applyRuleSetsBitAndParams() public {
        _registerParamRule(4);
        bytes memory params = abi.encode(true);

        vm.expectEmit(address(hub));
        emit ComplianceHub.PolicyUpdated(token, 0, 1 << 2);
        _apply(2, params);

        assertEq(hub.policy(token), 1 << 2);
        (bytes memory stored, bytes32 docHash) = hub.ruleParams(token, 2);
        assertEq(stored, params);
        assertEq(docHash, keccak256(params));
    }

    function test_applyRuleKeepsOtherRules() public {
        _registerParamRule(3);
        _apply(0, abi.encode(false));
        _apply(2, "");

        assertEq(hub.policy(token), (1 << 0) | (1 << 2));
        (bytes memory stored,) = hub.ruleParams(token, 0);
        assertEq(stored, abi.encode(false));
    }

    function test_applyRuleAlreadyOnReverts() public {
        _registerParamRule(1);
        _apply(0, "");
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(RULE_ALREADY_ON.selector, uint8(0)));
        hub.applyRule(token, 0, "", 0);
    }

    function test_applyRuleUnregisteredReverts() public {
        _registerParamRule(1);
        vm.prank(officer);
        vm.expectRevert(INVALID_RULE.selector);
        hub.applyRule(token, 1, "", 0);
    }

    function test_applyRuleOnlyOfficer() public {
        _registerParamRule(1);
        bytes32 role = hub.COMPLIANCE_OFFICER();
        vm.prank(auditor);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, auditor, role));
        hub.applyRule(token, 0, "", 0);
    }

    // --------------------------------------------------------------- removeRule

    function test_removeRuleClearsBitAndParams() public {
        _registerParamRule(4);
        _apply(1, "");
        _apply(2, abi.encode(false));
        assertFalse(hub.canTransfer(token, alice, bob, 1));

        vm.expectEmit(address(hub));
        emit ComplianceHub.PolicyUpdated(token, (1 << 1) | (1 << 2), 1 << 1);
        vm.prank(officer);
        hub.removeRule(token, 2);

        assertEq(hub.policy(token), 1 << 1);
        (bytes memory stored, bytes32 docHash) = hub.ruleParams(token, 2);
        assertEq(stored.length, 0);
        assertEq(docHash, 0);
        assertTrue(hub.canTransfer(token, alice, bob, 1));
    }

    function test_reApplyAfterRemoveTakesNewParams() public {
        _registerParamRule(1);
        _apply(0, abi.encode(false));
        vm.prank(officer);
        hub.removeRule(token, 0);
        _apply(0, "");
        assertTrue(hub.canTransfer(token, alice, bob, 1));
    }

    function test_removeRuleNotOnReverts() public {
        _registerParamRule(1);
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(RULE_NOT_ON.selector, uint8(0)));
        hub.removeRule(token, 0);
    }

    function test_removeRuleOnlyOfficer() public {
        _registerParamRule(1);
        _apply(0, "");
        bytes32 role = hub.COMPLIANCE_OFFICER();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role));
        hub.removeRule(token, 0);
    }

    // ----------------------------------------------------------------- setRules

    function test_setRulesAll256() public {
        _registerParamRule(256);
        _setMask(type(uint256).max, 0);
        assertEq(hub.policy(token), type(uint256).max);
        assertTrue(hub.canTransfer(token, alice, bob, 1));
    }

    function test_setRulesAdoptAndDropTogether() public {
        _registerParamRule(3);
        _apply(0, abi.encode(false));

        ComplianceHub.Op[] memory ops = new ComplianceHub.Op[](2);
        ops[0] = ComplianceHub.Op(2, true, abi.encode(true), keccak256("doc"));
        ops[1] = ComplianceHub.Op(0, false, "", 0);
        vm.expectEmit(address(hub));
        emit ComplianceHub.PolicyUpdated(token, 1 << 0, 1 << 2);
        vm.prank(officer);
        hub.setRules(token, ops, 1 << 0);

        assertEq(hub.policy(token), 1 << 2);
        (bytes memory dropped,) = hub.ruleParams(token, 0);
        assertEq(dropped.length, 0);
        (, bytes32 docHash) = hub.ruleParams(token, 2);
        assertEq(docHash, keccak256("doc"));
        assertTrue(hub.canTransfer(token, alice, bob, 1));
    }

    function test_setRulesReAdoptReparameterises() public {
        _registerParamRule(1);
        _apply(0, "");
        vm.prank(officer);
        hub.setRules(token, _op(0, true, abi.encode(false)), 1 << 0);
        assertEq(hub.policy(token), 1 << 0);
        assertFalse(hub.canTransfer(token, alice, bob, 1));
    }

    function test_setRulesDropOffRuleIsNoop() public {
        _registerParamRule(2);
        _apply(0, "");
        vm.prank(officer);
        hub.setRules(token, _op(1, false, ""), 1 << 0);
        assertEq(hub.policy(token), 1 << 0);
    }

    function test_setRulesStaleMaskReverts() public {
        _registerParamRule(1);
        ComplianceHub.Op[] memory ops = _op(0, true, "");
        vm.prank(officer);
        vm.expectRevert(STALE_POLICY.selector);
        hub.setRules(token, ops, 1);
    }

    function test_setRulesAdoptUnregisteredReverts() public {
        _registerParamRule(1);
        ComplianceHub.Op[] memory ops = _op(1, true, "");
        vm.prank(officer);
        vm.expectRevert(INVALID_RULE.selector);
        hub.setRules(token, ops, 0);
    }

    function test_setRulesOnlyOfficer() public {
        _registerParamRule(1);
        ComplianceHub.Op[] memory ops = _op(0, true, "");
        bytes32 role = hub.COMPLIANCE_OFFICER();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role));
        hub.setRules(token, ops, 0);
    }

    // ---------------------------------------------------- applyPolicyParameters

    function test_applyParamsUpdatesOnRule() public {
        _registerParamRule(1);
        _apply(0, "");
        vm.prank(officer);
        hub.applyPolicyParameters(token, 0, abi.encode(false), keccak256("v2"));

        (, bytes32 docHash) = hub.ruleParams(token, 0);
        assertEq(docHash, keccak256("v2"));
        assertFalse(hub.canTransfer(token, alice, bob, 1));
    }

    function test_applyParamsNotOnReverts() public {
        _registerParamRule(1);
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(RULE_NOT_ON.selector, uint8(0)));
        hub.applyPolicyParameters(token, 0, "", 0);
    }

    // ------------------------------------------------------- deprecate/suspend

    function test_deprecatedRuleBlocksNewAdoption() public {
        _registerParamRule(2);
        vm.prank(auditor);
        hub.deprecateRule(1);

        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(RULE_NOT_ADOPTABLE.selector, uint8(1)));
        hub.applyRule(token, 1, "", 0);

        ComplianceHub.Op[] memory ops = _op(1, true, "");
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(RULE_NOT_ADOPTABLE.selector, uint8(1)));
        hub.setRules(token, ops, 0);
    }

    function test_deprecatedRuleKeepsRunningForExistingTokens() public {
        _registerParamRule(2);
        _apply(1, abi.encode(true));
        vm.prank(auditor);
        hub.deprecateRule(1);

        // Still enforced, and the officer can still re-parameterise it.
        vm.startPrank(officer);
        hub.applyPolicyParameters(token, 1, abi.encode(false), 0);
        assertFalse(hub.canTransfer(token, alice, bob, 1));

        // Migration in one atomic call: adopt the replacement, drop the old rule.
        ComplianceHub.Op[] memory ops = new ComplianceHub.Op[](2);
        ops[0] = ComplianceHub.Op(0, true, "", 0);
        ops[1] = ComplianceHub.Op(1, false, "", 0);
        hub.setRules(token, ops, 1 << 1);
        vm.stopPrank();

        assertEq(hub.policy(token), 1 << 0);
        assertTrue(hub.canTransfer(token, alice, bob, 1));
    }

    // Dropping a deprecated rule and adopting it again in the same batch counts
    // as a new adoption, so it's blocked rather than slipping through.
    function test_setRulesDropThenReAdoptDeprecatedReverts() public {
        _registerParamRule(1);
        _apply(0, "");
        vm.prank(auditor);
        hub.deprecateRule(0);

        ComplianceHub.Op[] memory ops = new ComplianceHub.Op[](2);
        ops[0] = ComplianceHub.Op(0, false, "", 0);
        ops[1] = ComplianceHub.Op(0, true, "", 0);
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(RULE_NOT_ADOPTABLE.selector, uint8(0)));
        hub.setRules(token, ops, 1 << 0);
    }

    function test_suspendFailsClosedThenRecovers() public {
        _registerParamRule(2);
        address otherToken = makeAddr("otherToken");
        vm.startPrank(officer);
        hub.applyRule(token, 1, "", 0);
        hub.applyRule(otherToken, 0, "", 0);
        vm.stopPrank();

        vm.prank(auditor);
        hub.suspendRule(1);
        assertFalse(hub.canTransfer(token, alice, bob, 1));
        assertTrue(hub.canTransfer(otherToken, alice, bob, 1));   // doesn't enforce rule 1

        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(RULE_NOT_ADOPTABLE.selector, uint8(1)));
        hub.applyRule(otherToken, 1, "", 0);

        vm.prank(auditor);
        hub.unsuspendRule(1);
        assertTrue(hub.canTransfer(token, alice, bob, 1));
    }

    function test_suspendOnlyAuditor() public {
        _registerParamRule(1);
        bytes32 role = hub.COMPLIANCE_AUDITOR();
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, officer, role));
        hub.suspendRule(0);
    }

    function test_deprecateOnlyAuditor() public {
        _registerParamRule(1);
        bytes32 role = hub.COMPLIANCE_AUDITOR();
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, officer, role));
        hub.deprecateRule(0);
    }

    function test_deprecateAndSuspendRejectUnregistered() public {
        vm.prank(auditor);
        vm.expectRevert(INVALID_RULE.selector);
        hub.deprecateRule(0);
        vm.prank(auditor);
        vm.expectRevert(INVALID_RULE.selector);
        hub.suspendRule(0);
    }

    // ------------------------------------------------------------------ addRule

    function test_addRuleRejectsNonContract() public {
        vm.prank(auditor);
        vm.expectRevert(INVALID_RULE.selector);
        hub.addRule(alice);
    }

    function test_addRuleAllows256ThenLimits() public {
        _registerParamRule(256);
        assertEq(hub.nextIndex(), 256);
        (address ruleAddr,,,) = hub.ruleByIndex(255);
        assertEq(ruleAddr, address(paramRule));

        vm.prank(auditor);
        vm.expectRevert(RULE_LIMIT.selector);
        hub.addRule(address(paramRule));
    }

    function test_addRuleOnlyAuditor() public {
        bytes32 role = hub.COMPLIANCE_AUDITOR();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role));
        hub.addRule(address(paramRule));
    }
}
