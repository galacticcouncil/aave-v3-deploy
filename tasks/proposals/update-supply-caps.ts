import {generateProposal} from "../../helpers/hydration-proposal.js";
import {task} from "hardhat/config";
import {getBatch} from "../../helpers/transaction-batch";
import requirePoolAdmin from "../../helpers/utilities/require-pool-admin";

task(`update-supply-caps`, ``).setAction(async function (_, hre) {
  const admin = await requirePoolAdmin(hre);

  console.log("update supply caps");
  await hre.run("review-supply-caps", { fix: true, batch: true });

  console.log("proposal batch preimage:");
  console.log(
      (await generateProposal(getBatch(), admin, [])).toHex()
  );
});
