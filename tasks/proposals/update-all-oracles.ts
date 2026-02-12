// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
} from '../../helpers/hydration-proposal.js'
import { task } from 'hardhat/config'
import { getBatch, clearBatch } from '../../helpers/transaction-batch'
import ProposalDecoder from '../../helpers/proposal-decoder'
import chalk from 'chalk'
import { exit } from 'process'
import {
  FORK,
  POOL_ADMIN,
  getPoolAddressesProvider,
  getACLManager,
} from '../../helpers'
import {
  ConfigNames,
  getChainlinkOracles,
  getReserveAddresses,
  loadPoolConfig,
} from '../../helpers/market-config-helpers'
import { ORACLE_ID } from '../../helpers/deploy-ids'
import { MARKET_NAME } from '../../helpers/env'
import { addTransaction } from '../../helpers/transaction-batch'
import fs from 'fs'
import path from 'path'

task(
  `update-all-oracles`,
  `Compare on-chain oracle sources with config and generate proposal for differences`,
).setAction(async function (_, hre) {
  const { deployments } = hre
  const networkId = FORK ? FORK : hre.network.name
  const admin = POOL_ADMIN[networkId]
  const signer = await hre.ethers.getSigner(admin)
  const poolAddressesProvider = await getPoolAddressesProvider()
  const aclManager = (
    await getACLManager(await poolAddressesProvider.getACLManager())
  ).connect(signer)
  const isPoolAdmin = await aclManager.isPoolAdmin(admin)

  if (!isPoolAdmin) {
    console.error(chalk.red(`not pool admin ${admin}`))
    exit(1)
  }

  // --- Step 1: Load config ---
  console.log(chalk.blue('=== Step 1: Loading market config ==='))
  const poolConfig = await loadPoolConfig(MARKET_NAME as ConfigNames)

  const reservesAddresses = await getReserveAddresses(poolConfig, networkId)
  const chainlinkAggregators = await getChainlinkOracles(poolConfig, networkId)

  console.log(
    `  Found ${Object.keys(chainlinkAggregators).length} oracle configs`,
  )
  console.log(
    `  Found ${Object.keys(reservesAddresses).length} reserve addresses`,
  )

  // --- Step 2: Read on-chain state and diff ---
  console.log(chalk.blue('\n=== Step 2: Comparing on-chain vs config ==='))

  const oracleArtifactPath = path.join(
    process.cwd(),
    'deployments',
    'hydration',
    `${ORACLE_ID}.json`,
  )
  if (!fs.existsSync(oracleArtifactPath)) {
    console.error(
      chalk.red(`AaveOracle artifact not found at ${oracleArtifactPath}`),
    )
    exit(1)
  }
  const oracleArtifact = JSON.parse(
    fs.readFileSync(oracleArtifactPath, 'utf-8'),
  )
  const oracle = await hre.ethers.getContractAt(
    oracleArtifact.abi,
    oracleArtifact.address,
  )

  const assetsToUpdate: string[] = []
  const sourcesToUpdate: string[] = []

  for (const [symbol, configSource] of Object.entries(chainlinkAggregators)) {
    const tokenAddr = reservesAddresses[symbol]
    if (!tokenAddr) {
      console.log(chalk.yellow(`  ${symbol}: no reserve address, skipping`))
      continue
    }

    const onChainSource = await oracle.getSourceOfAsset(tokenAddr)
    const configSourceNorm = (configSource as string).toLowerCase()
    const onChainSourceNorm = onChainSource.toLowerCase()

    if (configSourceNorm === onChainSourceNorm) {
      console.log(chalk.gray(`  ${symbol}: unchanged (${onChainSource})`))
    } else {
      console.log(
        chalk.green(
          `  ${symbol}: CHANGED\n    on-chain: ${onChainSource}\n    config:   ${configSource}`,
        ),
      )
      assetsToUpdate.push(tokenAddr)
      sourcesToUpdate.push(configSource as string)
    }
  }

  if (assetsToUpdate.length === 0) {
    console.log(chalk.green('\nAll oracle sources are up to date!'))
    return
  }

  console.log(
    chalk.blue(`\n${assetsToUpdate.length} oracle source(s) to update`),
  )

  console.log(chalk.blue('\n=== Step 3: Generating proposal ==='))

  clearBatch()

  const oracleWithSigner = oracle.connect(signer)
  const tx = await oracleWithSigner.populateTransaction.setAssetSources(
    assetsToUpdate,
    sourcesToUpdate,
  )
  addTransaction(tx)

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin })),
  )

  let preimage = await generateProposalV2(txs, false)
  const decoder = new ProposalDecoder(hre)
  await decoder.init()
  console.log('preimage:')
  console.log(preimage.toHex())
  decoder.printTree(decoder.transformCall(preimage.toHuman()))
  console.log('hash:')
  console.log(preimage.hash.toHex())
  let { proposal } = await generateProposalV2(txs, true)
  console.log('proposal:')
  console.log(proposal.toHex())
  decoder.printTree(decoder.transformCall(proposal.toHuman()))
  console.log('proposal hash:')
  console.log(proposal.hash.toHex())
})
