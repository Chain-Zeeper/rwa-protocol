// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {NdiOnChainAcc} from "./NdiOnChainAcc.sol";

// ERC-4337 account factory: CREATE2 EIP-1167 clones of NdiOnChainAcc.
//
// The address is derived from (qx, qy, guardian, salt), so it can be computed
// off-chain before deployment and funds can be sent to it first. The account
// is then deployed lazily by the first UserOperation's initCode
// (factory = this, factoryData = createAccount(...)).
//
// Because the initialization params are part of the salt, nobody can front-run
// the deployment with a different key: a different key means a different address.
contract NdiOnChainAccFactory {
    address public immutable accountImplementation;

    event AccountCreated(address indexed account, bytes32 qx, bytes32 qy, address guardian);

    constructor(address accountImplementation_) {
        require(accountImplementation_ != address(0), "zero impl");
        accountImplementation = accountImplementation_;
    }

    // Idempotent: returns the existing account if already deployed, as the
    // entry point / bundlers expect from a factory.
    function createAccount(bytes32 qx, bytes32 qy, address guardian, uint256 salt) external returns (address account) {
        bytes32 fullSalt = _salt(qx, qy, guardian, salt);
        account = Clones.predictDeterministicAddress(accountImplementation, fullSalt);
        if (account.code.length != 0) return account;

        Clones.cloneDeterministic(accountImplementation, fullSalt);
        NdiOnChainAcc(payable(account)).initialize(qx, qy, guardian);
        emit AccountCreated(account, qx, qy, guardian);
    }

    function predictAddress(bytes32 qx, bytes32 qy, address guardian, uint256 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(accountImplementation, _salt(qx, qy, guardian, salt));
    }

    function _salt(bytes32 qx, bytes32 qy, address guardian, uint256 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(qx, qy, guardian, salt));
    }
}
