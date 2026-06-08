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

// ─── ABIs (only what the looper touches) ─────────────────────────────────────

const SUBLOOP_ABI = [
  {
    name: 'healthFactor',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'targetHf',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  // permissionless ramp step — borrows one HF-bounded, tranche-capped slice and
  // levers it in synchronously. No-ops (Borrowed(0)) once HF is at the floor.
  {
    name: 'pokeBorrow',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [],
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

const WAD = 10n ** 18n;

// ─── Looper class ─────────────────────────────────────────────────────────────

export class PropellerLooper {
  private publicClient: PublicClient;
  private walletClient: WalletClient;
  private account: ReturnType<typeof privateKeyToAccount>;
  private subLoop: Address;
  private pool: Address;

  constructor() {
    this.account = privateKeyToAccount(CONFIG.PRIVATE_KEY);
    this.subLoop = CONFIG.SUBLOOP_ADDRESS;
    this.pool = CONFIG.POOL_ADDRESS;

    this.publicClient = createPublicClient({
      chain: hydration,
      transport: http(CONFIG.RPC_URL),
    });

    this.walletClient = createWalletClient({
      account: this.account,
      chain: hydration,
      transport: http(CONFIG.RPC_URL),
    });
  }

  // ─── Main cycle ──────────────────────────────────────────────────────

  async runCycle(): Promise<void> {
    console.log(`\n[${new Date().toISOString()}] Running looper cycle...`);

    const [hf, target] = (await Promise.all([
      this.read(SUBLOOP_ABI, this.subLoop, 'healthFactor'),
      this.read(SUBLOOP_ABI, this.subLoop, 'targetHf'),
    ])) as [bigint, bigint];

    const leverage = await this.readLeverage();
    console.log(
      `  HF ${fmtHf(hf)} → target ${fmtHf(target)}` +
        (leverage !== null ? `   leverage ${leverage.toFixed(2)}×` : ''),
    );

    // idle once HF is within RAMP_HF_BUFFER above target. deployHfFloor == target,
    // so borrowing below this would just no-op and burn gas.
    const bufferBps = BigInt(Math.floor((1 + CONFIG.RAMP_HF_BUFFER) * 1e6));
    const idleThreshold = (target * bufferBps) / 1_000_000n;
    if (hf <= idleThreshold) {
      console.log('  at/near target — idle.');
      return;
    }

    // ramp one tranche toward target.
    try {
      console.log('  pokeBorrow() — levering one tranche...');
      await this.write(SUBLOOP_ABI, this.subLoop, 'pokeBorrow');
      const hfAfter = (await this.read(
        SUBLOOP_ABI,
        this.subLoop,
        'healthFactor',
      )) as bigint;
      console.log(`  pokeBorrow() succeeded — HF now ${fmtHf(hfAfter)}`);
    } catch (err) {
      console.error('  pokeBorrow() failed:', err);
      await this.sendAlert(
        `pokeBorrow() reverted on SubLoop ${this.subLoop}: ${String(err).slice(0, 300)}`,
        'error',
      );
    }
  }

  // ─── Leverage read (collateral / equity) ─────────────────────────────

  private async readLeverage(): Promise<number | null> {
    try {
      const data = (await this.read(POOL_ABI, this.pool, 'getUserAccountData', [
        this.subLoop,
      ])) as readonly bigint[];
      const coll = data[0];
      const debt = data[1];
      const equity = coll - debt;
      if (equity <= 0n) return null;
      return Number(coll) / Number(equity);
    } catch {
      return null;
    }
  }

  // ─── Contract helpers ────────────────────────────────────────────────

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

  private async write(
    abi: readonly unknown[],
    address: Address,
    functionName: string,
    args?: readonly unknown[],
  ): Promise<void> {
    const { request } = await this.publicClient.simulateContract({
      account: this.account,
      address,
      abi: abi as any,
      functionName: functionName as any,
      args: args as any,
    });
    // Hydration requires legacy (type 0) transactions.
    const hash = await this.walletClient.writeContract({
      ...request,
      gasPrice: 1_500_000n,
      gas: 5_000_000n,
    } as any);
    console.log(`    tx: ${hash}`);
    await this.publicClient.waitForTransactionReceipt({ hash });
  }

  // ─── Alerting ────────────────────────────────────────────────────────

  private async sendAlert(
    message: string,
    level: 'warn' | 'error' = 'warn',
  ): Promise<void> {
    if (!CONFIG.ALERT_WEBHOOK) return;
    const color = level === 'error' ? 0xe74c3c : 0xf1c40f;
    try {
      await fetch(CONFIG.ALERT_WEBHOOK, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username: 'Propeller Looper',
          embeds: [
            {
              title:
                level === 'error'
                  ? 'Propeller Looper — error'
                  : 'Propeller Looper — warning',
              description: message,
              color,
              footer: { text: `SubLoop ${this.subLoop}` },
              timestamp: new Date().toISOString(),
            },
          ],
        }),
      });
    } catch (err) {
      console.error('  sendAlert failed:', err);
    }
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

// HF is WAD-scaled. With no debt Aave returns ~uint256.max, so cap the display.
function fmtHf(hf: bigint): string {
  if (hf > 1000n * WAD) return '∞';
  return (Number(hf) / 1e18).toFixed(3);
}
