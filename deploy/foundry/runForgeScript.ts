import { spawnSync } from 'child_process'
import path from 'path'

type RunForgeScriptArgs = {
  rpcUrl: string
  privateKey: string // EOA that will broadcast
  scriptPath: string // e.g. "aave-v3-deploy/deploy/foundry/DeployClampedOracle.s.sol"
  contractName: string // e.g. "DeployClampedOracle"
  env: Record<string, string> // PRIMARY_FEED, SECONDARY_FEED, etc.
  broadcast?: boolean // default true
  verify?: boolean // optional
}

export function runForgeScript(args: RunForgeScriptArgs) {
  const {
    rpcUrl,
    privateKey,
    scriptPath,
    contractName,
    env,
    broadcast = true,
    verify = false,
  } = args

  const cwd = process.cwd()

  const scriptTarget = `${scriptPath}:${contractName}`

  const forgeArgs = [
    'script',
    scriptTarget,
    '--rpc-url',
    rpcUrl,
    '--private-key',
    privateKey,
  ]

  if (broadcast) forgeArgs.push('--broadcast')
  forgeArgs.push('-vvv')

  if (verify) {
    // add your verifier options if you want (etherscan key etc.)
    // forgeArgs.push("--verify");
  }

  const childEnv = {
    ...process.env,
    ...env,
  }

  const res = spawnSync('forge', forgeArgs, {
    cwd,
    env: childEnv,
    stdio: 'inherit',
    shell: process.platform === 'win32',
  })

  if (res.status !== 0) {
    throw new Error(`forge script failed with exit code ${res.status}`)
  }
}
