// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IGovernerFactory} from "./interface/IGovernerFactory.sol";
import {IConstitutionRegistry} from "./constitution/interface/IConstitutionRegistry.sol";
import {Governor, DelegateRegistration, VotingParametersRegistration} from "./Governer.sol";

// Registry + EIP-1167 clone factory for Governor implementations. Deploys a
// governor and its constitution together, wiring the fresh constitution into
// the clone's initializer. Governors are identified by address; names are
// off-chain.
contract GovernerFactory is IGovernerFactory, Ownable {
    IConstitutionRegistry public immutable constitutionRegistry;

    mapping(uint256 => address) public governanceImpl;
    mapping(uint256 => bool) public deprecated;

    constructor(address owner, address _constitutionRegistry) Ownable(owner) {
        require(_constitutionRegistry != address(0), "zero constitution registry");
        constitutionRegistry = IConstitutionRegistry(_constitutionRegistry);
    }

    function registerGovernance(uint256 version, address impl) external onlyOwner {
        require(impl != address(0), "zero impl");
        require(governanceImpl[version] == address(0), "version already registered");
        governanceImpl[version] = impl;
        emit GovernanceRegistered(version, impl);
    }

    // Gates new clones only; existing governors keep running, since a clone's
    // implementation address is baked into its bytecode. Reversible.
    function setDeprecated(uint256 version, bool _deprecated) external onlyOwner {
        require(governanceImpl[version] != address(0), "unknown governance version");
        deprecated[version] = _deprecated;
        emit GovernanceDeprecationSet(version, _deprecated);
    }

    function deployGovernance(
        uint256 version,
        uint256 constitutionVersion,
        bytes memory constitutionInitData,
        DelegateRegistration[] memory delegateRegistrations,
        VotingParametersRegistration[] memory votingParameterRegistrations
    ) external returns (address governor, address constitution) {
        address impl = governanceImpl[version];
        require(impl != address(0), "unknown governance version");
        require(!deprecated[version], "governance version deprecated");

        constitution = constitutionRegistry.deployConstitution(constitutionVersion, constitutionInitData);

        governor = Clones.clone(impl);
        Governor(payable(governor)).initialize(constitution, delegateRegistrations, votingParameterRegistrations);

        emit GovernanceDeployed(version, governor, constitution);
    }
}
