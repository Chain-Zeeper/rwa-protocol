// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MaxTransferable} from "../src/compliance/rules/MaxTransferable.sol";

contract MaxTransferableTest is Test {
    MaxTransferable rule;

    function setUp() public {
        rule = new MaxTransferable();
    }

    function testFuzz_allowsExactlyUpToTheCap(uint256 cap, uint256 amount) public view {
        assertEq(rule.check(address(1), address(2), address(3), amount, abi.encode(cap)), amount <= cap);
    }

    // The cap applies to every movement the hub checks, mints and burns included.
    function test_capAppliesToMintsAndBurns() public view {
        bytes memory params = abi.encode(uint256(50));
        assertFalse(rule.check(address(1), address(0), address(3), 51, params));
        assertFalse(rule.check(address(1), address(2), address(0), 51, params));
    }

    function test_RevertWhen_ParamsAreMissing() public {
        vm.expectRevert(bytes(""));   // abi.decode of empty bytes reverts with no data
        rule.check(address(1), address(2), address(3), 1, "");
    }

    function test_metadata() public view {
        assertEq(rule.name(), "MaxTransferable");
        assertEq(rule.ruleReference(), "MaxTransferable");
    }
}
