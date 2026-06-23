// Mint WETH (asset 20) on a freshly-reset lark testnet via WhitelistedCaller ref.
//
// On a freshly-bootstrapped lark, //Alice has plenty of HDX but ZERO WETH, which
// breaks `scripts/gigahdx/fund-account.ts` when funding the deployer's EVM-truncated account
// (deployer needs WETH for EVM gas). This script uses the same governance pattern
// as `scripts/gigahdx/runtime-upgrade.ts` to inject WETH directly via `tokens.setBalance`
// (Root origin, dispatched through WhitelistedCaller track).
//
// Defaults (override via env):
//   ALICE_WETH=10   — WETH minted to //Alice
//   DEPLOYER_WETH=1 — WETH minted directly to deployer's truncated SS58
//
// Usage:
//   WS_URL=wss://2.lark.hydration.cloud \
//     npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' \
//     scripts/gigahdx/mint-weth-wl.ts
//
// After this succeeds, run the standard `scripts/gigahdx/fund-account.ts` to transfer HDX
// to the deployer (or any other account) — Alice now has WETH to spare.

import { ApiPromise, WsProvider, Keyring } from "@polkadot/api";
import { hexToU8a } from "@polkadot/util";
import { encodeAddress } from "@polkadot/util-crypto";
import type { SubmittableExtrinsic } from "@polkadot/api/types";

const LARK_WS = process.env.WS_URL || "wss://2.lark.hydration.cloud";
const WETH_ASSET_ID = 20;
const HYDRATION_PREFIX = 63;

// Per Ben's rule. 4B HDX is well above any track's passing threshold on
// Hydration (total issuance ~6.5B) and avoids locking Alice's entire balance.
const MAX_VOTE_BASE = 4_000_000_000n * 10n ** 12n;

// Deployer EVM address — same Alice-derived dev key everyone uses on lark.
const DEPLOYER_EVM = "0x222222B60cA97a4998B7D07b99034Fa4d9339531";

const ALICE_WETH_HUMAN = process.env.ALICE_WETH || "10";
const DEPLOYER_WETH_HUMAN = process.env.DEPLOYER_WETH || "1";

function toBaseUnits(human: string, decimals: number): bigint {
	if (!human || human === "0") return 0n;
	const [whole, frac = ""] = human.split(".");
	const padded = (frac + "0".repeat(decimals)).slice(0, decimals);
	return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(padded || "0");
}

function evmToTruncatedSs58(evm: string): string {
	const buf = new Uint8Array(32);
	buf[0] = 0x45;
	buf[1] = 0x54;
	buf[2] = 0x48;
	buf[3] = 0x00;
	buf.set(hexToU8a(evm), 4);
	return encodeAddress(buf, HYDRATION_PREFIX);
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
	const api = await ApiPromise.create({ provider: new WsProvider(LARK_WS) });
	const alice = new Keyring({ type: "sr25519" }).addFromUri("//Alice");
	const deployerSs58 = evmToTruncatedSs58(DEPLOYER_EVM);

	const aliceWeth = toBaseUnits(ALICE_WETH_HUMAN, 18);
	const deployerWeth = toBaseUnits(DEPLOYER_WETH_HUMAN, 18);

	console.log(`alice:    ${alice.address}  +${ALICE_WETH_HUMAN} WETH`);
	console.log(`deployer: ${deployerSs58}  +${DEPLOYER_WETH_HUMAN} WETH`);

	// Skip fast-path: if both are already funded above thresholds, bail.
	const aliceWethBefore: any = await api.query.tokens.accounts(alice.address, WETH_ASSET_ID);
	const deployerWethBefore: any = await api.query.tokens.accounts(deployerSs58, WETH_ASSET_ID);
	if (aliceWethBefore.free.toBigInt() >= aliceWeth && deployerWethBefore.free.toBigInt() >= deployerWeth) {
		console.log("both already funded — nothing to do");
		await api.disconnect();
		return;
	}

	// Inner: batchAll(setBalance(alice), setBalance(deployer)) — under Root.
	const set1 = api.tx.tokens.setBalance(alice.address, WETH_ASSET_ID, aliceWeth.toString(), "0");
	const set2 = api.tx.tokens.setBalance(deployerSs58, WETH_ASSET_ID, deployerWeth.toString(), "0");
	const innerCall = api.tx.utility.batchAll([set1, set2]);
	const innerHash = innerCall.method.hash.toHex();
	console.log(`inner (batchAll[setBalance,setBalance]) hash: ${innerHash}`);

	// Step 1: TC whitelists the inner hash (no-op if already whitelisted)
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
		console.log("inner call already whitelisted");
	}

	// Step 2: Wrapper + preimage
	const wrapper = api.tx.whitelist.dispatchWhitelistedCallWithPreimage(innerCall);
	const wrapperHex = wrapper.method.toHex();
	const wrapperHash = wrapper.method.hash.toHex();
	const wrapperLen = wrapper.method.encodedLength;
	console.log(`wrapper hash: ${wrapperHash} len: ${wrapperLen}`);

	const pre: any = await api.query.preimage.requestStatusFor(wrapperHash);
	const preOld: any = await api.query.preimage.statusFor(wrapperHash);
	if (!pre.isSome && !preOld.isSome) {
		await signAndWait(
			api.tx.preimage.notePreimage(wrapperHex),
			alice,
			api,
			"preimage.notePreimage"
		);
	} else {
		console.log("wrapper preimage already noted");
	}

	// Step 3: Submit on whitelisted_caller track (1)
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

	// Vote against `free` directly — same-class lock is max-ed (per runbook gotcha #2),
	// so re-voting at 6x within track 1 doesn't add lock beyond the existing 4B from any
	// prior whitelisted-caller ref. Subtracting `frozen` is wrong for re-votes; it caps
	// the vote at usable (which can be tiny) and the support curve takes hours to drift
	// down to a passing threshold.
	const bal: any = await api.query.system.account(alice.address);
	const free = bal.data.free.toBigInt();
	const voteBalance = (free < MAX_VOTE_BASE ? free : MAX_VOTE_BASE).toString();
	console.log(
		`voting with ${Number(BigInt(voteBalance) / 10n ** 12n).toLocaleString()} HDX at 6x ` +
			`(free=${Number(free / 10n ** 12n).toLocaleString()}, cap=4B)`
	);
	await signAndWait(
		api.tx.convictionVoting.vote(refIndex, {
			Standard: { vote: { aye: true, conviction: "Locked6x" }, balance: voteBalance },
		}),
		alice,
		api,
		"convictionVoting.vote(aye, 6x)"
	);

	// Poll for approval
	console.log(`\npolling ref ${refIndex}...`);
	for (let i = 0; i < 120; i++) {
		await new Promise((r) => setTimeout(r, 3000));
		const info: any = await api.query.referenda.referendumInfoFor(refIndex);
		if (!info.isSome) continue;
		const r = info.unwrap();
		if (r.isApproved) {
			console.log(`  Approved`);
			break;
		}
		if (r.isRejected || r.isCancelled || r.isTimedOut || r.isKilled) {
			throw new Error(`${r.type}`);
		}
		if (i % 3 === 0) console.log(`  [${i}] ${r.type}`);
	}

	// Wait for enactment
	await new Promise((r) => setTimeout(r, 15000));

	const aliceWethAfter: any = await api.query.tokens.accounts(alice.address, WETH_ASSET_ID);
	const deployerWethAfter: any = await api.query.tokens.accounts(deployerSs58, WETH_ASSET_ID);
	console.log(`\nAlice WETH:    ${aliceWethAfter.free.toString()}  (${Number(aliceWethAfter.free.toBigInt()) / 1e18} WETH)`);
	console.log(`Deployer WETH: ${deployerWethAfter.free.toString()}  (${Number(deployerWethAfter.free.toBigInt()) / 1e18} WETH)`);

	if (aliceWethAfter.free.toBigInt() < aliceWeth || deployerWethAfter.free.toBigInt() < deployerWeth) {
		throw new Error("WETH balances below requested — referendum did not enact");
	}
	console.log("\n✓✓✓ WETH minted");
	await api.disconnect();
}

main().catch((e) => {
	console.error(`\nFAILED: ${e.message}`);
	process.exit(1);
});
