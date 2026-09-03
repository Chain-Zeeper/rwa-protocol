import {IRule} from "../../token policy/IRule.sol";

contract MaxTransferable is IRule {

    function check(address _from, address _to, uint256 _amount, bytes memory params) external pure returns (bool) {
        uint256 maxAmount = abi.decode(params, (uint256));
        return _amount <= maxAmount;
    }
    function name() external pure returns (string memory) {
        return "MaxTransferable";
    }
    function ruleReference() external pure returns (string memory) {
        return "MaxTransferable";
    }
}
