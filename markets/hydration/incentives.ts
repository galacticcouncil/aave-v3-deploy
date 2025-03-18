
import { eHydrationNetwork, AssetType, TransferStrategy, RewardsConfigInput } from "./../../helpers/types";
import {POOL_ADMIN} from "./../../helpers/constants";
import { tokenAddress } from "./helpers";

export const incentivesADOT : RewardsConfigInput  = {
  emissionPerSecond: "34629756533",
  duration: 7890000,
  asset: "DOT",
  assetType: AssetType.AToken,
  reward: tokenAddress(5),
  rewardOracle: "0",
  transferStrategy: TransferStrategy.PullRewardsStrategy,
  transferStrategyParams: "0",
  emissionAdmin: POOL_ADMIN[eHydrationNetwork.hydration]
}
