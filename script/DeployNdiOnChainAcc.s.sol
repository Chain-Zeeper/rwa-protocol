// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IEntryPoint} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/ERC4337Utils.sol";

import {NdiOnChainAcc} from "../src/account/NdiOnChainAcc.sol";
import {NdiOnChainAccFactory} from "../src/account/NdiOnChainAccFactory.sol";

// Deploys the NdiOnChainAcc implementation and its factory through the
// canonical CREATE2 deployer (0x4e59...956C). Addresses depend only on the
// bytecode, ENTRY_POINT and SALT, never on the deployer key or nonce, so the
// same settings produce the same addresses on Chiado and Gnosis mainnet, and
// therefore the same predicted account address for a given phone key.
//
// Idempotent: anything already at the predicted address is reused.
//
// Env:
//   ENTRY_POINT  ERC-4337 EntryPoint the accounts trust (default v0.8). Must be
//                one your bundler/paymaster provider supports on the chain.
//                Changing it changes every address.
//   SALT         CREATE2 salt (default keccak256("ndi.onchainacc.v1")).
//
// Dry run:  forge script script/DeployNdiOnChainAcc.s.sol --rpc-url chiado
// Deploy:   forge script script/DeployNdiOnChainAcc.s.sol --rpc-url chiado \
//             --account deployer --broadcast \
//             --verify --verifier blockscout --verifier-url https://gnosis-chiado.blockscout.com/api/
contract DeployNdiOnChainAcc is Script {
    uint256 constant GNOSIS = 100;
    uint256 constant CHIADO = 10200;
    uint256 constant ANVIL = 31337;

    function run() external returns (NdiOnChainAcc impl, NdiOnChainAccFactory factory) {
        require(block.chainid == GNOSIS || block.chainid == CHIADO || block.chainid == ANVIL, "unsupported chain");

        IEntryPoint entryPoint = IEntryPoint(vm.envOr("ENTRY_POINT", address(ERC4337Utils.ENTRYPOINT_V08)));
        bytes32 salt = vm.envOr("SALT", keccak256("ndi.onchainacc.v1"));
        require(address(entryPoint).code.length != 0, "no EntryPoint at ENTRY_POINT on this chain");

        address implAddr = vm.computeCreate2Address(
            salt, keccak256(abi.encodePacked(type(NdiOnChainAcc).creationCode, abi.encode(entryPoint)))
        );
        address factoryAddr = vm.computeCreate2Address(
            salt, keccak256(abi.encodePacked(type(NdiOnChainAccFactory).creationCode, abi.encode(implAddr)))
        );

        vm.startBroadcast();
        impl = implAddr.code.length == 0 ? new NdiOnChainAcc{salt: salt}(entryPoint) : NdiOnChainAcc(payable(implAddr));
        factory = factoryAddr.code.length == 0
            ? new NdiOnChainAccFactory{salt: salt}(implAddr)
            : NdiOnChainAccFactory(factoryAddr);
        vm.stopBroadcast();

        require(address(impl) == implAddr, "impl address mismatch");
        require(address(factory) == factoryAddr, "factory address mismatch");
        require(address(impl.entryPoint()) == address(entryPoint), "impl entry point mismatch");
        require(factory.accountImplementation() == implAddr, "factory impl mismatch");

        console.log("chain id      ", block.chainid);
        console.log("entry point   ", address(entryPoint));
        console.log("implementation", implAddr);
        console.log("factory       ", factoryAddr);
    }
}
