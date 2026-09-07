// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// Minimal view of a Gnosis Safe (Safe{Wallet}), covering only what governance
// needs. Deliberately vendored rather than pulling in safe-contracts as a
// submodule: these four functions are stable across Safe v1.3.x and v1.4.x,
// whereas the full package drags in a second copy of the OZ tree and pins us
// to one Safe release line.
//
// Signature verification is NOT declared here on purpose. Nothing in this repo
// verifies Safe owner signatures itself: a Safe checks them before it will call
// anything, so governance only ever needs to recognise the Safe as the caller.
// That also keeps us clear of `checkSignatures`, which changed shape between
// Safe versions (v1.3/v1.4 take a deprecated `data` argument, v1.5 drops it).
interface ISafe {
    function isOwner(address owner) external view returns (bool);

    function getOwners() external view returns (address[] memory);

    function getThreshold() external view returns (uint256);

    function nonce() external view returns (uint256);
}
