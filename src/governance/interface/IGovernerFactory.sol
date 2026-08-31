// SPDX-License-Identifier: MIT 

pragma solidity ^0.8.13;
struct governance {
    string name;
    uint256 version;
    address impl;

}

interface IGovernerFactory {
    function registerGovernance( uint256 version, address impl) external;
    function deployGovernance(string memory name, uint256 version, address impl,bytes memory params) external;
}
