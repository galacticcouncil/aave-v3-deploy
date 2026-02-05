import 'dotenv/config'
import hre from 'hardhat'
import { runForgeScript } from './foundry/runForgeScript'

async function main() {
  const network = hre.network.name

  const rpcUrl = process.env.RPC_URL!
  const privateKey = process.env.DEPLOYER_PRIVATE_KEY!

  const PRIMARY_FEED = process.env.PRIMARY_FEED!
  const SECONDARY_FEED = process.env.SECONDARY_FEED!
  const MAX_DIFF_BPS = process.env.MAX_DIFF_BPS!
  const SALT =
    process.env.SALT ??
    '0x0000000000000000000000000000000000000000000000000000000000000000'

  runForgeScript({
    rpcUrl,
    privateKey,
    scriptPath: 'deploy/foundry/DeployClampedOracle.s.sol',
    contractName: 'DeployClampedOracle',
    env: { PRIMARY_FEED, SECONDARY_FEED, MAX_DIFF_BPS, SALT },
    broadcast: true,
  })

  console.log(`Done (network=${network})`)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
