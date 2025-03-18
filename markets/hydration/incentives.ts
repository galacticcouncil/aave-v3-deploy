
import { eHydrationNetwork, AssetType, TransferStrategy, IncentivesConfig } from "./../../helpers/types";
import {POOL_ADMIN} from "./../../helpers/constants";
import { tokenAddress } from "./helpers";

export const incentivesConf : IncentivesConfig  = {
    enabled: {
      [eHydrationNetwork.hydration]: true,
    },

    //NOTE: list of accounts to be set as `emissionManager` admin for asset
    rewards: { 
      [eHydrationNetwork.hydration]: {
        "DOT": POOL_ADMIN[eHydrationNetwork.hydration], 
      },
    },
    rewardsOracle: {
      //NOTE: our tasks doesn't support this option
      [eHydrationNetwork.hydration]: [],
    },
    incentivesInput: {
      [eHydrationNetwork.hydration]: [
        {
          emissionPerSecond: "34629756533",
          duration: 7890000,
          asset: "DOT",
          assetType: AssetType.AToken,
          reward: "DOT",
          rewardOracle: "0",
          transferStrategy: TransferStrategy.PullRewardsStrategy,
          transferStrategyParams: "0",
        },
      ],
    },
}
