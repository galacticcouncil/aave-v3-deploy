// @ts-nocheck
import { generateProposalV2 } from "../../helpers/hydration-proposal.js";
import { aaveManagerCall } from "../../helpers/lark-proposal.js";
import { task } from "hardhat/config";
import {
  addTransaction,
  getBatch,
  clearBatch,
} from "../../helpers/transaction-batch";
import ProposalDecoder from "../../helpers/proposal-decoder";
import chalk from "chalk";
import { exit } from "process";
import {
  FORK,
  POOL_ADMIN,
  getPoolAddressesProvider,
  getACLManager,
} from "../../helpers";
import { ORACLE_ID } from "../../helpers/deploy-ids";
import fs from "fs";
import path from "path";

// --- Hardcoded swap inputs ---
// PRIME asset on Hydration: assetId 43 -> tokenAddress(43).
const PRIME_TOKEN = "0x000000000000000000000000000000010000002b";
// Current source on AaveOracle (the original PRIMEoracle ManagedOracle).
const OLD_SOURCE = "0xDEe587cC569bf1FcBdcD6d1472031d225f34C307";
// New source: ClampedOracle(MRL primary, PRIME/HOLLAR 1-day EMA secondary, 200 bps).
// NOTE: the 0x166f… wrapper below was deployed against the WRONG secondary (the
// 2-Pool-PRIME LP-share feed, see EXPECTED_SECONDARY note). It MUST be redeployed
// via `deploy-clamped-oracle` with the corrected secondary, then this address
// replaced. Until then the secondary() sanity-check below will (by design) reject
// the stale wrapper and refuse to build the swap.
const NEW_SOURCE = "0x166f286745171D58B6b16E6020f7e48246c816E3"; // STALE — redeploy
const EXPECTED_PRIMARY = "0x82022F77ae239Ad99bB1F2aC0d8DaFF6Cc976a07";
// Secondary = routed/Omnipool Day (1-day) EMA, PRIME(43) priced in HOLLAR(222):
// returns value(PRIME)/value(HOLLAR) ≈ 1.0457. Format is
// 000001 | 04 (Day period) | <8-byte zero source> | 000000de (HOLLAR 222) | 0000002b (PRIME 43).
// Previously 0x00000102737461626c6573770000008f0000002b = stablesw(143, 43), i.e. the
// 2-Pool-PRIME LP-share token priced in PRIME (≈1.0286) — the wrong ratio; HOLLAR (222)
// was absent entirely. (stablesw prices share tokens only, so the corrected feed uses
// the routed/Omnipool source, matching the config's member-vs-member feeds.)
const EXPECTED_SECONDARY = "0x000001040000000000000000000000de0000002b";
const EXPECTED_MAX_DIFF_BPS = 200;

task(
  `swap-prime-oracle`,
  `Swap PRIME's source on AaveOracle from the raw MRL pointer to the ClampedOracle wrapper`
).setAction(async function (_, hre) {
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const signer = await hre.ethers.getSigner(admin);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const aclManager = (
    await getACLManager(await poolAddressesProvider.getACLManager())
  ).connect(signer);
  const isPoolAdmin = await aclManager.isPoolAdmin(admin);

  if (!isPoolAdmin) {
    console.error(chalk.red(`not pool admin ${admin}`));
    exit(1);
  }

  console.log(chalk.blue("=== Sanity-checking the new oracle ==="));

  // 1. Wrapper has code.
  const code = await hre.ethers.provider.getCode(NEW_SOURCE);
  if (code === "0x" || code.length < 4) {
    console.error(chalk.red(`No code at NEW_SOURCE ${NEW_SOURCE}`));
    exit(1);
  }

  const wrapper = new hre.ethers.Contract(
    NEW_SOURCE,
    [
      "function primary() view returns (address)",
      "function secondary() view returns (address)",
      "function maxDiffBps() view returns (uint256)",
      "function latestAnswer() view returns (int256)",
      "function decimals() view returns (uint8)",
    ],
    hre.ethers.provider
  );

  // 2. Wrapper is configured as expected.
  const [primary, secondary, maxDiffBps, decimals, latestAnswer] =
    await Promise.all([
      wrapper.primary(),
      wrapper.secondary(),
      wrapper.maxDiffBps(),
      wrapper.decimals(),
      wrapper.latestAnswer(),
    ]);

  if (primary.toLowerCase() !== EXPECTED_PRIMARY.toLowerCase()) {
    console.error(
      chalk.red(
        `Wrapper primary mismatch: got ${primary}, expected ${EXPECTED_PRIMARY}`
      )
    );
    exit(1);
  }
  if (secondary.toLowerCase() !== EXPECTED_SECONDARY.toLowerCase()) {
    console.error(
      chalk.red(
        `Wrapper secondary mismatch: got ${secondary}, expected ${EXPECTED_SECONDARY}`
      )
    );
    exit(1);
  }
  if (maxDiffBps.toNumber() !== EXPECTED_MAX_DIFF_BPS) {
    console.error(
      chalk.red(
        `Wrapper maxDiffBps mismatch: got ${maxDiffBps.toString()}, expected ${EXPECTED_MAX_DIFF_BPS}`
      )
    );
    exit(1);
  }
  if (decimals !== 8) {
    console.error(
      chalk.red(`Wrapper decimals mismatch: got ${decimals}, expected 8`)
    );
    exit(1);
  }
  if (latestAnswer.lte(0)) {
    console.error(
      chalk.red(
        `Wrapper latestAnswer is non-positive: ${latestAnswer.toString()}`
      )
    );
    exit(1);
  }

  console.log(
    chalk.green(
      `  wrapper ok -- primary=${primary} secondary=${secondary} bps=${maxDiffBps} answer=${latestAnswer.toString()}`
    )
  );

  console.log(chalk.blue("\n=== Verifying current on-chain source ==="));

  const oracleArtifactPath = path.join(
    process.cwd(),
    "deployments",
    "hydration",
    `${ORACLE_ID}.json`
  );
  if (!fs.existsSync(oracleArtifactPath)) {
    console.error(
      chalk.red(`AaveOracle artifact not found at ${oracleArtifactPath}`)
    );
    exit(1);
  }
  const oracleArtifact = JSON.parse(
    fs.readFileSync(oracleArtifactPath, "utf-8")
  );
  const aaveOracle = await hre.ethers.getContractAt(
    oracleArtifact.abi,
    oracleArtifact.address
  );

  const currentSource = await aaveOracle.getSourceOfAsset(PRIME_TOKEN);
  if (currentSource.toLowerCase() === NEW_SOURCE.toLowerCase()) {
    console.log(
      chalk.yellow(
        `  on-chain source already equals ${NEW_SOURCE} -- nothing to do`
      )
    );
    return;
  }
  if (currentSource.toLowerCase() !== OLD_SOURCE.toLowerCase()) {
    console.log(
      chalk.yellow(
        `  warning: current source ${currentSource} differs from expected old ${OLD_SOURCE}`
      )
    );
  } else {
    console.log(chalk.gray(`  current source: ${currentSource}`));
  }
  console.log(chalk.gray(`  new source:     ${NEW_SOURCE}`));

  console.log(chalk.blue("\n=== Building proposal ==="));

  clearBatch();
  const oracleWithSigner = aaveOracle.connect(signer);
  const tx = await oracleWithSigner.populateTransaction.setAssetSources(
    [PRIME_TOKEN],
    [NEW_SOURCE]
  );
  addTransaction(tx);

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );

  const decoder = new ProposalDecoder(hre);
  await decoder.init();

  const preimage = await generateProposalV2(txs, false);
  console.log("preimage:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
  console.log("preimage hash:");
  console.log(preimage.hash.toHex());

  const { proposal } = await generateProposalV2(txs, true);
  console.log("\nproposal:");
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
  console.log("proposal hash:");
  console.log(proposal.hash.toHex());
});
