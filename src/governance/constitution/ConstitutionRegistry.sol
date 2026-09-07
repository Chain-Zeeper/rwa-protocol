// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IConstitutionRegistry} from "./interface/IConstitutionRegistry.sol";

// Registry + EIP-1167 clone factory for IConstitution implementations.
// Registration is owner-gated; deploying from a registered template is open.
contract ConstitutionRegistry is IConstitutionRegistry, Ownable {
    mapping(uint256 => address) public constitutionImpl;
    mapping(uint256 => bool) public deprecated;

    constructor(address owner) Ownable(owner) {}

    function registerConstitution(uint256 version, address impl) external onlyOwner {
        require(impl != address(0), "zero impl");
        require(constitutionImpl[version] == address(0), "version already registered");
        constitutionImpl[version] = impl;
        emit ConstitutionRegistered(version, impl);
    }

    // Gates new clones only; existing ones keep running, since a clone's
    // implementation address is baked into its bytecode. Reversible.
    function setDeprecated(uint256 version, bool _deprecated) external onlyOwner {
        require(constitutionImpl[version] != address(0), "unknown constitution version");
        deprecated[version] = _deprecated;
        emit ConstitutionDeprecationSet(version, _deprecated);
    }

    // initData is mandatory: an uninitialized clone can be claimed by anyone.
    // The initializer runs with this registry as msg.sender, so a constitution
    // must take its owner as a parameter rather than reading msg.sender.
    function deployConstitution(uint256 version, bytes calldata initData) external returns (address instance) {
        address impl = constitutionImpl[version];
        require(impl != address(0), "unknown constitution version");
        require(!deprecated[version], "constitution version deprecated");
        require(initData.length >= 4, "init data required");

        instance = Clones.clone(impl);
        (bool success, bytes memory returndata) = instance.call(initData);
        if (!success) {
            if (returndata.length > 0) {
                assembly {
                    let size := mload(returndata)
                    revert(add(returndata, 0x20), size)
                }
            } else {
                revert("ConstitutionRegistry: init reverted without reason");
            }
        }
        emit ConstitutionDeployed(version, impl, instance);
    }
}
