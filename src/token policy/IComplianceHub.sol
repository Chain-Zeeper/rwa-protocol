interface IComplianceHub {
    function canTransfer(address token, address from, address to, uint256 amount) external view returns (bool);
}