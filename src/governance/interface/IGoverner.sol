interface IGovernor{
    function registerVotingStyle(address _votingStyle, bytes4 selector) external;
    function propose(address[] memory targets, uint256 value, string memory signature, bytes memory data) external returns (uint256);
}