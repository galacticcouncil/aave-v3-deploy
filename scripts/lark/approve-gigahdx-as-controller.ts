// Register GIGAHDX Pool as an approved controller via
// `pallet-evm-accounts::approve_contract`.
//
// **WHY THIS IS REQUIRED.** HOLLAR (`GhoToken`) sets its `delegatedToken` to
// the native HDX precompile. On `HOLLAR.transferFrom(liquidator, GhoAToken,
// amount)` — which AAVE's `liquidationCall` does internally — HOLLAR first
// calls `HDX.allowance(liquidator, pool)` and, if that returns ≥ `amount`,
// SKIPS the internal allowance check.
//
// The HDX precompile (`runtime/hydradx/src/evm/precompiles/multicurrency.rs`)
// returns `Balance::MAX` only when the spender is in
// `pallet_evm_accounts::ApprovedContract`. The MAIN AAVE pool was added at
// deployment time; the GIGAHDX (second-MM-instance) pool was missed.
//
// Without this registration, HOLLAR falls through to the internal allowance
// path. The liquidator never called `HOLLAR.approve(pool, ...)` (Martin's
// `pallet-liquidation::liquidate_gigahdx` deliberately doesn't), so internal
// `allowance[liquidator][pool] == 0`. AAVE then runs `allowance -= amount`
// with Solidity 0.8+ checked math → underflow → `Panic(0x11)` → liquidation
// reverts as `dispatcher.EvmArithmeticOverflowOrUnderflow`.
//
// Symptom: PEPL's gigahdx liquidations log `gigahdx: liquidationCall reverted:
// [78, 72, 123, 113, 0..., 17]` repeatedly. The OR-clause routing fix in
// `pallets/liquidation/src/lib.rs` is necessary but not sufficient — without
// this approve_contract step, every liquidation still panics in the HOLLAR
// transferFrom.
//
// **ORIGIN.** `evmAccounts::approve_contract` requires Root or GeneralAdmin.
// We use the WhitelistedCaller path (Alice as sole TC on lark) so it lands
// in minutes instead of waiting through a GeneralAdmin referendum.
//
// Run once per chain (idempotent — script checks `approvedContract(pool)`
// and exits if already registered). Run AFTER Phase 7 (proposal enactment
// puts the GIGAHDX pool address into `pallet_gigahdx::gigaHdxPoolContract`).
//
// Usage:
//   WS_URL=wss://<N>.lark.hydration.cloud \
//     npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' \
//     scripts/lark/approve-gigahdx-as-controller.ts

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import type { SubmittableExtrinsic } from "@polkadot/api/types";
import * as fs from "fs";
import * as path from "path";

const LARK_WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";
const MAX_VOTE_BASE = 4_000_000_000n * 10n ** 12n; // 4B HDX — Ben's rule

function resolveGigahdxPool(): string {
	if (process.env.GIGAHDX_POOL) return process.env.GIGAHDX_POOL;
	const p = path.join(__dirname, "..", "..", "deployments", "lark2", "Pool-Proxy-GIGAHDX.json");
	if (!fs.existsSync(p)) {
		throw new Error(`Pool-Proxy-GIGAHDX.json not found at ${p}; set GIGAHDX_POOL env var`);
	}
	return JSON.parse(fs.readFileSync(p, "utf8")).address;
}

async function signAndWait(
	tx: SubmittableExtrinsic<"promise">,
	signer: any,
	api: ApiPromise,
	label: string
): Promise<any[]> {
	console.log(`\n--- ${label} ---`);
	return new Promise((resolve, reject) => {
		tx.signAndSend(signer, ({ status, dispatchError, events }) => {
			if (status.isInBlock) console.log(`  in block: ${status.asInBlock.toHex().slice(0, 18)}...`);
			if (status.isFinalized) {
				if (dispatchError) {
					if (dispatchError.isModule) {
						const d = api.registry.findMetaError(dispatchError.asModule);
						return reject(new Error(`${d.section}.${d.name}: ${d.docs.join(" ")}`));
					}
					return reject(new Error(dispatchError.toString()));
				}
				for (const { event } of events) {
					if (event.section === "system" && event.method === "ExtrinsicFailed") {
						return reject(new Error(`ExtrinsicFailed: ${event.data.toString()}`));
					}
				}
				console.log(`  OK`);
				resolve(events as any[]);
			}
		}).catch(reject);
	});
}

async function main() {
	const GIGAHDX_POOL = resolveGigahdxPool();
	console.log(`GIGAHDX Pool: ${GIGAHDX_POOL}`);

	const api = await ApiPromise.create({ provider: new WsProvider(LARK_WS) });
	const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");

	// Idempotency: skip if already approved.
	const existing: any = await api.query.evmAccounts.approvedContract(GIGAHDX_POOL);
	if (!existing.isEmpty) {
		console.log(`GIGAHDX pool already in approved contracts — nothing to do`);
		await api.disconnect();
		return;
	}

	// Build the inner call: evmAccounts.approve_contract(GIGAHDX_POOL).
	// Requires Root or GeneralAdmin. Dispatched as Root via the whitelist
	// pallet (`whitelist.dispatch_whitelisted_call_with_preimage` runs the
	// call with `Origin::Root` — see FRAME whitelist pallet source).
	const innerCall: any = (api.tx as any).evmAccounts.approveContract(GIGAHDX_POOL);
	const innerHash = innerCall.method.hash.toHex();
	console.log(`inner call hash: ${innerHash}`);

	// TC whitelist the inner call hash (Alice = sole TC member on lark).
	const wl: any = await api.query.whitelist.whitelistedCall(innerHash);
	if (!wl.isSome) {
		const wlCall = api.tx.whitelist.whitelistCall(innerHash);
		await signAndWait(
			api.tx.technicalCommittee.propose(1, wlCall, wlCall.method.encodedLength),
			alice,
			api,
			"TC propose(whitelist.whitelistCall)"
		);
	} else {
		console.log("inner already whitelisted");
	}

	// Wrap inner in dispatchWhitelistedCallWithPreimage (preimage embedded inline).
	const wrapper = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(innerCall);
	const wrapperHex = wrapper.method.toHex();
	const wrapperHash = wrapper.method.hash.toHex();
	const wrapperLen = wrapper.method.encodedLength;
	console.log(`wrapper hash: ${wrapperHash} len: ${wrapperLen}`);

	const preReq: any = await api.query.preimage.requestStatusFor(wrapperHash);
	const preOld: any = await api.query.preimage.statusFor(wrapperHash);
	if (!preReq.isSome && !preOld.isSome) {
		await signAndWait(
			api.tx.preimage.notePreimage(wrapperHex),
			alice,
			api,
			"preimage.notePreimage"
		);
	} else {
		console.log("wrapper preimage already noted");
	}

	// Submit WhitelistedCaller ref + decision deposit + vote.
	const events = await signAndWait(
		api.tx.referenda.submit(
			{ Origins: "WhitelistedCaller" },
			{ Lookup: { hash: wrapperHash, len: wrapperLen } },
			{ After: 1 }
		),
		alice,
		api,
		"referenda.submit(WhitelistedCaller)"
	);
	let refIndex: number | null = null;
	for (const { event } of events) {
		if (event.section === "referenda" && event.method === "Submitted") {
			refIndex = (event.data[0] as any).toNumber();
			break;
		}
	}
	if (refIndex == null) throw new Error("no Submitted event");
	console.log(`ref: ${refIndex}`);

	await signAndWait(
		api.tx.referenda.placeDecisionDeposit(refIndex),
		alice,
		api,
		"placeDecisionDeposit"
	);

	const bal: any = await api.query.system.account(alice.address);
	const free = bal.data.free.toBigInt();
	const voteBalance = (free < MAX_VOTE_BASE ? free : MAX_VOTE_BASE).toString();
	console.log(`voting with ${Number(BigInt(voteBalance) / 10n ** 12n).toLocaleString()} HDX at 6x (4B cap)`);
	await signAndWait(
		api.tx.convictionVoting.vote(refIndex, {
			Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
		}),
		alice,
		api,
		"convictionVoting.vote"
	);

	for (let i = 0; i < 60; i++) {
		await new Promise((r) => setTimeout(r, 3000));
		const info: any = await api.query.referenda.referendumInfoFor(refIndex);
		if (!info.isSome) continue;
		const r = info.unwrap();
		console.log(`  [${i}] ${r.type}`);
		if (r.isApproved) break;
		if (r.isRejected || r.isCancelled || r.isTimedOut || r.isKilled)
			throw new Error(`${r.type}`);
	}

	console.log("waiting 15s for enactment...");
	await new Promise((r) => setTimeout(r, 15000));

	const approved: any = await api.query.evmAccounts.approvedContract(GIGAHDX_POOL);
	if (!approved.isEmpty) {
		console.log(`\n✓ GIGAHDX pool is now an approved contract.`);
	} else {
		console.log(`\nWARNING: GIGAHDX pool NOT in approvedContract after enactment — check events`);
	}

	await api.disconnect();
}

main().catch((e) => {
	console.error(`FAILED: ${e.message}`);
	process.exit(1);
});
