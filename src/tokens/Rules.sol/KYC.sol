import {IRule} from "../../token policy/IRule.sol";

struct attester {
    address attester;
    bytes32 docHash;
}

contract KYC is IRule {

    mapping(address=>bytes32) public attestation;
    function check(address _from, address _to, uint256 _amount,bytes memory params) external view returns (bool) {
        /// call attestations on address of from and to 
        return true;
    }
    function name() external pure returns (string memory) {
        return "KYC";
    }
    function ruleReference() external pure returns (string memory) {
        return "KYC";
    }
}