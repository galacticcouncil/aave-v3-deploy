// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";

/// @notice Smoke tests for the one fully-implemented contract in the scaffold.
///         The vault/loop logic lands behind these once REQ-SWAP is available.
contract SyntheticTokenTest is Test {
    SyntheticToken internal synth;
    address internal admin = address(0xA11CE);
    address internal vault = address(0xBEEF);
    address internal user = address(0xCAFE);

    function setUp() public {
        synth = new SyntheticToken("Propeller Synthetic HOLLAR", "psHOLLAR", admin);
        bytes32 minter = synth.MINTER_ROLE();
        vm.prank(admin);
        synth.grantRole(minter, vault);
    }

    function test_decimals() public view {
        assertEq(synth.decimals(), 18);
    }

    function test_minterCanMintAndBurn() public {
        vm.prank(vault);
        synth.mint(vault, 1_000e18);
        assertEq(synth.balanceOf(vault), 1_000e18);

        vm.prank(vault);
        synth.burn(vault, 400e18);
        assertEq(synth.balanceOf(vault), 600e18);
    }

    function test_nonMinterCannotMint() public {
        vm.expectRevert();
        vm.prank(user);
        synth.mint(user, 1e18);
    }

    function testFuzz_mintBurnRoundTrips(uint128 amt) public {
        vm.assume(amt > 0);
        vm.startPrank(vault);
        synth.mint(vault, amt);
        assertEq(synth.totalSupply(), amt);
        synth.burn(vault, amt);
        assertEq(synth.totalSupply(), 0);
        vm.stopPrank();
    }
}
