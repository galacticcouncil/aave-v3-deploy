import 'dotenv/config'
import { spawnSync } from 'child_process'
import fs from 'fs'
import path from 'path'
import { tokenAddress } from '../markets/hydration/helpers'

// eslint-disable-next-line @typescript-eslint/no-var-requires
const { utils } = require('ethers')

const DEFAULT_MAX_DIFF_BPS = 500

const ORACLE_CONFIGS = [
  {
    name: '2-POOL-GDOT',
    assetId: 690,
    primaryFeed: '0xedbD21F476039C6019d2EC3e97f949af98a5c121',
    secondaryFeed: '0x00000102737461626c657377000003e9000002b2',
  },
  {
    name: 'VDOT',
    assetId: 15,
    primaryFeed: '0x2fFa376E0a84606e4Ccb3738071312A34Cebad6C',
    secondaryFeed: '0x00000102626966726f73746f000000050000000f',
  },
  {
    name: 'HDX',
    assetId: 0,
    primaryFeed: '0xea63e594ee00590938E856F2134E6C792bA92d13',
    secondaryFeed: '0x0000010200000000000000000000000a00000000',
  },
  {
    name: 'BNC',
    assetId: 14,
    primaryFeed: '0xc94c414E8eBF7EA928D9bE555A8eAb719B89bBcE',
    secondaryFeed: '0x0000010200000000000000000000000a0000000e',
  },
  {
    name: '2-POOL-GETH',
    assetId: 4200,
    primaryFeed: '0x32CC29cA6924B16077056A7B049663AF153D9E90',
    secondaryFeed: '0x00000102737461626c657377000003ef00001068',
  },
  {
    name: '3-POOL',
    assetId: 103,
    primaryFeed: '0xFbD6F083b9e8683fe62B21cF5849f362238610AF',
    secondaryFeed: '0x00000102737461626c657377000003ea00000067',
  },
  // === Assets WITHOUT USDOracleAdapter (primary = secondary) ===
  {
    name: 'USDC',
    assetId: 22,
    primaryFeed: '0x17711BE5D63B2Fe8A2C379725DE720773158b954',
    secondaryFeed: '0x17711BE5D63B2Fe8A2C379725DE720773158b954',
  },
  {
    name: 'USDT',
    assetId: 10,
    primaryFeed: '0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B',
    secondaryFeed: '0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B',
  },
  {
    name: 'WETH',
    assetId: 20,
    primaryFeed: '0x8aEAE0bBf623B0E70732086B8D48A6090C311596',
    secondaryFeed: '0x8aEAE0bBf623B0E70732086B8D48A6090C311596',
  },
  {
    name: 'WBTC',
    assetId: 19,
    primaryFeed: '0xeDD9A7C47A9F91a0F2db93978A88844167B4a04f',
    secondaryFeed: '0xeDD9A7C47A9F91a0F2db93978A88844167B4a04f',
  },
  {
    name: 'DOT',
    assetId: 5,
    primaryFeed: '0xFBCa0A6dC5B74C042DF23025D99ef0F1fcAC6702',
    secondaryFeed: '0xFBCa0A6dC5B74C042DF23025D99ef0F1fcAC6702',
  },
  {
    name: 'TBTC',
    assetId: 1000765,
    primaryFeed: '0xe5AcDfB0d5EC5cE34F7448B41ef4a97c4e83D9c1',
    secondaryFeed: '0xe5AcDfB0d5EC5cE34F7448B41ef4a97c4e83D9c1',
  },
  {
    name: 'ETH',
    assetId: 34,
    primaryFeed: '0x1AF549Fe19A9B73D094173C41e18BF7F357F594b',
    secondaryFeed: '0x1AF549Fe19A9B73D094173C41e18BF7F357F594b',
  },
  {
    name: 'WSTETH',
    assetId: 1000809,
    primaryFeed: '0x52bBB0BC38C42D60b24EBF0C617E8218D2aB6d36',
    secondaryFeed: '0x52bBB0BC38C42D60b24EBF0C617E8218D2aB6d36',
  },
  {
    name: 'WSTETH_ETH',
    assetId: 1000809, // same underlying token as WSTETH
    primaryFeed: '0xA317cEbdE7F948e132fDD177E5002A1DD2C2cB21',
    secondaryFeed: '0xA317cEbdE7F948e132fDD177E5002A1DD2C2cB21',
  },
  {
    name: '2-POOL-HUSDC',
    assetId: 110,
    primaryFeed: '0x00000102737461626c657377000000de0000006e',
    secondaryFeed: '0x00000102737461626c657377000000de0000006e',
  },
  {
    name: '2-POOL-HUSDT',
    assetId: 111,
    primaryFeed: '0x00000102737461626c657377000000de0000006f',
    secondaryFeed: '0x00000102737461626c657377000000de0000006f',
  },
  {
    name: '2-POOL-HUSDS',
    assetId: 112,
    primaryFeed: '0x00000102737461626c657377000000de00000070',
    secondaryFeed: '0x00000102737461626c657377000000de00000070',
  },
  {
    name: '2-POOL-HUSDE',
    assetId: 113,
    primaryFeed: '0x00000102737461626c657377000000de00000071',
    secondaryFeed: '0x00000102737461626c657377000000de00000071',
  },
  {
    name: 'PAXG',
    assetId: 39,
    primaryFeed: '0x8fB61B8E81C2f17695F14A136C98b0C4013bc105',
    secondaryFeed: '0x8fB61B8E81C2f17695F14A136C98b0C4013bc105',
  },
]

function generateSalt(name: string): string {
  return utils.keccak256(utils.toUtf8Bytes(`ClampedOracle_${name}_v1`))
}

function deployOracle(
  config: (typeof ORACLE_CONFIGS)[0],
  rpcUrl: string,
  privateKey: string,
): string | null {
  const salt = generateSalt(config.name)

  console.log(`\n--- Deploying ${config.name} ---`)
  console.log(`  Primary: ${config.primaryFeed}`)
  console.log(`  Secondary: ${config.secondaryFeed}`)
  console.log(`  Salt: ${salt}`)

  const scriptTarget =
    'deploy/foundry/DeployAllClampedOracles.s.sol:DeployAllClampedOracles'

  const forgeArgs = [
    'script',
    scriptTarget,
    '--rpc-url',
    rpcUrl,
    '--private-key',
    privateKey,
    '--broadcast',
    '-vvv',
  ]

  const res = spawnSync('forge', forgeArgs, {
    cwd: process.cwd(),
    env: {
      ...process.env,
      DEPLOYER_PRIVATE_KEY: privateKey,
      PRIMARY_FEED: config.primaryFeed,
      SECONDARY_FEED: config.secondaryFeed,
      MAX_DIFF_BPS: DEFAULT_MAX_DIFF_BPS.toString(),
      SALT: salt,
    },
    encoding: 'utf-8',
  })

  const output = (res.stdout || '') + (res.stderr || '')
  console.log(output)

  if (res.status !== 0) {
    console.error(`Failed to deploy ${config.name}`)
    return null
  }

  // Parse deployed address from output
  const match = output.match(/JSON_OUTPUT:\s+(0x[a-fA-F0-9]{40})/)
  if (match) {
    return match[1]
  }

  console.error(`Could not parse deployed address for ${config.name}`)
  return null
}

async function main() {
  const rpcUrl = process.env.RPC_URL!
  const privateKey = process.env.DEPLOYER_PRIVATE_KEY!

  if (!rpcUrl || !privateKey) {
    throw new Error('RPC_URL and DEPLOYER_PRIVATE_KEY must be set')
  }

  console.log('Deploying all ClampedOracles...')
  console.log(`Total oracles to deploy: ${ORACLE_CONFIGS.length}`)

  const deployedAddresses: Record<
    string,
    {
      address: string | null
      token: string
      primaryFeed: string
      secondaryFeed: string
    }
  > = {}

  for (const config of ORACLE_CONFIGS) {
    const address = deployOracle(config, rpcUrl, privateKey)
    deployedAddresses[config.name] = {
      address,
      token: tokenAddress(config.assetId),
      primaryFeed: config.primaryFeed,
      secondaryFeed: config.secondaryFeed,
    }
  }

  const deploymentsDir = path.join(process.cwd(), 'deployments', 'hydration')
  fs.mkdirSync(deploymentsDir, { recursive: true })

  const outputPath = path.join(deploymentsDir, 'clamped-oracles.json')
  const jsonOutput = {
    network: 'hydration',
    deployedAt: new Date().toISOString(),
    maxDiffBps: DEFAULT_MAX_DIFF_BPS,
    oracles: deployedAddresses,
  }

  fs.writeFileSync(outputPath, JSON.stringify(jsonOutput, null, 2))
  console.log(`\n-------------------------------------------`)
  console.log(`Deployment addresses saved to: ${outputPath}`)
  console.log(JSON.stringify(jsonOutput, null, 2))

  const successful = Object.values(deployedAddresses).filter(
    (v) => v.address !== null,
  ).length
  const failed = Object.values(deployedAddresses).filter(
    (v) => v.address === null,
  ).length
  console.log(`\nSummary: ${successful} deployed, ${failed} failed`)

  if (failed > 0) {
    console.error('Some oracles failed to deploy. Skipping config update.')
    return
  }
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
