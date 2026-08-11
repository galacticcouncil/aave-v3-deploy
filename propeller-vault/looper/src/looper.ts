import {
  createPublicClient,
  createWalletClient,
  http,
  type PublicClient,
  type WalletClient,
  type Address,
  type Chain,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { CONFIG } from './config.js';

// ─── Hydration chain definition ──────────────────────────────────────────────

const hydration: Chain = {
  id: 222222,
  name: 'Hydration',
  nativeCurrency: { name: 'HDX', symbol: 'HDX', decimals: 18 },
  rpcUrls: {
    default: { http: [CONFIG.RPC_URL] },
  },
};

// ─── ABIs (only what the maintainer touches) ─────────────────────────────────

const SUBLOOP_ABI = [
  view('healthFactor', 'uint256'),
  view('targetHf', 'uint256'),
  view('deLeverTrigger', 'uint256'),
  nonpayable('pokeBorrow'), // permissionless ramp (lever one tranche)
  nonpayable('pokeRepay'), // permissionless unwind servicing
  nonpayable('deLever'), // permissionless safety de-lever
] as const;

const VAULT_ABI = [
  view('queueHead', 'uint256'),
  view('queueTail', 'uint256'),
  nonpayable('pokeSettle'), // settle the redeem queue
  nonpayable('rebalance'), // keep the LTV band
  nonpayable('maintainPeg'), // top up the synthetic floor
] as const;

const HARVESTER_ABI = [
  {
    name: 'harvest',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'minOuts', type: 'uint256[]' }],
    outputs: [],
  },
] as const;

const POOL_ABI = [
  {
    name: 'getUserAccountData',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'user', type: 'address' }],
    outputs: [
      { name: 'totalCollateralBase', type: 'uint256' },
      { name: 'totalDebtBase', type: 'uint256' },
      { name: 'availableBorrowsBase', type: 'uint256' },
      { name: 'currentLiquidationThreshold', type: 'uint256' },
      { name: 'ltv', type: 'uint256' },
      { name: 'healthFactor', type: 'uint256' },
    ],
  },
] as const;

function view(name: string, out: string) {
  return { name, type: 'function', stateMutability: 'view', inputs: [], outputs: [{ name: '', type: out }] } as const;
}
function nonpayable(name: string) {
  return { name, type: 'function', stateMutability: 'nonpayable', inputs: [], outputs: [] } as const;
}

const WAD = 10n ** 18n;

// ─── Maintainer ───────────────────────────────────────────────────────────────
//
// Permissionless keeper for the Propeller loop. Drives every now-open op:
//   fast (each cycle): pokeBorrow (ramp) · deLever (safety) · pokeRepay+pokeSettle
//                      (service withdrawals)
//   slow (every SLOW_EVERY): maintainPeg · rebalance · harvest
// Each op self-gates on-chain, so a skipped read only wastes gas, never misbehaves.
// Signs with a gas-only account — no role required (all targets are permissionless).

export class PropellerLooper {
  private publicClient: PublicClient;
  private walletClient: WalletClient;
  private account: ReturnType<typeof privateKeyToAccount>;
  private subLoop: Address;
  private vaults: Address[];
  private harvester: Address;
  private pool: Address;
  private cycle = 0;

  constructor() {
    this.account = privateKeyToAccount(CONFIG.PRIVATE_KEY);
    this.subLoop = CONFIG.SUBLOOP_ADDRESS;
    this.vaults = CONFIG.VAULT_ADDRESSES;
    this.harvester = CONFIG.HARVESTER_ADDRESS;
    this.pool = CONFIG.POOL_ADDRESS;

    this.publicClient = createPublicClient({ chain: hydration, transport: http(CONFIG.RPC_URL) });
    this.walletClient = createWalletClient({
      account: this.account,
      chain: hydration,
      transport: http(CONFIG.RPC_URL),
    });
  }

  async runCycle(): Promise<void> {
    this.cycle++;
    console.log(`\n[${new Date().toISOString()}] maintainer cycle #${this.cycle}`);

    const [hf, target, trigger] = (await Promise.all([
      this.read(SUBLOOP_ABI, this.subLoop, 'healthFactor'),
      this.read(SUBLOOP_ABI, this.subLoop, 'targetHf'),
      this.read(SUBLOOP_ABI, this.subLoop, 'deLeverTrigger'),
    ])) as [bigint, bigint, bigint];

    const leverage = await this.readLeverage();
    console.log(
      `  HF ${fmtHf(hf)} → target ${fmtHf(target)}` +
        (leverage !== null ? `   leverage ${leverage.toFixed(2)}×` : ''),
    );

    // ── fast: ramp / safety ────────────────────────────────────────────
    // delever only if HF fell BELOW the floor (genuinely under-collateralised);
    // never during the normal ramp (pokeBorrow stops at the floor). deLever is a
    // stub today — calling it is a safe no-op until its spiral is implemented.
    if (hf < target) {
      await this.poke(SUBLOOP_ABI, this.subLoop, 'deLever', 'deLever (HF below floor)');
    } else if (hf > (target * BigInt(Math.floor((1 + CONFIG.RAMP_HF_BUFFER) * 1e6))) / 1_000_000n) {
      await this.poke(SUBLOOP_ABI, this.subLoop, 'pokeBorrow', 'pokeBorrow (ramp)');
    } else {
      console.log('  HF in band — no ramp.');
    }
    void trigger; // reserved for future deLever gating once implemented

    // ── fast: service withdrawals (only when a redeem queue is non-empty) ──
    // pokeRepay is on the SHARED SubLoop, so it fires at most once per cycle no
    // matter how many vaults have pending requests; pokeSettle is per-vault.
    const pending: Address[] = [];
    for (const vault of this.vaults) {
      const [head, tail] = (await Promise.all([
        this.read(VAULT_ABI, vault, 'queueHead'),
        this.read(VAULT_ABI, vault, 'queueTail'),
      ])) as [bigint, bigint];
      if (tail > head) pending.push(vault);
    }
    if (pending.length) {
      await this.poke(SUBLOOP_ABI, this.subLoop, 'pokeRepay', 'pokeRepay (free unwind equity)');
      for (const vault of pending) {
        await this.poke(VAULT_ABI, vault, 'pokeSettle', `pokeSettle ${short(vault)}`);
      }
    }

    // ── slow: peg / rebalance / harvest (self-gating no-ops) ────────────
    if (this.cycle % CONFIG.SLOW_EVERY === 0) {
      for (const vault of this.vaults) {
        await this.poke(VAULT_ABI, vault, 'maintainPeg', `maintainPeg ${short(vault)}`);
        await this.poke(VAULT_ABI, vault, 'rebalance', `rebalance ${short(vault)}`);
      }
      // harvest walks the Harvester's OWN vault registry and distributes to all
      // of them in one call — so it is once per cycle, not once per vault.
      if (this.harvester) {
        await this.poke(HARVESTER_ABI, this.harvester, 'harvest', 'harvest (skim+distribute)', [[]]);
      }
    }
  }

  private async readLeverage(): Promise<number | null> {
    try {
      const data = (await this.read(POOL_ABI, this.pool, 'getUserAccountData', [
        this.subLoop,
      ])) as readonly bigint[];
      const equity = data[0] - data[1];
      if (equity <= 0n) return null;
      return Number(data[0]) / Number(equity);
    } catch {
      return null;
    }
  }

  // ─── helpers ─────────────────────────────────────────────────────────

  private async read(
    abi: readonly unknown[],
    address: Address,
    functionName: string,
    args?: readonly unknown[],
  ): Promise<unknown> {
    return this.publicClient.readContract({
      address,
      abi: abi as any,
      functionName: functionName as any,
      args: args as any,
    });
  }

  /// simulate → send a permissionless poke; a benign revert (nothing to do /
  /// HealthyEnough / paused) is logged and skipped, never fatal.
  private async poke(
    abi: readonly unknown[],
    address: Address,
    functionName: string,
    label: string,
    args: readonly unknown[] = [],
  ): Promise<void> {
    try {
      const { request } = await this.publicClient.simulateContract({
        account: this.account,
        address,
        abi: abi as any,
        functionName: functionName as any,
        args: args as any,
      });
      const hash = await this.walletClient.writeContract({
        ...request,
        gasPrice: 1_500_000n,
        gas: 5_000_000n,
      } as any);
      console.log(`  ${label} → ${hash}`);
      await this.publicClient.waitForTransactionReceipt({ hash });
    } catch (err) {
      // simulate reverts on no-op/guarded paths — expected, just skip.
      console.log(`  ${label}: skipped (${shortErr(err)})`);
    }
  }
}

// ─── formatting ─────────────────────────────────────────────────────────────

function fmtHf(hf: bigint): string {
  if (hf > 1000n * WAD) return '∞';
  return (Number(hf) / 1e18).toFixed(3);
}

function short(addr: Address): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function shortErr(err: unknown): string {
  const m = (err as Error)?.message ?? String(err);
  const reason = m.match(/reason:\s*([^\n]+)/)?.[1] ?? m.split('\n')[0];
  return reason.slice(0, 80);
}
