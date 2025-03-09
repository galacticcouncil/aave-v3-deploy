import { generateProposal } from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";
import ProposalDecoder from "../../helpers/proposal-decoder";


import { getEmissionManager, getIncentivesV2  } from "../../helpers/contract-getters";
import { getAddress } from "ethers/lib/utils";


import {
  getPoolAddressesProvider,
} from "../../helpers/contract-getters";
import { POOL_ADDRESSES_PROVIDER_ID } from "../../helpers/deploy-ids";
import { getAddressFromJson } from "../../helpers/utilities/tx";
import { getAaveProtocolDataProvider } from "../../helpers/contract-getters";
import { FORK } from "../../helpers/hardhat-config-helpers";


task(`setup-incentives`, `Updates incentives program or starts new one if incentives doesn't exists.`).setAction(async function (_, hre) {
  const admin = await requirePoolAdmin(hre);

  const em = await getEmissionManager();
  const incentives = await getIncentivesV2();

  // console.log(em);
  // console.log(incentives);


  // const network = FORK ? FORK : hre.network.name;
  // console.log(POOL_ADDRESSES_PROVIDER_ID )
  //   const poolAddressesProvider = await getPoolAddressesProvider(
  //     await getAddressFromJson(network, POOL_ADDRESSES_PROVIDER_ID)
  //   );
  //
  //   const protocolDataProvider = await getAaveProtocolDataProvider(
  //     await poolAddressesProvider.getPoolDataProvider()
  //   );
  //
  //   const reserves = await protocolDataProvider.getAllATokens();
  //
  //   console.log(reserves);

   let tx = await incentives.configureAssets([{
        emissionPerSecond: ethers.utils.parseEther("0.1"),                  // Reward per second
        totalSupply: "1000000000000000000000000",                                      // The total supply of the asset to incentivize
        distributionEnd: 1000,                                              // The end of the distribution of the incentives for an asset
        asset: getAddress("0x02639ec01313c8775Fae74F2dad1118c8A8a86dA"), //aDot     //The asset address to incentivize
        reward: getAddress("0x0000000000000000000000000000000100000005"), //Dot     //The reward token address
        transferStrategy:getAddress("0x02639ec01313c8775Fae74F2dad1118c8A8a86dA"),  //The TransferStrategy address with the install hook and claim logic
        rewardOracle: getAddress("0x02639ec01313c8775Fae74F2dad1118c8A8a86dA"),     //The Price Oracle of a reward to visualize the incentives at the UI frontend. Must follow Chainlink Aggregator IEACAggregatorProxy interface to be compatible.
    }]);

  // console.log("udpate incentives program");
  // await hre.run("review-supply-caps", { fix: true, batch: true });
  //
  // const { preimages, whitelist, proposal, whitelistedCall } =
  //   await generateProposal(getBatch(), admin, [], true);
  //
  // const decoder = new ProposalDecoder(hre);
  // await decoder.init();
  // console.log("submit preimages:");
  // console.log(preimages.toHex());
  // decoder.printTree(decoder.transformCall(preimages.toHuman()));
  // console.log("whitelisted call hash:", whitelistedCall.hash.toHex());
  // console.log(whitelistedCall.toHex());
  // decoder.printTree(decoder.transformCall(whitelistedCall.toHuman()));
  // console.log("whitelist call hash:", whitelistedCall.hash.toHex());
  // console.log(whitelist.toHex());
  // decoder.printTree(decoder.transformCall(whitelist.toHuman()));
  // console.log("whitelisted proposal:");
  // console.log(proposal.toHex());
  // decoder.printTree(decoder.transformCall(proposal.toHuman()));
  // console.log("whitelisted proposal hash:");
  // console.log(proposal.hash.toHex());
});
