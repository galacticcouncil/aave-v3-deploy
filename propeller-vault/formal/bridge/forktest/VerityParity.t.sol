// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// TEMPLATE — lives outside the Foundry `test/` path so it can't break the green suite.
// Wire in per ../README.md once (1) `solc 0.8.33` has built bytecode/CollateralVaultAave.bin and
// (2) the upstream uint16 selector fix lands. It exercises the VERITY-EMITTED bytecode (not the Lean
// proofs): deploy it, run `deposit` against mocks that mirror the emitted uint256-arg selectors, and
// assert the accounting storage slots + that each cross-contract call was recorded.

import {Test} from "forge-std/Test.sol";

/// aave pool mirroring the selectors Verity emits (uint256 referralCode, not uint16).
contract MockAaveU256 {
    bytes32 public last;            // keccak of the last call, for assertion
    uint256 public supplied;
    uint256 public borrowed;
    function supply(address a, uint256 amt, address obo, uint256 ref) external returns (bool) {
        supplied += amt; last = keccak256(abi.encode("supply", a, amt, obo, ref)); return true;
    }
    function borrow(address a, uint256 amt, uint256 mode, uint256 ref, address obo) external returns (bool) {
        borrowed += amt; last = keccak256(abi.encode("borrow", a, amt, mode, ref, obo)); return true;
    }
    function repay(address, uint256 amt, uint256, address) external pure returns (uint256) { return amt; }
    function withdraw(address, uint256 amt, address) external pure returns (uint256) { return amt; }
}

contract MockSynth { // SyntheticToken.mint(address,uint256)
    uint256 public minted;
    function mint(address, uint256 amt) external returns (bool) { minted += amt; return true; }
}

contract MockSubLoop { // SubLoop.deposit(uint256)
    uint256 public seeded;
    function deposit(uint256 amt) external returns (bool) { seeded += amt; return true; }
}

contract VerityParityTest is Test {
    // verity deposit signature (interface params lower to address):
    //   deposit(address pool, address synth, address loop, address asset, address hollar,
    //           address onBehalfOf, uint256 assets, uint256 borrowAmount, uint256 synthAmount)
    bytes4 constant DEPOSIT =
        bytes4(keccak256("deposit(address,address,address,address,address,address,uint256,uint256,uint256)"));

    address vault;
    MockAaveU256 pool;
    MockSynth synth;
    MockSubLoop loop;
    address keeper;
    address asset;
    address hollar;

    function setUp() public {
        keeper = makeAddr("keeper");
        asset = makeAddr("asset");
        hollar = makeAddr("hollar");
        // skip cleanly until the bytecode artifact exists (see build-yul.sh).
        string memory path = "formal/bridge/forktest/bytecode/CollateralVaultAave.bin";
        try vm.readFile(path) returns (string memory hexstr) {
            pool = new MockAaveU256(); synth = new MockSynth(); loop = new MockSubLoop();
            bytes memory code = vm.parseBytes(hexstr); // runtime+init hex from solc
            bytes memory initWithArgs =
                abi.encodePacked(code, abi.encode(keeper, address(pool), address(synth), address(loop)));
            address v;
            assembly { v := create(0, add(initWithArgs, 0x20), mload(initWithArgs)) }
            require(v != address(0), "verity vault deploy failed");
            vault = v;
        } catch {
            vm.skip(true); // no bytecode yet → skipped, never red
        }
    }

    function test_deposit_wires_all_calls() public {
        uint256 assets = 1e18; uint256 borrowAmt = 0.74e18; uint256 synthAmt = 0.74e18;
        vm.prank(address(this));
        (bool ok,) = vault.call(abi.encodeWithSelector(
            DEPOSIT, address(pool), address(synth), address(loop),
            asset, hollar, address(this), assets, borrowAmt, synthAmt));
        assertTrue(ok, "verity deposit reverted");

        // cross-contract calls landed with the right amounts
        assertEq(pool.supplied(), assets, "supply amount");
        assertEq(pool.borrowed(), borrowAmt, "borrow amount");
        assertEq(synth.minted(), synthAmt, "synth.mint amount");
        assertEq(loop.seeded(), borrowAmt, "subloop.deposit amount");

        // accounting storage slots (0 totalAssets, 1 totalSupply, 3 mainDebt, 4 synthSupply)
        assertEq(uint256(vm.load(vault, bytes32(uint256(0)))), assets, "slot0 totalAssets");
        assertEq(uint256(vm.load(vault, bytes32(uint256(1)))), assets, "slot1 totalSupply");
        assertEq(uint256(vm.load(vault, bytes32(uint256(3)))), borrowAmt, "slot3 mainDebt");
        assertEq(uint256(vm.load(vault, bytes32(uint256(4)))), synthAmt, "slot4 synthSupply");
    }

    function test_pokeSettle_onlyKeeper() public {
        // non-keeper caller must revert (deploy-side access control)
        (bool ok,) = vault.call(abi.encodeWithSignature(
            "pokeSettle(address,address,address,address,address,uint256,uint256)",
            address(pool), address(0), address(0), address(this), address(this), uint256(0), uint256(0)));
        assertFalse(ok, "non-keeper pokeSettle should revert");
    }
}
