
import { eHydrationNetwork, AssetType, TransferStrategy, RewardsConfigInput } from "./../../helpers/types";
import {POOL_ADMIN} from "./../../helpers/constants";
import { tokenAddress } from "./helpers";
import { BigNumber } from "ethers";

export const incentivesDOT : RewardsConfigInput  = {
  emissionPerSecond: BigNumber.from("10000000000000000"),
  duration: 604800,
  asset: "DOT",
  assetType: AssetType.AToken,
  reward: tokenAddress(5),
  rewardOracle: "DOT",
  transferStrategy: TransferStrategy.PotRewardsStrategy,
  emissionAdmin: POOL_ADMIN[eHydrationNetwork.hydration]
}
