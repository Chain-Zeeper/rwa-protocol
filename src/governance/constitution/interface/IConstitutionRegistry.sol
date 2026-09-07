// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IConstitutionRegistry {
    event ConstitutionRegistered(uint256 indexed version, address impl);
    event ConstitutionDeprecationSet(uint256 indexed version, bool deprecated);
    event ConstitutionDeployed(uint256 indexed version, address impl, address instance);

    function registerConstitution(uint256 version, address impl) external;

    // blocks new clones only; existing constitutions are unaffected
    function setDeprecated(uint256 version, bool deprecated) external;

    function constitutionImpl(uint256 version) external view returns (address);
    function deprecated(uint256 version) external view returns (bool);

    function deployConstitution(uint256 version, bytes calldata initData) external returns (address instance);
}
