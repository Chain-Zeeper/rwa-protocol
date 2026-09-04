// SPDX-License-Identifier: MIT
import "../token policy/IRule.sol";
import {IComplianceHub} from "../token policy/IComplianceHub.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

struct Rule{
    address ruleAddress;
    bytes32 codeHash;
}
struct RuleParams {
    address token;
    uint8 ruleIndex;
    bytes params;
    bytes32 dochash;
}

error INVALID_RULE();
contract Compliancehub is IComplianceHub, AccessControl {
    event PolicyUpdated(address indexed token, uint256 oldMask, uint256 newMask);

    mapping(uint8 => Rule) public ruleByIndex;
    uint8 public nextIndex;
    mapping(address => uint256) public policy;
    mapping(address => mapping(uint8 => RuleParams)) public ruleParams;

    bytes32 public constant COMPLIANCE_OFFICER = keccak256("COMPLIANCE_OFFICER");
    bytes32 public constant COMPLIANCE_AUDITOR = keccak256("COMPLIANCE_AUDITOR");

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
    
    function canTransfer(address token, address from, address to, uint256 amt)
        external view returns (bool)
    {
        uint256 remaining = policy[token];
        while (remaining != 0) {
            uint256 bit = remaining & (~remaining + 1);   // isolate lowest set bit
            uint8 i = _bitIndex(bit);                       // convert bit to rule index (0-255)

            Rule storage rule = ruleByIndex[i];
            if (rule.ruleAddress == address(0)) revert INVALID_RULE();

            if (!IRule(rule.ruleAddress).check(from, to, amt, ruleParams[token][i].params)) {
                return false;
            }
            remaining &= remaining - 1;   // clear lowest set bit, move to the next one
    }
    return true;
    }
    function _bitIndex(uint256 bit) private pure returns (uint8 r) {
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

    function addRule(address ruleAddress) external onlyRole(COMPLIANCE_AUDITOR) {
        bytes32 codeHash = keccak256(abi.encodePacked(ruleAddress.code));
        ruleByIndex[nextIndex] = Rule(ruleAddress, codeHash);
        nextIndex++;
    }
    
    function setPolicy(address token, uint256 mask) external onlyRole(COMPLIANCE_AUDITOR) {
        policy[token] = mask;
    }
    function applyPolicyParameters(address token, uint8 index, bytes calldata params, bytes32 docHash) onlyRole(COMPLIANCE_OFFICER) external {
        _applyPolicyParameters(token, index, params, docHash);      
    }

    function _applyPolicyParameters(address token, uint8 index, bytes calldata params, bytes32 docHash) internal {
        if(index >= nextIndex) revert INVALID_RULE();
        ruleParams[token][index] = RuleParams(token, index, params, docHash);        
    }

    struct Op { uint8 index; bool adopt; bytes params; bytes32 docHash; }

    function applyPolicyBatch(address token, Op[] calldata ops, uint256 expectedMask) external {
        require(policy[token] == expectedMask, "STALE_POLICY");   // compare-and-swap
        uint256 oldMask = policy[token];
        for (uint i; i < ops.length; i++) {
            if (ops[i].adopt) {
                _applyPolicyParameters(token, ops[i].index, ops[i].params, ops[i].docHash);
            } else {
                delete ruleParams[token][ops[i].index];
            }
        }
        emit PolicyUpdated(token, oldMask, policy[token]);
    }



}