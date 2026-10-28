// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DelegateRegistration, VotingParametersRegistration} from "./Governor.sol";

interface IGovernerFactory {
    event GovernanceRegistered(uint256 indexed version, address impl);
    event GovernanceDeprecationSet(uint256 indexed version, bool deprecated);
    event GovernanceDeployed(uint256 indexed version, address indexed governor, address constitution);

    function registerGovernance(uint256 version, address impl) external;

    // blocks new deployments only; existing clones are unaffected
    function setDeprecated(uint256 version, bool deprecated) external;

    // deploys the constitution and the governor clone atomically, so neither
    // can be left pointing at one that doesn't exist
    function deployGovernance(
        uint256 version,
        uint256 constitutionVersion,
        bytes memory constitutionInitData,
        DelegateRegistration[] memory delegateRegistrations,
        VotingParametersRegistration[] memory votingParameterRegistrations,
        bytes32 salt
    ) external returns (address governor, address constitution);

    // where deployGovernance puts the governor for this deployer and salt
    function predictGovernor(address deployer, uint256 version, bytes32 salt) external view returns (address);
}
