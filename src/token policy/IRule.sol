// SPDX-License-Identifier: MIT 

interface IRule {
    function check(address _from, address _to, uint256 _amount, bytes memory params) external view returns (bool);
    function name() external view returns (string memory);
    function ruleReference() external view returns (string memory);
}