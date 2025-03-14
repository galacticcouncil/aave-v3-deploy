const { ethers } = require('ethers');

// Connect to your local node
const provider = new ethers.providers.JsonRpcProvider('http://localhost:9999');

// The contract address and function parameters from your error
const contractAddress = '0x112b087b60C1a166130d59266363C45F8aa99db0';
const assetAddress = '0xf3ba4d1b50f78301bdd7eaea9b67822a15fca691';

//Rename thus to assetAddress so it is used
const tbtcAddress = '0x69003a65189f6Ed993D3bD3E2B74f1Db39F405ce';

// This is a minimal ABI with just the function we're trying to call
// You might need to adjust the function name/signature based on the actual contract
const minimumABI = [
  // Try different function signatures that might match 0xec489c21
  "function getPool(address asset) view returns (address)",
  "function getReserveData(address asset) view returns (tuple)",
  "function getAssetData(address asset) view returns (tuple)",
  "function getLendingPool(address asset) view returns (address)",
  // Add any other potential functions that match the signature
];

async function debugPoolCall() {
  const ethers = require('ethers');

  const functionSignatures = [
    "getPool(address)",
    "getReserveData(address)",
    "getAssetData(address)",
    "getLendingPool(address)"
  ];
  
  functionSignatures.forEach(signature => {
    const selector = ethers.utils.id(signature).slice(0, 10);
    console.log(`${signature}: ${selector}`);
  });
  console.log('Starting debug...');
  console.log(`Contract: ${contractAddress}`);
  console.log(`Asset: ${assetAddress}`);
  
  // Check if the contract exists
  const code = await provider.getCode(contractAddress);
  if (code === '0x') {
    console.error('Contract does not exist at the specified address');
    return;
  }
  console.log('Contract exists ✓');
  
  // Check if the asset address exists
  const assetCode = await provider.getCode(assetAddress);
  console.log(`Asset contract exists: ${assetCode !== '0x'}`);
  
  // Try basic contract information (if it's a standard ERC20)
  try {
    const assetContract = new ethers.Contract(
      assetAddress,
      [
        "function name() view returns (string)",
        "function symbol() view returns (string)",
        "function decimals() view returns (uint8)"
      ],
      provider
    );
    
    const [name, symbol, decimals] = await Promise.all([
      assetContract.name().catch(() => 'N/A'),
      assetContract.symbol().catch(() => 'N/A'),
      assetContract.decimals().catch(() => 'N/A')
    ]);
    
    console.log('Asset information:');
    console.log(`- Name: ${name}`);
    console.log(`- Symbol: ${symbol}`);
    console.log(`- Decimals: ${decimals}`);
  } catch (error) {
    console.log('Could not retrieve asset information', error.message);
  }
  
  // Try calling the function with different signatures
  for (const functionSignature of minimumABI) {
    const contract = new ethers.Contract(contractAddress, [functionSignature], provider);
    const functionName = functionSignature.split('(')[0];
    
    try {
      console.log(`Trying ${functionName}...`);
      const result = await contract[functionName](assetAddress);
      console.log('Success! Result:', result);
      return;
    } catch (error) {
      console.log(`Failed with ${functionName}: ${error.message}`);
      
      // Try to decode the error
      if (error.data) {
        console.log('Error data:', error.data);
      }
    }
  }
  
  // Direct low-level call with the function selector
  try {
    console.log('Trying direct call with function selector 0xec489c21...');
    const data = `0xec489c21000000000000000000000000${assetAddress.slice(2)}`;
    const result = await provider.call({
      to: contractAddress,
      data,
    });
    console.log('Success with direct call! Result:', result);
  } catch (error) {
    console.log('Failed with direct call:', error.message);
    
    // Try to trace the transaction to get more information
    console.log('Attempting to trace the transaction...');
    try {
      // Some nodes support debug_traceCall - you might need to adjust based on your node
      const trace = await provider.send('debug_traceCall', [
        {
          to: contractAddress,
          data: `0xec489c21000000000000000000000000${assetAddress.slice(2)}`
        },
        'latest',
        { tracer: 'callTracer' }
      ]);
      console.log('Trace result:', JSON.stringify(trace, null, 2));
    } catch (traceError) {
      console.log('Tracing not supported or failed:', traceError.message);
    }
  }
  
  // Additional checks: try to query the contract's admin or owner if applicable
  try {
    const ownerABI = [
      "function owner() view returns (address)",
      "function admin() view returns (address)",
      "function getAdmin() view returns (address)"
    ];
    const contract = new ethers.Contract(contractAddress, ownerABI, provider);
    
    for (const fn of ['owner', 'admin', 'getAdmin']) {
      try {
        if (contract[fn]) {
          const result = await contract[fn]();
          console.log(`Contract ${fn}: ${result}`);
        }
      } catch (e) {
        // Ignore errors for functions that don't exist
      }
    }
  } catch (error) {
    console.log('Could not check contract owner/admin');
  }
  
  console.log('Debug complete');
}

// Run the debug function
debugPoolCall()
  .then(() => console.log('Debug completed'))
  .catch(error => console.error('Debug failed:', error));