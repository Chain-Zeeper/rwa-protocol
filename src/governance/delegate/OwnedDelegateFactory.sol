// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {OwnedDelegate} from "./OwnedDelegate.sol";

// EIP-1167 clone factory giving every approver one canonical delegate adapter.
//
// The clone is deterministic in the approver's address, so `delegateFor(a)`
// answers "which address does a hub register as the delegate?" before the
// adapter exists -- a governance proposal can wire the delegation and deploy
// the adapter in either order, and two hubs delegating to the same approver
// land on the same adapter rather than each standing up their own.
contract OwnedDelegateFactory {
    address public immutable implementation;

    event OwnedDelegateDeployed(address indexed approver, address indexed delegate);

    constructor(address _implementation) {
        require(_implementation != address(0), "zero implementation");
        implementation = _implementation;
    }

    function deploy(address approver) external returns (address delegate) {
        delegate = Clones.cloneDeterministic(implementation, _salt(approver));
        OwnedDelegate(delegate).initialize(approver);
        emit OwnedDelegateDeployed(approver, delegate);
    }

    // the adapter's address whether or not it has been deployed yet
    function delegateFor(address approver) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(approver), address(this));
    }

    function isDeployed(address approver) external view returns (bool) {
        return delegateFor(approver).code.length > 0;
    }

    function _salt(address approver) private pure returns (bytes32) {
        return keccak256(abi.encode(approver));
    }
}
