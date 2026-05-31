import {
  eHydrationNetwork,
  IAaveConfiguration,
  AssetType,
  TransferStrategy,
} from "./../../helpers/types";
import { POOL_ADMIN } from "./../../helpers/constants";
import { BigNumber } from "ethers";
import AaveMarket from "../aave";
import {
  strategyDOT,
  strategyUSDC,
  strategyUSDT,
  strategyVDOT,
  strategyWBTC,
  strategyWETH,
  strategyTBTC,
  strategyGDOT,
  strategyETH,
  strategyGETH,
  strategy3POOL,
  strategyHUSDT,
  strategyHUSDC,
  strategyHUSDS,
  strategyHUSDe,
  strategyPAXG,
  strategyPRIME,
  strategyApyUSD,
  strategySIGIL,
  strategySOL,
  strategyGSOL,
  strategyEURC,
  strategyHEURC,
} from "./reservesConfigs";
import { tokenAddress } from "./helpers";
import { ZERO_ADDRESS } from "../../helpers";

const gdotSupplyIncentive = {
  incentivizedToken: AssetType.AToken,
  reward: tokenAddress(69),
  rewardOracle: "2-POOL-GDOT",
  transferStrategy: TransferStrategy.PotRewardsStrategy,
  emissionAdmin: POOL_ADMIN[eHydrationNetwork.hydration],
};

const primeSupplyIncentive = {
  incentivizedToken: AssetType.AToken,
  reward: tokenAddress(43),
  rewardOracle: "PRIME",
  transferStrategy: TransferStrategy.PotRewardsStrategy,
  emissionAdmin: POOL_ADMIN[eHydrationNetwork.hydration],
};

export const HydrationConfig: IAaveConfiguration = {
  ...AaveMarket,
  MarketId: "Hydration Market",
  ATokenNamePrefix: "Hydrated",
  StableDebtTokenNamePrefix: "Hydrated",
  VariableDebtTokenNamePrefix: "Hydrated",
  SymbolPrefix: "Hydrated",
  ProviderId: 222222,
  ReservesConfig: {
    USDC: strategyUSDC,
    USDT: strategyUSDT,
    WETH: strategyWETH,
    WBTC: strategyWBTC,
    DOT: strategyDOT,
    VDOT: strategyVDOT,
    TBTC: strategyTBTC,
    "2-POOL-GDOT": strategyGDOT,
    ETH: strategyETH,
    "2-POOL-GETH": strategyGETH,
    "3-POOL": strategy3POOL,
    "2-POOL-HUSDT": strategyHUSDT,
    "2-POOL-HUSDC": strategyHUSDC,
    "2-POOL-HUSDS": strategyHUSDS,
    "2-POOL-HUSDE": strategyHUSDe,
    PAXG: strategyPAXG,
    PRIME: strategyPRIME,
    APYUSD: strategyApyUSD,
    SIGIL: strategySIGIL,
    SOL: strategySOL,
    "2-POOL-GSOL": strategyGSOL,
    EURC: strategyEURC,
    "2-POOL-HEURC": strategyHEURC,
  },
  ReserveAssets: {
    [eHydrationNetwork.hydration]: {
      USDC: tokenAddress(22),
      USDT: tokenAddress(10),
      // WETH: tokenAddress(20),
      WBTC: tokenAddress(19),
      DOT: tokenAddress(5),
      VDOT: tokenAddress(15),
      TBTC: tokenAddress(1000765),
      "2-POOL-GDOT": tokenAddress(690),
      ETH: tokenAddress(34),
      "2-POOL-GETH": tokenAddress(4200),
      "3-POOL": tokenAddress(103),
      "2-POOL-HUSDC": tokenAddress(110),
      "2-POOL-HUSDT": tokenAddress(111),
      "2-POOL-HUSDS": tokenAddress(112),
      "2-POOL-HUSDE": tokenAddress(113),
      PAXG: tokenAddress(39),
      PRIME: tokenAddress(43),
      APYUSD: tokenAddress(46),
      SIGIL: tokenAddress(816),
      SOL: tokenAddress(1000752),
      "2-POOL-GSOL": tokenAddress(90001),
      EURC: tokenAddress(44),
      "2-POOL-HEURC": tokenAddress(10044),
    },
    [eHydrationNetwork.nice]: {
      USDC: tokenAddress(21),
      USDT: tokenAddress(10),
      WETH: tokenAddress(20),
      WBTC: tokenAddress(3),
      DOT: tokenAddress(5),
      VDOT: tokenAddress(15),
      "2-POOL-GDOT": tokenAddress(690),
      ETH: tokenAddress(34),
      "2-POOL-GETH": tokenAddress(4200),
      //TBTC: ZERO_ADDRESS
    },
    [eHydrationNetwork.zombie]: {
      USDC: ZERO_ADDRESS,
      USDT: ZERO_ADDRESS,
      // WETH: ZERO_ADDRESS,
      WBTC: ZERO_ADDRESS,
      DOT: ZERO_ADDRESS,
      //VDOT: ZERO_ADDRESS,
      //TBTC: ZERO_ADDRESS,
    },
  },
  EModes: {
    StableEMode: {
      id: "1",
      ltv: "9000",
      liquidationThreshold: "9300",
      liquidationBonus: "10150",
      label: "Stablecoins",
      assets: [
        "USDC",
        "USDT",
        "3-POOL",
        "2-POOL-HUSDT",
        "2-POOL-HUSDC",
        "2-POOL-HUSDS",
        "2-POOL-HUSDE",
      ],
    },
    DotEMode: {
      id: "2",
      ltv: "8500",
      liquidationThreshold: "9200",
      liquidationBonus: "10450",
      label: "DOT correlated",
      assets: ["DOT", "VDOT", "2-Pool-GDOT"],
    },
    EthEMode: {
      id: "3",
      ltv: "8000",
      liquidationThreshold: "9000",
      liquidationBonus: "10450",
      label: "ETH",
      assets: ["ETH", "2-Pool-GETH"],
    },
    SolEMode: {
      id: "4",
      ltv: "8000",
      liquidationThreshold: "8500",
      liquidationBonus: "10450",
      label: "SOL correlated",
      assets: ["SOL", "2-Pool-GSOL"],
    },
    EurozoneEMode: {
      id: "5",
      ltv: "8000",
      liquidationThreshold: "8500",
      liquidationBonus: "10300",
      label: "EUROZONE",
      assets: ["EURC", "2-POOL-HEURC"],
    },
  },
  ChainlinkAggregator: {
    [eHydrationNetwork.hydration]: {
      USDC: "0x17711BE5D63B2Fe8A2C379725DE720773158b954",
      USDT: "0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B",
      WETH: "0x8aEAE0bBf623B0E70732086B8D48A6090C311596",
      WBTC: "0xeDD9A7C47A9F91a0F2db93978A88844167B4a04f",
      DOT: "0xFBCa0A6dC5B74C042DF23025D99ef0F1fcAC6702",
      VDOT: "0x2fFa376E0a84606e4Ccb3738071312A34Cebad6C",
      TBTC: "0xe5AcDfB0d5EC5cE34F7448B41ef4a97c4e83D9c1",
      "2-POOL-GDOT": "0xedbD21F476039C6019d2EC3e97f949af98a5c121",
      BNC: "0xc94c414E8eBF7EA928D9bE555A8eAb719B89bBcE",
      HDX: "0xea63e594ee00590938E856F2134E6C792bA92d13",
      ETH: "0x1AF549Fe19A9B73D094173C41e18BF7F357F594b",
      WSTETH: "0x52bBB0BC38C42D60b24EBF0C617E8218D2aB6d36",
      "2-POOL-GETH": "0x32CC29cA6924B16077056A7B049663AF153D9E90",
      WSTETH_ETH: "0xA317cEbdE7F948e132fDD177E5002A1DD2C2cB21",
      "3-POOL": "0xFbD6F083b9e8683fe62B21cF5849f362238610AF",
      "2-POOL-HUSDC": "0x00000102737461626c657377000000de0000006e", // HOLLAR(222) / 2-POOL-HUSDC(110) 10 min. stablesw
      "2-POOL-HUSDT": "0x00000102737461626c657377000000de0000006f", // HOLLAR(222) / 2-POOL-HUSDT(111) 10 min. stablesw
      "2-POOL-HUSDS": "0x00000102737461626c657377000000de00000070", // HOLLAR(222) / 2-POOL-HUSDS(112) 10 min. stablesw
      "2-POOL-HUSDE": "0x00000102737461626c657377000000de00000071", // HOLLAR(222) / 2-POOL-HUSDe(113) 10 min. stablesw
      PAXG: "0x8fB61B8E81C2f17695F14A136C98b0C4013bc105",
      PRIME: "0xDEe587cC569bf1FcBdcD6d1472031d225f34C307",
      APYUSD: "0x286BAaA3F5738ac01EF922B1E913Fcc09916AF96",
      SIGIL: "0xe50AA7afa36A5E04C0b0D0892D0b173c924b662F",
      // GIGASOL oracles
      SOL: "0x2FAA73BCC0115b9F67d2f36E53738B7FF95f0D2C", // DIA SOL/USD oracle
      "2-POOL-GSOL": "0xCD3648A48378cBDa915f6be0A30073b76593Ed9A",
      JITOSOL_SOL: "0x5B29bceaCBD1c37FD4A2c32a052b63813ed0D4b8",
      // HEURC oracles
      EURC: "0xaa47a5662269270D3DF33Ae08F806e383611575c", // DIA EUR/USD oracle
      "2-POOL-HEURC": "0x71691b7EE575a2842b242cE8E0AEcdB0e031B725",
      EURUSD: "0xaa47a5662269270D3DF33Ae08F806e383611575c", // DIA EUR/USD oracle (used for HEURC pool drifting peg)
    },
    [eHydrationNetwork.nice]: {
      USDC: "0xEE7aFb45c094DC9fA404D6A86A7d795d4aA33D28",
      USDT: "0xb4aC9f0E6E207D5d81B756F8aF6efe3fe7B0E72c",
      WETH: "0xBd763043861CAF4E7e4E7Ffe951A03dF2Ea7E5AC",
      WBTC: "0xC9cCBe99bdD9538871f9756Ca5Ea64C2267cb0a7",
      DOT: "0x422E745797EC0Ef399c17cE3E2348394F2944727",
      VDOT: "0x234F96059d628Da80B76A40c0E50a9D16a8F3191",
      //TBTC: "0x5d8320f3ced9575d8e25b6f437e610fc6a03bf52",
      "2-POOL-GDOT": "0x234F96059d628Da80B76A40c0E50a9D16a8F3191", //NOTE: this is vDOT's oracle
      ETH: "0x52bBB0BC38C42D60b24EBF0C617E8218D2aB6d36", //TODO: waithing on DIA
      WSTETH: "0x52bBB0BC38C42D60b24EBF0C617E8218D2aB6d36", //TODO: waiting on DIA
      "2-POOL-GETH": "0x493f00bA516E55e5CA932f55CeB6b5c4b6E4257F", //TODO: deploy USDOracleAdapter and use real address
      WSTETH_ETH: "0x493f00bA516E55e5CA932f55CeB6b5c4b6E4257F", //TODO: deploy OraclesAggregator and use real address
    },
    [eHydrationNetwork.zombie]: {
      // GIGASOL oracles for zombie testing
      SOL: "0x2FAA73BCC0115b9F67d2f36E53738B7FF95f0D2C", // DIA SOL/USD oracle (same as mainnet fork)
      "2-POOL-GSOL": "0xCD3648A48378cBDa915f6be0A30073b76593Ed9A", // USDOracleAdapter TODO: REPLACE BEFORE CREATING GIGASOL PROPOSAL
      JITOSOL_SOL: "0x5B29bceaCBD1c37FD4A2c32a052b63813ed0D4b8", // ManagedOracle (jitoSOL/SOL) TODO: REPLACE BEFORE CREATING GIGASOL PROPOSAL
    },
  },
  IncentivesConfig: {
    [eHydrationNetwork.hydration]: {
      "2-POOL-GDOT": [
        {
          // 2,350 gDOT per 30 days
          emissionPerSecond: BigNumber.from("906635802469136"),
          distributionEnd: Date.parse("15 Oct 2026 14:00:00 GMT") / 1000,
          reserve: "2-Pool-GDOT",
          ...gdotSupplyIncentive,
        },
        {
          emissionPerSecond: BigNumber.from("27557227366"),
          distributionEnd: Date.parse("30 Jul 2025 17:52:36 GMT") / 1000,
          reserve: "2-Pool-GDOT",
          incentivizedToken: AssetType.AToken,
          reward: tokenAddress(14),
          rewardOracle: "BNC",
          transferStrategy: TransferStrategy.PotRewardsStrategy,
          emissionAdmin: POOL_ADMIN[eHydrationNetwork.hydration],
        },
        {
          emissionPerSecond: BigNumber.from("285779578189"),
          distributionEnd: Date.parse("30 Jul 2025 17:52:36 GMT") / 1000,
          reserve: "2-Pool-GDOT",
          incentivizedToken: AssetType.AToken,
          reward: tokenAddress(0),
          rewardOracle: "HDX",
          transferStrategy: TransferStrategy.PotRewardsStrategy,
          emissionAdmin: POOL_ADMIN[eHydrationNetwork.hydration],
        },
      ],
      "2-POOL-HUSDT": [
        {
          // 8,268.71 PRIME per 30 days
          emissionPerSecond: BigNumber.from("3190"),
          distributionEnd: Date.parse("15 Oct 2026 14:00:00 GMT") / 1000,
          reserve: "2-Pool-HUSDT",
          ...primeSupplyIncentive,
        },
      ],
      "2-POOL-HUSDC": [
        {
          // 8,268.71 PRIME per 30 days
          emissionPerSecond: BigNumber.from("3190"),
          distributionEnd: Date.parse("15 Oct 2026 14:00:00 GMT") / 1000,
          reserve: "2-Pool-HUSDC",
          ...primeSupplyIncentive,
        },
      ],
      "2-POOL-HEURC": [
        {
          // 7,295.92 PRIME per 30 days
          emissionPerSecond: BigNumber.from("2814"),
          distributionEnd: Date.parse("15 Oct 2026 14:00:00 GMT") / 1000,
          reserve: "2-Pool-HEURC",
          ...primeSupplyIncentive,
        },
      ],
    },
  },
  USDOracleAdapter: {
    [eHydrationNetwork.hydration]: {
      "2-POOL-GDOT": {
        assetToX: "0x00000102737461626c657377000003e9000002b2", //hydration's chainlink precompile, stableswap 10min., aDOT(1001)/gDOTs(690)
        xToUSD: "0xFBCa0A6dC5B74C042DF23025D99ef0F1fcAC6702",
      },
      VDOT: {
        assetToX: "0x00000102626966726f73746f000000050000000f", //hydration's chainlink precompile, bifrosto 10min., DOT(5)/vDOT(15),
        xToUSD: "0xFBCa0A6dC5B74C042DF23025D99ef0F1fcAC6702",
      },
      HDX: {
        assetToX: "0x0000010200000000000000000000000a00000000", //hydration's chainlink precompile, 10min. USD(10)/HDX(0)
        xToUSD: "0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B",
      },
      BNC: {
        assetToX: "0x0000010200000000000000000000000a0000000e", //hydration's chainlink precompile, 10min. USDT(10)/BNC(14)
        xToUSD: "0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B",
      },
      "2-POOL-GETH": {
        assetToX: "0x00000102737461626c657377000003ef00001068", //hydration's chainlink precompile, stableswap 10min., aETH(1007)/gETHs(4200)
        xToUSD: "0x1AF549Fe19A9B73D094173C41e18BF7F357F594b",
      },
      "3-POOL": {
        assetToX: "0x00000102737461626c657377000003ea00000067", //hydration's chainlink precompile, stableswap 10min., aUSDT(1002)/3-POOL(103)
        xToUSD: "0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B", // DIA USDT/USD oracle
      },
      // GIGASOL - stableswap price oracle for 2-POOL-GSOL
      "2-POOL-GSOL": {
        assetToX: "0x00000102737461626c657377000003f100015f91", // hydration's chainlink precompile, stableswap 10min., aSOL(1009)/gSOLs(90001)
        xToUSD: "0x2FAA73BCC0115b9F67d2f36E53738B7FF95f0D2C", // DIA SOL/USD oracle
      },
      // HEURC - stableswap price oracle for 2-POOL-HEURC
      "2-POOL-HEURC": {
        assetToX: "0x00000102737461626c657377000004140000273c", // hydration's chainlink precompile, stableswap 10min., aEURC(1044)/2-Pool-HEURC(10044)
        xToUSD: "0xaa47a5662269270D3DF33Ae08F806e383611575c", // DIA EUR/USD oracle
      },
    },
    [eHydrationNetwork.zombie]: {
      // GIGASOL - stableswap price oracle for 2-POOL-GSOL (same config as mainnet)
      "2-POOL-GSOL": {
        assetToX: "0x00000102737461626c657377000003f100015f91", // hydration's chainlink precompile, stableswap 10min., aSOL(1009)/gSOLs(90001)
        xToUSD: "0x2FAA73BCC0115b9F67d2f36E53738B7FF95f0D2C", // DIA SOL/USD oracle
      },
    },
  },
  OraclesAggregator: {
    [eHydrationNetwork.hydration]: {
      WSTETH_ETH: {
        srcAssetToX: "0x52bBB0BC38C42D60b24EBF0C617E8218D2aB6d36", //wstETH -> USD
        destAssetToX: "0x1AF549Fe19A9B73D094173C41e18BF7F357F594b", //ETH -> USD
      },
      // NOTE: JITOSOL_SOL uses ManagedOracle pattern (like wstETH), not OraclesAggregator
    },
  },
};

export default HydrationConfig;
