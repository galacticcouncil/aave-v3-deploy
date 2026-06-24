// @ts-nocheck
import {
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import {
  addTransaction,
  getBatch,
  clearBatch,
} from "../../helpers/transaction-batch";
import {
  getACLManager,
  getPoolAddressesProvider,
} from "../../helpers";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { EMERGENCY_ADMIN } from "../../helpers/constants";
import { eHydrationNetwork } from "../../helpers/types";

const NEW_EMERGENCY_ADMIN = EMERGENCY_ADMIN[eHydrationNetwork.hydration];
const OLD_EMERGENCY_ADMIN = "0x146a5e57fa0b8b1e13c53bcf1d05183b1c02b51b";

task(`add-emergency-admin`, `Replace TC emergency admin in Aave ACLManager`)
  .addFlag("whitelisted", "Generate a whitelisted proposal")
  .setAction(async function ({ whitelisted }, hre) {
    const admin = await requirePoolAdmin(hre);

    const poolAddressesProvider = await getPoolAddressesProvider();
    const aclManager = await getACLManager(
      await poolAddressesProvider.getACLManager()
    );

    addTransaction(
      await aclManager.populateTransaction.addEmergencyAdmin(
        NEW_EMERGENCY_ADMIN
      )
    );

    addTransaction(
      await aclManager.populateTransaction.removeEmergencyAdmin(
        OLD_EMERGENCY_ADMIN
      )
    );

    const txs = await Promise.all(
      getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
    );
    clearBatch();

    const decoder = new ProposalDecoder(hre);
    await decoder.init();
    let prop = await generateProposalV2(txs, whitelisted);
    if (whitelisted) {
      const { whitelistedCall, proposal } = prop;
      console.log("submit preimages:");
      console.log(whitelistedCall.toHex());
      console.log("whitelist image:");
      console.log(proposal.toHex());
      decoder.printTree(decoder.transformCall(proposal.toHuman()));
    } else {
      console.log("submit preimages:");
      console.log(prop.toHex());
      decoder.printTree(decoder.transformCall(prop.toHuman()));
    }
  });
