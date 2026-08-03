interface IRule {
    function validate(address _from, address _to, uint256 _amount) external view returns (bool);
}