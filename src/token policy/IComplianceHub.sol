interface IComplianceHub {
    function isCompliant(address _from, address _to, uint256 _amount) external view returns (bool);
}