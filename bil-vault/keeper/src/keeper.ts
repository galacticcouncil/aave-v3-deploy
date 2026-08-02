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
    name: 'totalQueuedBil',
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
    name: 'syncMaturities',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'maxPositions', type: 'uint256' }],
    outputs: [{ name: 'processed', type: 'uint256' }],
  },
  {
    name: 'pokeDecentral',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'positionIndex', type: 'uint256' }],
    outputs: [],
  },
  {
    name: 'pokeQueue',
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
  // ─── ERC-7540 redemption queue ───────────────────────────────────────
  {
    // renamed: the explicit getter was dropped for EIP-170 budget; the
    // public storage var's auto-getter is the canonical read now.
    name: 'queueTail',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'getRedemptionRequest',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'requestId', type: 'uint256' }],
    outputs: [
      { name: 'user', type: 'address' },
      { name: 'bilAmount', type: 'uint256' },
      { name: 'bilSettled', type: 'uint256' },
      { name: 'hollarOwed', type: 'uint256' },
      { name: 'active', type: 'bool' },
    ],
  },
  {
    name: 'autoClaimEnabled',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'controller', type: 'address' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    name: 'redeem',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'shares', type: 'uint256' },
      { name: 'receiver', type: 'address' },
      { name: 'controller', type: 'address' },
    ],
    outputs: [{ name: 'assets', type: 'uint256' }],
  },
] as const;

// ─── Keeper class ────────────────────────────────────────────────────────────

export class BILKeeper {
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

    // Keep maturity accounting current even while the vault is paused, when
    // pokeDecentral and pokeQueue are intentionally unavailable.
    await this.syncMaturitiesIfDue();

    // 1. Read vault state
    const [positionCount, positionHead, idleHollar, totalQueuedBil, minReinvestAmount] =
      await Promise.all([
        this.readContract('getPositionCount'),
        this.readContract('getPositionHead'),
        this.readContract('idleHollar'),
        this.readContract('totalQueuedBil'),
        this.readContract('minReinvestAmount'),
      ]);

    console.log(`  Positions: ${positionCount} (head: ${positionHead})`);
    console.log(`  Idle HOLLAR: ${formatEther(idleHollar as bigint)}`);
    console.log(`  Queued BIL: ${formatEther(totalQueuedBil as bigint)}`);

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
    const [idleHollarAfter, totalQueuedBilAfter] = await Promise.all([
      this.readContract('idleHollar'),
      this.readContract('totalQueuedBil'),
    ]);

    const idle = idleHollarAfter as bigint;
    const queued = totalQueuedBilAfter as bigint;
    const minReinvest = minReinvestAmount as bigint;

    // 4. pokeQueue handles both queue processing and reinvestment
    if ((idle > 0n && queued > 0n) || (idle >= minReinvest && queued === 0n)) {
      try {
        console.log(`  Calling pokeQueue() (idle=${formatEther(idle)}, queued=${formatEther(queued)})...`);
        await this.writeContract('pokeQueue');
        console.log('  pokeQueue() succeeded');
      } catch (err) {
        console.error('  pokeQueue() failed:', err);
      }
    }

    // 5. Auto-claim on behalf of opted-in controllers. Requires this keeper
    //    address to hold CLAIM_OPERATOR_ROLE on the vault. With pull-redemption,
    //    settled shares sit in totalReservedHollar until someone calls redeem();
    //    this step closes the loop for users who toggled setAutoClaim(true).
    await this.autoClaimSettled();

    console.log('  Cycle complete.');
  }

  private async syncMaturitiesIfDue(): Promise<void> {
    const batch = 50n;
    try {
      const { result } = await this.publicClient.simulateContract({
        account: this.account,
        address: this.vaultAddress,
        abi: VAULT_ABI,
        functionName: 'syncMaturities',
        args: [batch],
      });
      if ((result as bigint) === 0n) return;

      console.log(`  Synchronizing up to ${batch} matured positions...`);
      await this.writeContract('syncMaturities', [batch]);
    } catch (err) {
      console.error('  syncMaturities() failed:', err);
    }
  }

  // ─── Auto-claim for opted-in controllers ─────────────────────────────

  /// Walk the redemption queue, sum claimable shares per controller, and call
  /// `redeem(shares, controller, controller)` for those with autoClaim on.
  /// Receiver is forced to the controller — `CLAIM_OPERATOR_ROLE` only
  /// authorizes timing, not redirection.
  private async autoClaimSettled(): Promise<void> {
    const queueLen = (await this.readContract('queueTail')) as bigint;
    if (queueLen === 0n) return;

    // Sum settled shares per controller across all live requests.
    const claimable = new Map<Address, bigint>();
    for (let i = 0n; i < queueLen; i++) {
      const req = (await this.readContract('getRedemptionRequest', [i])) as [
        Address, bigint, bigint, bigint, boolean,
      ];
      const [user, , bilSettled, , active] = req;
      if (!active || bilSettled === 0n) continue;
      claimable.set(user, (claimable.get(user) ?? 0n) + bilSettled);
    }
    if (claimable.size === 0) return;

    // For each controller with claimable shares, check opt-in and call redeem.
    for (const [controller, shares] of claimable) {
      let optedIn = false;
      try {
        optedIn = (await this.readContract('autoClaimEnabled', [controller])) as boolean;
      } catch (err) {
        console.error(`  autoClaimEnabled(${controller}) failed:`, err);
        continue;
      }
      if (!optedIn) continue;

      try {
        console.log(`  Auto-claim: redeem(${formatEther(shares)} hDCL) for ${controller}`);
        await this.writeContract('redeem', [shares, controller, controller]);
      } catch (err) {
        // Could revert if the keeper isn't a CLAIM_OPERATOR_ROLE holder,
        // or if the controller flipped autoClaim off mid-cycle. Either way,
        // log and continue — don't block the rest of the batch.
        console.error(`  redeem for ${controller} failed:`, err);
      }
    }
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

      // Off-chain monitoring: alert if a position has been past maturity
      // for too long. There is no on-chain stale recognition path anymore —
      // try/catch + UUPS upgrade handles a broken Decentral pool. This alert
      // exists so an operator can investigate if a position is stuck.
      const cutoff = maturity + CONFIG.STALE_THRESHOLD_SECONDS;
      if (nowSeconds > cutoff) {
        const hours = Math.floor((nowSeconds - maturity) / 3600);
        console.warn(`  WARNING: Position ${index} is ${hours}h past maturity!`);
        await this.sendAlert(
          `Stuck position (Active past maturity): index=${index}, tokenId=${tokenId}, ` +
            `principal=${formatEther(principal)}, hours past maturity: ${hours}`
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

      // Off-chain monitoring (see comment above on the Active branch).
      const cutoff = maturity + CONFIG.STALE_THRESHOLD_SECONDS;
      if (nowSeconds > cutoff) {
        const hours = Math.floor((nowSeconds - maturity) / 3600);
        console.warn(
          `  WARNING: Position ${index} stuck in state ${stateNames[state]} for ${hours}h past maturity`
        );
        await this.sendAlert(
          `Stuck position: index=${index}, tokenId=${tokenId}, state=${stateNames[state]}, ` +
            `principal=${formatEther(principal)}, hours past maturity: ${hours}`
        );
      }
      return;
    }
  }

  private async tryProcessPosition(index: number): Promise<void> {
    try {
      await this.writeContract('pokeDecentral', [BigInt(index)]);
      console.log(`    pokeDecentral(${index}) succeeded`);
    } catch (err) {
      // Expected: Decentral may not have approved the withdrawal yet
      console.log(`    pokeDecentral(${index}) reverted (may need Decentral approval)`);
    }
  }

  // ─── Contract helpers ────────────────────────────────────────────────

  private async readContract(functionName: string, args?: readonly unknown[]): Promise<unknown> {
    return this.publicClient.readContract({
      address: this.vaultAddress,
      abi: VAULT_ABI,
      functionName: functionName as any,
      args: args as any,
    });
  }

  private async writeContract(functionName: string, args?: readonly unknown[]): Promise<void> {
    const { request } = await this.publicClient.simulateContract({
      account: this.account,
      address: this.vaultAddress,
      abi: VAULT_ABI,
      functionName: functionName as any,
      args: args as any,
    });
    // Hydration requires legacy (type 0) transactions
    const hash = await this.walletClient.writeContract({
      ...request,
      gasPrice: 1_500_000n,
      gas: 5_000_000n,
    } as any);
    console.log(`    tx: ${hash}`);
    await this.publicClient.waitForTransactionReceipt({ hash });
  }

  // ─── Alerting ────────────────────────────────────────────────────────

  /// Post a Discord webhook embed. `ALERT_WEBHOOK` is expected to be a
  /// Discord webhook URL (https://discord.com/api/webhooks/<id>/<token>).
  /// Levels map to standard embed colors so on-call can triage by sidebar
  /// stripe in the channel.
  private async sendAlert(message: string, level: 'warn' | 'error' = 'warn'): Promise<void> {
    if (!CONFIG.ALERT_WEBHOOK) return;

    const color = level === 'error'
      ? 0xE74C3C  // red
      : 0xF1C40F; // yellow

    try {
      await fetch(CONFIG.ALERT_WEBHOOK, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username: 'BIL Keeper',
          embeds: [
            {
              title: level === 'error' ? 'BIL Keeper — error' : 'BIL Keeper — warning',
              description: message,
              color,
              footer: { text: `Vault ${this.vaultAddress}` },
              timestamp: new Date().toISOString(),
            },
          ],
        }),
      });
    } catch (err) {
      console.error('  Failed to send alert:', err);
    }
  }
}
