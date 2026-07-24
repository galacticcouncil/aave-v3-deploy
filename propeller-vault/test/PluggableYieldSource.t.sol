// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {SyntheticToken} from "../src/SyntheticToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockYieldSource} from "./mocks/MockYieldSource.sol";

/// @notice Phase A: proves PRIME is genuinely PLUGGABLE, not just renamed. The
///         vault binds only to `IYieldSource`; here it runs a full deposit →
///         redeem → claim against `MockYieldSource` — a source with no leverage,
///         no PRIME, no Aave loop, no health factor, no keeper cranks. If this
///         works with zero changes to the vault, the seam is real.
contract PluggableYieldSourceTest is Test {
    MockERC20 eth;
    MockERC20 aEth;
    MockERC20 ethDebt;
    MockERC20 hollar;
    MockERC20 aHollar;
    MockERC20 hollarDebt;
    MockERC20 aSynth;
    MockERC20 synthDebt;

    MockPool pool;
    SyntheticToken synth;
    MockYieldSource source; // the NON-leveraged plug
    CollateralVault vault;

    function setUp() public {
        eth = new MockERC20("ETH", "ETH", 18);
        aEth = new MockERC20("aETH", "aETH", 18);
        ethDebt = new MockERC20("dETH", "dETH", 18);
        hollar = new MockERC20("HOLLAR", "HOLLAR", 18);
        aHollar = new MockERC20("aHOLLAR", "aHOLLAR", 18);
        hollarDebt = new MockERC20("dHOLLAR", "dHOLLAR", 18);
        synth = new SyntheticToken("Propeller Synthetic", "psHOLLAR", address(this));
        aSynth = new MockERC20("aSYNTH", "aSYNTH", 18);
        synthDebt = new MockERC20("dSYNTH", "dSYNTH", 18);

        pool = new MockPool();
        pool.initReserve(address(eth), address(aEth), address(ethDebt), 8500, 7500, 18, 3_000e18);
        pool.initReserve(address(hollar), address(aHollar), address(hollarDebt), 0, 0, 18, 1e18);
        pool.initReserve(address(synth), address(aSynth), address(synthDebt), 9800, 100, 18, 1e18);

        source = new MockYieldSource(address(hollar));

        vault = CollateralVault(
            address(
                new ERC1967Proxy(
                    address(new CollateralVault()),
                    abi.encodeCall(
                        CollateralVault.initialize,
                        (
                            "Propeller ETH",
                            "pETH",
                            address(eth),
                            address(pool),
                            address(source), // ← a non-leveraged IYieldSource in the socket
                            address(0),
                            address(hollar),
                            address(synth),
                            address(aEth),
                            address(hollarDebt),
                            9800,
                            1_000e18,
                            address(this)
                        )
                    )
                )
            )
        );

        synth.grantRole(synth.MINTER_ROLE(), address(vault));
    }

    function test_depositRedeemClaimThroughNonLeveragedSource() public {
        // deposit 1 ETH — the borrowed HOLLAR routes into the generic source
        eth.mint(address(this), 1e18);
        eth.approve(address(vault), 1e18);
        uint256 shares = vault.deposit(1e18, address(this));
        assertGt(shares, 0, "shares minted");

        assertGt(vault.loopShares(), 0, "vault holds shares in the generic source");
        assertGt(source.equityOf(address(vault)), 0, "source reports the vault's equity");
        assertEq(
            hollar.balanceOf(address(source)),
            hollarDebt.balanceOf(address(vault)),
            "borrowed HOLLAR is custodied by the source"
        );

        // redeem the whole position. No ramp, no pokeBorrow/pokeRepay — this
        // source has none; requestUnwind frees synchronously and pokeSettle pulls
        // it straight back.
        uint256 reqId = vault.requestRedeem(shares, address(this));
        vault.pokeSettle();
        uint256 got = vault.claim(reqId, address(this));

        // Full principal back through a source with no leverage at all. The only
        // expected shortfall is DEAD_SHARES (1000 wei), so pin it tightly — a loose
        // band would hide a real principal loss.
        assertApproxEqAbs(got, 1e18, 1e6, "principal returned via the generic seam");
        assertApproxEqAbs(hollarDebt.balanceOf(address(vault)), 0, 1e12, "Main debt repaid");
    }
}
