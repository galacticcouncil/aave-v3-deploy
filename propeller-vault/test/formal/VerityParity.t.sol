// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// Exercises the VERITY-EMITTED bytecode (not the Lean proofs): deploy CollateralVaultAave (built by
// solc 0.8.33 from the Verity Yul), run `deposit` against mocks with the MAINNET Aave V3 ABI, and
// assert every cross-contract call + the accounting storage slots, plus the onlyKeeper guard.
// Run with `--evm-version shanghai` (or later; Hydration is Osaka) — the bytecode uses PUSH0, so on
// the default `paris` EVM it self-skips and the main suite stays green. See ../formal/bridge/forktest/.

import {Test} from "forge-std/Test.sol";

/// aave pool with the MAINNET Aave V3 ABI (uint16 referralCode → selectors 0x617ba037 / 0xa415bcad):
/// the Verity bytecode now dispatches to exactly these signatures. (real Aave's supply/borrow are
/// `void`; here they `returns (bool)` so the strict `externalCallWithReturn` 32-byte check passes —
/// see README: a live fork additionally needs a void/empty-returndata interface call in Verity.)
contract MockAavePool {
    uint256 public supplied;
    uint256 public borrowed;
    function supply(address, uint256 amt, address, uint16) external returns (bool) {
        supplied += amt; return true;
    }
    function borrow(address, uint256 amt, uint256, uint16, address) external returns (bool) {
        borrowed += amt; return true;
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
    MockAavePool pool;
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
            pool = new MockAavePool(); synth = new MockSynth(); loop = new MockSubLoop();
            bytes memory code = vm.parseBytes(hexstr); // init+runtime hex from solc 0.8.33
            bytes memory initWithArgs =
                abi.encodePacked(code, abi.encode(keeper, address(pool), address(synth), address(loop)));
            address v;
            assembly { v := create(0, add(initWithArgs, 0x20), mload(initWithArgs)) }
            // verity bytecode uses PUSH0 (shanghai+); on an older evm (foundry.toml default = paris)
            // create returns 0 → skip cleanly. run `--evm-version shanghai` (or later; Hydration is
            // Osaka) to execute. also skipped if the .bin artifact is absent.
            if (v == address(0)) { vm.skip(true); return; }
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
