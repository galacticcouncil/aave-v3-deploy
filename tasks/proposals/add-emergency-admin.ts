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

const EMERGENCY_ADMIN_ADDRESS = "0xaa7e0000000000000000000000000000000aa7e1";

task(`add-emergency-admin`, `Register TC emergency admin in Aave ACLManager`)
  .addFlag("whitelisted", "Generate a whitelisted proposal")
  .setAction(async function ({ whitelisted }, hre) {
    const admin = await requirePoolAdmin(hre);

    const poolAddressesProvider = await getPoolAddressesProvider();
    const aclManager = await getACLManager(
      await poolAddressesProvider.getACLManager()
    );

    addTransaction(
      await aclManager.populateTransaction.addEmergencyAdmin(
        EMERGENCY_ADMIN_ADDRESS
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
