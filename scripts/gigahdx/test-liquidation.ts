// LIQUIDATION test for GIGAHDX (missing from test-e2e.ts which only covers
// supply/borrow/repay/withdraw/transfer).
//
// Goal: exercise AAVE V3's Pool.liquidationCall against the GIGAHDX pool with
// ethers.js so we get full revert-data decoding. The substrate evm.call path
// strips revert payload to just `0x`, hiding which custom error / Panic code
// was emitted.
//
// Strategy:
//   1. Stake a tiny amount as a NEW tester (so the position isn't lock-bound by
//      prior gigahdx state from existing borrowers).
//   2. Have tester borrow HOLLAR; drive HF below 1 by dropping stHDX price.
//   3. Use a SEPARATE liquidator account that gets HOLLAR + approves the pool.
//   4. Call Pool.liquidationCall via ethers.js, capture revert reason.
//
// In our case the running chain ALREADY has Alice as a $145K-debt borrower with
// HF<1, so we skip steps 1-2 and just go straight to the liquidation probe.
// The catch: Alice's stHDX is lock-bound (Stakes.gigahdx > 0). A direct EVM
// liquidationCall would revert with ExceedsFreeBalance on the seize transfer.
// To test the AAVE math in isolation, we ALSO bypass the lock via storage
// override (substrate set_storage of `pallet_gigahdx::Stakes[Alice].gigahdx = 0`).
//
// Usage:
//   WS_URL=ws://127.0.0.1:9999 RPC_URL=http://127.0.0.1:9999 \
//     npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' \
//     scripts/gigahdx/test-liquidation.ts

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const WS_URL = process.env.WS_URL || "ws://127.0.0.1:9999";
const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:9999";

// Borrower (currently liquidatable on the running chain)
const BORROWER = process.env.BORROWER || "0xd43593c715fdd31c61141abd04a99fd6822c8558"; // Alice EVM
const BORROWER_URI = process.env.BORROWER_URI || "//Alice"; // for any substrate-side cleanup

// Liquidator (must have HOLLAR + allowance)
const LIQUIDATOR = process.env.LIQUIDATOR || "0x8eaf04151687736326c9fea17e25fc5287613693"; // Bob EVM
const LIQUIDATOR_URI = process.env.LIQUIDATOR_URI || "//Bob";

const STHDX_UNDERLYING = "0x000000000000000000000000000000010000029e";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";

function readDeployment(name: string): string {
	const p = path.join(__dirname, "..", "..", "deployments", "lark2", `${name}.json`);
	if (!fs.existsSync(p)) throw new Error(`missing artifact: ${p}`);
	return JSON.parse(fs.readFileSync(p, "utf8")).address;
}
const POOL = process.env.POOL || readDeployment("Pool-Proxy-GIGAHDX");
const ORACLE = process.env.ORACLE || readDeployment("AaveOracle-GIGAHDX");

// Iface for everything we need
const POOL_ABI = [
	"function liquidationCall(address collateralAsset, address debtAsset, address user, uint256 debtToCover, bool receiveAToken) external",
	"function getUserAccountData(address user) external view returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor)",
	"function getReserveData(address asset) external view returns (tuple(tuple(uint256 data) configuration, uint128 liquidityIndex, uint128 currentLiquidityRate, uint128 variableBorrowIndex, uint128 currentVariableBorrowRate, uint128 currentStableBorrowRate, uint40 lastUpdateTimestamp, uint16 id, address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress, address interestRateStrategyAddress, uint128 accruedToTreasury, uint128 unbacked, uint128 isolationModeTotalDebt))",
];
const ERC20_ABI = [
	"function balanceOf(address) external view returns (uint256)",
	"function allowance(address owner, address spender) external view returns (uint256)",
	"function approve(address spender, uint256 amount) external returns (bool)",
];
const ORACLE_ABI = [
	"function getAssetPrice(address asset) external view returns (uint256)",
];

// Known error selectors
const PANIC_SELECTOR = "0x4e487b71";
const EXCEEDS_FREE_BALANCE_SELECTOR = "0x9e176ac9"; // LockableAToken
const ERROR_STRING_SELECTOR = "0x08c379a0";

function decodeRevert(data: string): string {
	if (!data || data === "0x") return "<empty revert data — likely OOG or low-level revert>";
	const sel = data.slice(0, 10).toLowerCase();
	if (sel === PANIC_SELECTOR) {
		const code = BigInt("0x" + data.slice(10).slice(0, 64));
		const reasons: Record<string, string> = {
			"0x01": "assert(false)",
			"0x11": "arithmetic over/underflow",
			"0x12": "division/modulo by zero",
			"0x21": "invalid enum",
			"0x22": "storage byte array bad",
			"0x31": "pop from empty array",
			"0x32": "array index out of bounds",
			"0x41": "alloc too much memory / array too large",
			"0x51": "invalid function pointer",
		};
		return `Panic(0x${code.toString(16)}) — ${reasons["0x" + code.toString(16)] || "unknown"}`;
	}
	if (sel === EXCEEDS_FREE_BALANCE_SELECTOR) {
		const requested = BigInt("0x" + data.slice(10, 74));
		const available = BigInt("0x" + data.slice(74, 138));
		return `ExceedsFreeBalance(requested=${requested}, available=${available})`;
	}
	if (sel === ERROR_STRING_SELECTOR) {
		try {
			const str = ethers.utils.defaultAbiCoder.decode(["string"], "0x" + data.slice(10))[0];
			return `Error("${str}")`;
		} catch {
			return `Error(<undecodable string>) ${data}`;
		}
	}
	return `unknown selector ${sel} — raw: ${data.slice(0, 80)}…`;
}

type Status = "pass" | "fail" | "skip";
const results: Array<{ phase: string; status: Status; note: string }> = [];

function section(s: string) {
	console.log("\n" + "=".repeat(72));
	console.log("  " + s);
	console.log("=".repeat(72));
}

async function phase(label: string, fn: () => Promise<string>): Promise<boolean> {
	section(label);
	try {
		const note = await fn();
		console.log(`\n  PASS — ${note}`);
		results.push({ phase: label, status: "pass", note });
		return true;
	} catch (e: any) {
		console.log(`\n  FAIL — ${e.message || e}`);
		results.push({ phase: label, status: "fail", note: e.message || String(e) });
		return false;
	}
}

async function main() {
	console.log(`POOL:       ${POOL}`);
	console.log(`ORACLE:     ${ORACLE}`);
	console.log(`BORROWER:   ${BORROWER}`);
	console.log(`LIQUIDATOR: ${LIQUIDATOR}`);
	console.log(`RPC:        ${RPC_URL}`);
	console.log(`WS:         ${WS_URL}`);

	const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
	const pool = new ethers.Contract(POOL, POOL_ABI, provider);
	const oracle = new ethers.Contract(ORACLE, ORACLE_ABI, provider);
	const hollar = new ethers.Contract(HOLLAR, ERC20_ABI, provider);

	// PHASE 1: pre-flight
	await phase("Phase 1 — Verify borrower is liquidatable", async () => {
		const acc = await pool.getUserAccountData(BORROWER);
		const hf = acc.healthFactor.toString();
		const debt = acc.totalDebtBase.toString();
		const col = acc.totalCollateralBase.toString();
		console.log(`  collateral=$${(Number(col) / 1e8).toFixed(2)}, debt=$${(Number(debt) / 1e8).toFixed(2)}, HF=${(Number(hf) / 1e18).toFixed(4)}`);
		if (BigInt(hf) >= BigInt("1000000000000000000")) {
			throw new Error(`borrower not liquidatable (HF >= 1)`);
		}
		return `HF=${(Number(hf) / 1e18).toFixed(4)} — liquidatable`;
	});

	// PHASE 2: verify oracles
	await phase("Phase 2 — Verify oracles respond", async () => {
		const sthdxPrice = await oracle.getAssetPrice(STHDX_UNDERLYING);
		const hollarPrice = await oracle.getAssetPrice(HOLLAR);
		console.log(`  stHDX:  ${sthdxPrice.toString()} = $${(Number(sthdxPrice) / 1e8).toFixed(8)}`);
		console.log(`  HOLLAR: ${hollarPrice.toString()} = $${(Number(hollarPrice) / 1e8).toFixed(4)}`);
		if (BigInt(sthdxPrice) === 0n) throw new Error("stHDX oracle returns 0");
		if (BigInt(hollarPrice) === 0n) throw new Error("HOLLAR oracle returns 0");
		return `stHDX=${sthdxPrice}, HOLLAR=${hollarPrice}`;
	});

	// PHASE 3: verify liquidator has HOLLAR + allowance
	await phase("Phase 3 — Verify liquidator funding", async () => {
		const bal = await hollar.balanceOf(LIQUIDATOR);
		const allow = await hollar.allowance(LIQUIDATOR, POOL);
		console.log(`  liquidator HOLLAR balance:   ${bal.toString()} (${(Number(bal) / 1e18).toFixed(4)})`);
		console.log(`  liquidator allowance → POOL: ${allow.toString()} (${(Number(allow) / 1e18).toFixed(4)})`);
		if (BigInt(bal) === 0n) throw new Error("liquidator has no HOLLAR");
		return `bal=${(Number(bal) / 1e18).toFixed(2)}, allowance=${(Number(allow) / 1e18).toFixed(2)}`;
	});

	// PHASE 4: dump the reserve states (these are the bytes liquidationCall reads)
	await phase("Phase 4 — Reserve state snapshot", async () => {
		const stRes = await pool.getReserveData(STHDX_UNDERLYING);
		const hrRes = await pool.getReserveData(HOLLAR);
		console.log(`  stHDX reserve:`);
		console.log(`    aTokenAddress:                ${stRes.aTokenAddress}`);
		console.log(`    variableDebtTokenAddress:     ${stRes.variableDebtTokenAddress}`);
		console.log(`    interestRateStrategyAddress:  ${stRes.interestRateStrategyAddress}`);
		console.log(`    liquidityIndex:               ${stRes.liquidityIndex.toString()}`);
		console.log(`    accruedToTreasury:            ${stRes.accruedToTreasury.toString()}`);
		console.log(`    isolationModeTotalDebt:       ${stRes.isolationModeTotalDebt.toString()}`);
		console.log(`  HOLLAR reserve:`);
		console.log(`    aTokenAddress (GhoAToken):    ${hrRes.aTokenAddress}`);
		console.log(`    variableDebtTokenAddress:     ${hrRes.variableDebtTokenAddress}`);
		console.log(`    interestRateStrategyAddress:  ${hrRes.interestRateStrategyAddress}`);
		console.log(`    variableBorrowIndex:          ${hrRes.variableBorrowIndex.toString()}`);
		console.log(`    accruedToTreasury:            ${hrRes.accruedToTreasury.toString()}`);
		return "snapshot ok";
	});

	// PHASE 5: try liquidationCall via eth_call (dry-run) — captures revert data CLEANLY
	for (const amt of [
		"1000000000000000",       // 0.001 HOLLAR
		"100000000000000000",      // 0.1 HOLLAR
		"1000000000000000000",     // 1 HOLLAR
		"10000000000000000000",    // 10 HOLLAR
		"100000000000000000000",   // 100 HOLLAR
		"1000000000000000000000",  // 1000 HOLLAR
	]) {
		const human = (Number(amt) / 1e18).toFixed(6);
		await phase(`Phase 5.${human} — eth_call liquidationCall(${human} HOLLAR, receiveAToken=true)`, async () => {
			const iface = new ethers.utils.Interface(POOL_ABI);
			const calldata = iface.encodeFunctionData("liquidationCall", [
				STHDX_UNDERLYING,
				HOLLAR,
				BORROWER,
				amt,
				true,
			]);
			try {
				await provider.call({ from: LIQUIDATOR, to: POOL, data: calldata, gasLimit: "0x7a120" });
				return "SIMULATED OK (would succeed if executed as tx)";
			} catch (e: any) {
				// dump full structure to find where ethers stashes the data
				const dataPaths = [
					e.data,
					e.error?.data,
					e.error?.error?.data,
					e.body && tryGetBodyData(e.body),
				].filter(Boolean);
				const errData = dataPaths[0] || "";
				if (!errData) {
					console.log(`    full e: ${JSON.stringify({ code: e.code, reason: e.reason, body: e.body?.slice?.(0, 300), error: e.error })}`);
				}
				throw new Error(`revert: ${decodeRevert(errData)}`);
			}
		});
	}

	// PHASE 6: try receiveAToken=false (different code path: _burnCollateralATokens)
	await phase("Phase 6 — eth_call liquidationCall(1 HOLLAR, receiveAToken=FALSE)", async () => {
		const iface = new ethers.utils.Interface(POOL_ABI);
		const calldata = iface.encodeFunctionData("liquidationCall", [
			STHDX_UNDERLYING,
			HOLLAR,
			BORROWER,
			"1000000000000000000",
			false,
		]);
		try {
			await provider.call({ from: LIQUIDATOR, to: POOL, data: calldata, gasLimit: "0x7a120" });
			return "SIMULATED OK";
		} catch (e: any) {
			const errData = e.data || e.error?.data || (e.body && tryGetBodyData(e.body)) || "";
			throw new Error(`revert: ${decodeRevert(errData)}`);
		}
	});

	// PHASE 7: probe the HOLLAR IR strategy directly with the parameters AAVE
	// would pass during a liquidation. If IT panics, we've found the site.
	await phase("Phase 7 — probe HOLLAR IR strategy calculateInterestRates", async () => {
		// The strategy is custom (GhoInterestRateStrategy). Call calculateInterestRates(params)
		// with the kind of input updateInterestRates would generate.
		const hrRes = await pool.getReserveData(HOLLAR);
		const strategy = hrRes.interestRateStrategyAddress;

		// AAVE V3 CalculateInterestRatesParams struct:
		const STRATEGY_ABI = [
			"function calculateInterestRates(tuple(uint256 unbacked, uint256 liquidityAdded, uint256 liquidityTaken, uint256 totalStableDebt, uint256 totalVariableDebt, uint256 averageStableBorrowRate, uint256 reserveFactor, address reserve, address aToken)) external view returns (uint256 liquidityRate, uint256 stableBorrowRate, uint256 variableBorrowRate)",
		];
		const ir = new ethers.Contract(strategy, STRATEGY_ABI, provider);

		try {
			const result = await ir.calculateInterestRates({
				unbacked: 0,
				liquidityAdded: "1000000000000000000", // 1 HOLLAR repaid
				liquidityTaken: 0,
				totalStableDebt: 0,
				totalVariableDebt: "144837281260619447670460", // Alice's scaled debt
				averageStableBorrowRate: 0,
				reserveFactor: "2000", // 20%
				reserve: HOLLAR,
				aToken: hrRes.aTokenAddress,
			});
			console.log(`  liqRate: ${result.liquidityRate}, stableRate: ${result.stableBorrowRate}, varRate: ${result.variableBorrowRate}`);
			return "IR strategy OK";
		} catch (e: any) {
			const errData = e.data || e.error?.data || (e.body && tryGetBodyData(e.body)) || "";
			throw new Error(`IR revert: ${decodeRevert(errData)}`);
		}
	});

	// PHASE 8: connect substrate API and submit Martin's pallet liquidation
	// extrinsic. Captures the EVM-side revert via the node's log file.
	await phase("Phase 8 — submit Liquidation.liquidate(670, 222, alice, 1 HOLLAR, []) via substrate", async () => {
		const api = await ApiPromise.create({ provider: new WsProvider(WS_URL) });
		await api.isReady;
		const bob = new Keyring({ type: "sr25519" }).addFromUri(LIQUIDATOR_URI);
		console.log(`  signing with ${LIQUIDATOR_URI} = ${bob.address}`);

		const tx = api.tx.liquidation.liquidate(670, 222, BORROWER, "1000000000000000000", []);
		const result: any = await new Promise((resolve, reject) => {
			tx.signAndSend(bob, ({ status, dispatchError, events }: any) => {
				if (dispatchError) {
					let msg = dispatchError.toString();
					if (dispatchError.isModule) {
						const d = api.registry.findMetaError(dispatchError.asModule);
						msg = `${d.section}.${d.name} (${d.docs.join(" ")})`;
					}
					return resolve({ ok: false, err: msg, events });
				}
				if (status.isInBlock) {
					const evts = events.map((e: any) => ({ section: e.event.section, method: e.event.method }));
					resolve({ ok: true, block: status.asInBlock.toHex(), events: evts });
				}
			}).catch(reject);
		});
		await api.disconnect();

		if (result.ok) return `liquidation extrinsic succeeded in ${result.block.slice(0, 10)}…`;
		throw new Error(`extrinsic err: ${result.err}`);
	});

	function tryGetBodyData(body: string): string | undefined {
		try {
			const j = JSON.parse(body);
			return j?.error?.data;
		} catch { return undefined; }
	}

	// summary
	console.log("\n" + "=".repeat(72));
	console.log("  SUMMARY");
	console.log("=".repeat(72));
	const colW = 60;
	for (const r of results) {
		const tag = r.status === "pass" ? "  PASS  " : r.status === "fail" ? "  FAIL  " : "  SKIP  ";
		console.log(`  ${r.phase.padEnd(colW)} ${tag}`);
		if (r.note && r.status !== "pass") {
			console.log(`         note: ${r.note.slice(0, 120)}`);
		}
	}
	const failed = results.filter(r => r.status === "fail").length;
	if (failed) {
		console.log(`\n  ${failed} of ${results.length} phases FAILED — see notes above`);
	} else {
		console.log(`\n  ALL ${results.length} PHASES PASSED`);
	}
}

main().catch((e) => {
	console.error("FATAL:", e);
	process.exit(1);
});
