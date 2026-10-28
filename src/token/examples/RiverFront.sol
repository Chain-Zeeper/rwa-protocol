// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IComplianceHub} from "../../compliance/IComplianceHub.sol";
import {RWA} from "../RWA.sol";

// Example project token: an initial supply minted to the project treasury at
// deploy, with further issuance and redemption by role. One role per
// privileged action, as in the ERC-7943 reference implementation. The admin
// starts with every role and can hand freezing and forced transfers to a
// transfer agent later without redeploying. Enumerable so who holds each role
// can be read straight off the contract.
contract RiverFront is RWA, AccessControlEnumerable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");
    bytes32 public constant FORCE_TRANSFER_ROLE = keccak256("FORCE_TRANSFER_ROLE");

    // The initial mint goes through the hub, but the token has no policy yet
    // (its address isn't known until now), so it isn't checked against KYC.
    // Make sure `treasury` is KYC'd before the policy is applied, or it won't
    // be able to send.
    constructor(IComplianceHub _complianceHub, address admin, address treasury, uint256 initialSupply)
        RWA("RiverFront", "RIVER", _complianceHub)
    {
        require(admin != address(0), "zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(BURNER_ROLE, admin);
        _grantRole(FREEZER_ROLE, admin);
        _grantRole(FORCE_TRANSFER_ROLE, admin);
        _mint(treasury, initialSupply);
    }

    // Recipient must pass canReceive and the token's transfer rules.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    // Redemption: works even if the holder can't send, and consumes frozen
    // tokens if it has to.
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    function _checkFreezer(address, uint256) internal view override {
        _checkRole(FREEZER_ROLE);
    }

    function _checkEnforcer(address, address, uint256) internal view override {
        _checkRole(FORCE_TRANSFER_ROLE);
    }

    function supportsInterface(bytes4 interfaceId)
        public view override(RWA, AccessControlEnumerable) returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
