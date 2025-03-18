
import { eHydrationNetwork, AssetType, TransferStrategy, RewardsConfigInput } from "./../../helpers/types";
import {POOL_ADMIN} from "./../../helpers/constants";
import { tokenAddress } from "./helpers";

export const incentivesADOT : RewardsConfigInput  = {
  emissionPerSecond: 165343915,
  duration: 604800,
  asset: "0x02639ec01313c8775Fae74F2dad1118c8A8a86dA",
  reward: tokenAddress(5),
  rewardOracle: "0xfbca0a6dc5b74c042df23025d99ef0f1fcac6702",
  transferStrategy: TransferStrategy.PullRewardsStrategy,
  emissionAdmin: POOL_ADMIN[eHydrationNetwork.hydration]
}
