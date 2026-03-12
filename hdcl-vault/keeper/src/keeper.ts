import {
  createPublicClient,
  createWalletClient,
  http,
  type PublicClient,
  type WalletClient,
  type Address,
  type Chain,
  formatEther,
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

// ─── NFTState enum (must match Solidity) ─────────────────────────────────────

const NFTState = {
  Active: 0,
  YieldWithdrawalRequested: 1,
  YieldClaimed: 2,
  PrincipalWithdrawalRequested: 3,
  Redeemed: 4,
} as const;

// ─── Vault ABI (only the functions the keeper needs) ─────────────────────────

const VAULT_ABI = [
  {
    name: 'getPositionCount',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'getPositionHead',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'getPosition',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'positionIndex', type: 'uint256' }],
    outputs: [
      { name: 'tokenId', type: 'uint256' },
      { name: 'principal', type: 'uint256' },
      { name: 'apyWad', type: 'uint256' },
      { name: 'depositTime', type: 'uint256' },
      { name: 'maturityTime', type: 'uint256' },
      { name: 'state', type: 'uint8' },
    ],
  },
  {
    name: 'idleHollar',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'totalQueuedHdcl',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'minReinvestAmount',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'processPosition',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'positionIndex', type: 'uint256' }],
    outputs: [],
  },
  {
    name: 'processQueue',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [],
    outputs: [],
  },
  {
    name: 'reinvest',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [],
    outputs: [],
  },
  {
    name: 'exchangeRate',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'totalAssets',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const;

// ─── Keeper class ────────────────────────────────────────────────────────────

export class HDCLKeeper {
  private publicClient: PublicClient;
  private walletClient: WalletClient;
  private account: ReturnType<typeof privateKeyToAccount>;
  private vaultAddress: Address;

  constructor() {
    this.account = privateKeyToAccount(CONFIG.PRIVATE_KEY);
    this.vaultAddress = CONFIG.VAULT_ADDRESS;

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
    const now = Math.floor(Date.now() / 1000);
    console.log(`\n[${new Date().toISOString()}] Running keeper cycle...`);

    // 1. Read vault state
    const [positionCount, positionHead, idleHollar, totalQueuedHdcl, minReinvestAmount] =
      await Promise.all([
        this.readContract('getPositionCount'),
        this.readContract('getPositionHead'),
        this.readContract('idleHollar'),
        this.readContract('totalQueuedHdcl'),
        this.readContract('minReinvestAmount'),
      ]);

    console.log(`  Positions: ${positionCount} (head: ${positionHead})`);
    console.log(`  Idle HOLLAR: ${formatEther(idleHollar as bigint)}`);
    console.log(`  Queued HDCL: ${formatEther(totalQueuedHdcl as bigint)}`);

    // 2. Iterate positions and process any that should advance
    const count = Number(positionCount);
    const head = Number(positionHead);

    for (let i = head; i < count; i++) {
      try {
        await this.processPositionIfNeeded(i, now);
      } catch (err) {
        console.error(`  Error processing position ${i}:`, err);
      }
    }

    // 3. Re-read state after position processing (it may have changed)
    const [idleHollarAfter, totalQueuedHdclAfter] = await Promise.all([
      this.readContract('idleHollar'),
      this.readContract('totalQueuedHdcl'),
    ]);

    const idle = idleHollarAfter as bigint;
    const queued = totalQueuedHdclAfter as bigint;
    const minReinvest = minReinvestAmount as bigint;

    // 4. If idleHollar > 0 AND totalQueuedHdcl > 0 -> processQueue
    if (idle > 0n && queued > 0n) {
      try {
        console.log('  Calling processQueue()...');
        await this.writeContract('processQueue');
        console.log('  processQueue() succeeded');
      } catch (err) {
        console.error('  processQueue() failed:', err);
      }
    }

    // 5. If idleHollar >= minReinvestAmount AND totalQueuedHdcl == 0 -> reinvest
    if (idle >= minReinvest && queued === 0n) {
      try {
        console.log(`  Calling reinvest() with ${formatEther(idle)} idle HOLLAR...`);
        await this.writeContract('reinvest');
        console.log('  reinvest() succeeded');
      } catch (err) {
        console.error('  reinvest() failed:', err);
      }
    }

    console.log('  Cycle complete.');
  }

  // ─── Position processing ─────────────────────────────────────────────

  private async processPositionIfNeeded(index: number, nowSeconds: number): Promise<void> {
    const position = (await this.readContract('getPosition', [BigInt(index)])) as [
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
      number,
    ];

    const [tokenId, principal, , , maturityTime, state] = position;

    // Skip redeemed positions
    if (state === NFTState.Redeemed) return;

    const maturity = Number(maturityTime);

    // Active + matured -> should process
    if (state === NFTState.Active && nowSeconds >= maturity) {
      console.log(`  Position ${index} (token ${tokenId}): Active & matured, calling processPosition()...`);
      await this.tryProcessPosition(index);

      // Check for stale: > 96 hours past maturity
      const staleCutoff = maturity + CONFIG.STALE_THRESHOLD_SECONDS;
      if (nowSeconds > staleCutoff) {
        console.warn(
          `  WARNING: Position ${index} is ${Math.floor((nowSeconds - maturity) / 3600)}h past maturity!`
        );
        await this.sendAlert(
          `Stale position detected: index=${index}, tokenId=${tokenId}, ` +
            `principal=${formatEther(principal)}, ` +
            `hours past maturity: ${Math.floor((nowSeconds - maturity) / 3600)}`
        );
      }
      return;
    }

    // In any intermediate withdrawal state -> try to advance
    if (
      state === NFTState.YieldWithdrawalRequested ||
      state === NFTState.YieldClaimed ||
      state === NFTState.PrincipalWithdrawalRequested
    ) {
      const stateNames = ['Active', 'YieldWithdrawalRequested', 'YieldClaimed', 'PrincipalWithdrawalRequested'];
      console.log(
        `  Position ${index} (token ${tokenId}): state=${stateNames[state]}, calling processPosition()...`
      );
      await this.tryProcessPosition(index);

      // Check for stale: > 96 hours past maturity without fully progressing
      const staleCutoff = maturity + CONFIG.STALE_THRESHOLD_SECONDS;
      if (nowSeconds > staleCutoff) {
        console.warn(
          `  WARNING: Position ${index} stuck in state ${stateNames[state]} for ` +
            `${Math.floor((nowSeconds - maturity) / 3600)}h past maturity`
        );
        await this.sendAlert(
          `Stuck position: index=${index}, tokenId=${tokenId}, state=${stateNames[state]}, ` +
            `principal=${formatEther(principal)}, ` +
            `hours past maturity: ${Math.floor((nowSeconds - maturity) / 3600)}`
        );
      }
      return;
    }
  }

  private async tryProcessPosition(index: number): Promise<void> {
    try {
      await this.writeContract('processPosition', [BigInt(index)]);
      console.log(`    processPosition(${index}) succeeded`);
    } catch (err) {
      // Expected: Decentral may not have approved the withdrawal yet
      console.log(`    processPosition(${index}) reverted (may need Decentral approval)`);
    }
  }

  // ─── Contract helpers ────────────────────────────────────────────────

  private async readContract(functionName: string, args?: readonly unknown[]): Promise<unknown> {
    return this.publicClient.readContract({
      address: this.vaultAddress,
      abi: VAULT_ABI,
      functionName,
      args: args as any,
    });
  }

  private async writeContract(functionName: string, args?: readonly unknown[]): Promise<void> {
    const { request } = await this.publicClient.simulateContract({
      account: this.account,
      address: this.vaultAddress,
      abi: VAULT_ABI,
      functionName,
      args: args as any,
    });
    const hash = await this.walletClient.writeContract(request as any);
    console.log(`    tx: ${hash}`);
    await this.publicClient.waitForTransactionReceipt({ hash });
  }

  // ─── Alerting ────────────────────────────────────────────────────────

  private async sendAlert(message: string): Promise<void> {
    if (!CONFIG.ALERT_WEBHOOK) return;

    try {
      await fetch(CONFIG.ALERT_WEBHOOK, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text: `[HDCL Keeper] ${message}`,
          timestamp: new Date().toISOString(),
        }),
      });
    } catch (err) {
      console.error('  Failed to send alert:', err);
    }
  }
}
