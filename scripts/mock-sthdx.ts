// Deploy a MintableERC20 mock and inject its code at the stHDX substrate-dispatch address
// so Anvil fork tests can call ERC20 methods on stHDX.
import hre from "hardhat";

const STHDX_ADDRESS = "0x000000000000000000000000000000010000029e";

async function main() {
  const [signer] = await hre.ethers.getSigners();
  console.log("Deployer:", signer.address);

  // Deploy MintableERC20 with stHDX params
  const MintableERC20 = await hre.ethers.getContractFactory(
    "@aave/core-v3/contracts/mocks/tokens/MintableERC20.sol:MintableERC20"
  );
  const token = await MintableERC20.deploy("stHDX", "stHDX", 12);
  await token.deployed();
  console.log("MintableERC20 mock deployed at:", token.address);

  // Get the runtime bytecode
  const deployedBytecode = await hre.ethers.provider.getCode(token.address);
  console.log("Bytecode length:", (deployedBytecode.length - 2) / 2, "bytes");

  // Inject the bytecode at the stHDX substrate-dispatch address
  await hre.network.provider.send("anvil_setCode", [
    STHDX_ADDRESS,
    deployedBytecode,
  ]);
  console.log("Injected bytecode at stHDX address:", STHDX_ADDRESS);

  // Verify
  const stHdxCode = await hre.ethers.provider.getCode(STHDX_ADDRESS);
  console.log("stHDX now has code:", (stHdxCode.length - 2) / 2, "bytes");

  // Verify decimals()
  const stHdx = MintableERC20.attach(STHDX_ADDRESS);
  const decimals = await stHdx.decimals();
  console.log("stHDX decimals:", decimals);

  // Mint 1M stHDX to deployer for supply testing
  const mintAmount = hre.ethers.utils.parseUnits("1000000", 12);
  // Mock: set balance directly via storage manipulation since we can't call mint
  // (the proxy address state won't have the right mappings)
  // Just log — minting via cheat not strictly needed for initReserves
  console.log("Done. stHDX mock is ready.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
