import {
  eHydrationNetwork,
  IAaveConfiguration,
  AssetType,
  TransferStrategy,
} from './../../helpers/types'
import { POOL_ADMIN } from './../../helpers/constants'
import { BigNumber, utils } from 'ethers'
import AaveMarket from '../aave'
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
} from './reservesConfigs'
import { tokenAddress } from './helpers'
import { ZERO_ADDRESS } from '../../helpers'

const gdotSupplyIncentive = {
  incentivizedToken: AssetType.AToken,
  reward: tokenAddress(69),
  rewardOracle: '2-POOL-GDOT',
  transferStrategy: TransferStrategy.PotRewardsStrategy,
  emissionAdmin: POOL_ADMIN[eHydrationNetwork.hydration],
}

export const HydrationConfig: IAaveConfiguration = {
  ...AaveMarket,
  MarketId: 'Hydration Market',
  ATokenNamePrefix: 'Hydrated',
  StableDebtTokenNamePrefix: 'Hydrated',
  VariableDebtTokenNamePrefix: 'Hydrated',
  SymbolPrefix: 'Hydrated',
  ProviderId: 222222,
  ReservesConfig: {
    USDC: strategyUSDC,
    USDT: strategyUSDT,
    WETH: strategyWETH,
    WBTC: strategyWBTC,
    DOT: strategyDOT,
    VDOT: strategyVDOT,
    TBTC: strategyTBTC,
    '2-POOL-GDOT': strategyGDOT,
    ETH: strategyETH,
    '2-POOL-GETH': strategyGETH,
    '3-POOL': strategy3POOL,
    '2-POOL-HUSDT': strategyHUSDT,
    '2-POOL-HUSDC': strategyHUSDC,
    '2-POOL-HUSDS': strategyHUSDS,
    '2-POOL-HUSDE': strategyHUSDe,
    PAXG: strategyPAXG,
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
      '2-POOL-GDOT': tokenAddress(690),
      ETH: tokenAddress(34),
      '2-POOL-GETH': tokenAddress(4200),
      '3-POOL': tokenAddress(103),
      '2-POOL-HUSDC': tokenAddress(110),
      '2-POOL-HUSDT': tokenAddress(111),
      '2-POOL-HUSDS': tokenAddress(112),
      '2-POOL-HUSDE': tokenAddress(113),
      PAXG: tokenAddress(39),
    },
    [eHydrationNetwork.lark]: {
      USDC: tokenAddress(22),
      USDT: tokenAddress(10),
      // WETH: tokenAddress(20),
      WBTC: tokenAddress(19),
      DOT: tokenAddress(5),
      VDOT: tokenAddress(15),
      TBTC: tokenAddress(1000765),
      '2-POOL-GDOT': tokenAddress(690),
      ETH: tokenAddress(34),
      '2-POOL-GETH': tokenAddress(4200),
      '3-POOL': tokenAddress(103),
      '2-POOL-HUSDC': tokenAddress(110),
      '2-POOL-HUSDT': tokenAddress(111),
      '2-POOL-HUSDS': tokenAddress(112),
      '2-POOL-HUSDE': tokenAddress(113),
      PAXG: tokenAddress(39),
    },
    [eHydrationNetwork.nice]: {
      USDC: tokenAddress(21),
      USDT: tokenAddress(10),
      WETH: tokenAddress(20),
      WBTC: tokenAddress(3),
      DOT: tokenAddress(5),
      VDOT: tokenAddress(15),
      '2-POOL-GDOT': tokenAddress(690),
      ETH: tokenAddress(34),
      '2-POOL-GETH': tokenAddress(4200),
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
      id: '1',
      ltv: '9000',
      liquidationThreshold: '9300',
      liquidationBonus: '10150',
      label: 'Stablecoins',
      assets: [
        'USDC',
        'USDT',
        '3-POOL',
        '2-POOL-HUSDT',
        '2-POOL-HUSDC',
        '2-POOL-HUSDS',
        '2-POOL-HUSDE',
      ],
    },
    DotEMode: {
      id: '2',
      ltv: '8500',
      liquidationThreshold: '9200',
      liquidationBonus: '10450',
      label: 'DOT correlated',
      assets: ['DOT', 'VDOT', '2-Pool-GDOT'],
    },
    EthEMode: {
      id: '3',
      ltv: '8000',
      liquidationThreshold: '9000',
      liquidationBonus: '10450',
      label: 'ETH',
      assets: ['ETH', '2-Pool-GETH'],
    },
  },
  ChainlinkAggregator: {
    [eHydrationNetwork.hydration]: {
      USDC: '0x8001B9520eBB312aB888C1eEC737AfA56471dc46',
      USDT: '0x205c1143d6bE986DBE7a2E389Ac7d42cB6095DC6',
      WETH: '0xC646e269A86b783A3c9Cb7cff4Fc931Dc25D51b7',
      WBTC: '0xe174F8188C586D0a57CBFA487188B347907d77F6',
      DOT: '0x5997008BD1e515D3789aCCb18CA67632Be572636',
      VDOT: '0x2fFa376E0a84606e4Ccb3738071312A34Cebad6C',
      TBTC: '0x42B8d6326ed7125279493d4889Abc78d9d81E279',
      '2-POOL-GDOT': '0xd112C33D2cf4199a764acEab739E493D36c4C6A8',
      BNC: '0x3Fa1eA9cac6c88caCF0A231fF7E26348487b6e89',
      HDX: '0x6e4FDA8dFC82BE465F3eC7A54747BA80dCf2a8c0',
      ETH: '0xc4D17436fa0510Fe0efDD9b59B1F3Fc2eFe05b02',
      WSTETH: '0x21E165F7EE14cECC0d5c7587590D54a4A3f8d3B6',
      '2-POOL-GETH': '0xd112C33D2cf4199a764acEab739E493D36c4C6A8',
      WSTETH_ETH: '0xdC6d1765125D795D79FAe5C9f0a2F1F160D46750',
      '3-POOL': '0xFA09900A2b871e40ccf8E082b370e9A9baDa3A4e',
      '2-POOL-HUSDC': '0x71FB115862D2A8f35a53508A4B2A67b47A2D8D25',
      '2-POOL-HUSDT': '0x1bD38d8a1F43838df3104f84A559a5A35254650a',
      '2-POOL-HUSDS': '0x6CD370B3a01a25F17522E347FBc4345C309A3269',
      '2-POOL-HUSDE': '0xd2D49a26E8b24266b714Eba4b79BEaEF56a17676',
      PAXG: '0x9C7713EB68D465a59A044bF9B4805C77C556994C',
    },
    [eHydrationNetwork.lark]: {
      USDC: '0x8001B9520eBB312aB888C1eEC737AfA56471dc46',
      USDT: '0x205c1143d6bE986DBE7a2E389Ac7d42cB6095DC6',
      WETH: '0xC646e269A86b783A3c9Cb7cff4Fc931Dc25D51b7',
      WBTC: '0xe174F8188C586D0a57CBFA487188B347907d77F6',
      DOT: '0x5997008BD1e515D3789aCCb18CA67632Be572636',
      VDOT: '0x2fFa376E0a84606e4Ccb3738071312A34Cebad6C',
      TBTC: '0x42B8d6326ed7125279493d4889Abc78d9d81E279',
      '2-POOL-GDOT': '0xd112C33D2cf4199a764acEab739E493D36c4C6A8',
      BNC: '0x3Fa1eA9cac6c88caCF0A231fF7E26348487b6e89',
      HDX: '0x6e4FDA8dFC82BE465F3eC7A54747BA80dCf2a8c0',
      ETH: '0xc4D17436fa0510Fe0efDD9b59B1F3Fc2eFe05b02',
      WSTETH: '0x21E165F7EE14cECC0d5c7587590D54a4A3f8d3B6',
      '2-POOL-GETH': '0xd112C33D2cf4199a764acEab739E493D36c4C6A8',
      WSTETH_ETH: '0xdC6d1765125D795D79FAe5C9f0a2F1F160D46750',
      '3-POOL': '0xFA09900A2b871e40ccf8E082b370e9A9baDa3A4e',
      '2-POOL-HUSDC': '0x71FB115862D2A8f35a53508A4B2A67b47A2D8D25',
      '2-POOL-HUSDT': '0x1bD38d8a1F43838df3104f84A559a5A35254650a',
      '2-POOL-HUSDS': '0x6CD370B3a01a25F17522E347FBc4345C309A3269',
      '2-POOL-HUSDE': '0xd2D49a26E8b24266b714Eba4b79BEaEF56a17676',
      PAXG: '0x9C7713EB68D465a59A044bF9B4805C77C556994C',
    },
    [eHydrationNetwork.nice]: {
      USDC: '0xEE7aFb45c094DC9fA404D6A86A7d795d4aA33D28',
      USDT: '0xb4aC9f0E6E207D5d81B756F8aF6efe3fe7B0E72c',
      WETH: '0xBd763043861CAF4E7e4E7Ffe951A03dF2Ea7E5AC',
      WBTC: '0xC9cCBe99bdD9538871f9756Ca5Ea64C2267cb0a7',
      DOT: '0x422E745797EC0Ef399c17cE3E2348394F2944727',
      VDOT: '0x234F96059d628Da80B76A40c0E50a9D16a8F3191',
      //TBTC: "0x5d8320f3ced9575d8e25b6f437e610fc6a03bf52",
      '2-POOL-GDOT': '0x234F96059d628Da80B76A40c0E50a9D16a8F3191', //NOTE: this is vDOT's oracle
      ETH: '0x52bBB0BC38C42D60b24EBF0C617E8218D2aB6d36', //TODO: waithing on DIA
      WSTETH: '0x52bBB0BC38C42D60b24EBF0C617E8218D2aB6d36', //TODO: waiting on DIA
      '2-POOL-GETH': '0x493f00bA516E55e5CA932f55CeB6b5c4b6E4257F', //TODO: deploy USDOracleAdapter and use real address
      WSTETH_ETH: '0x493f00bA516E55e5CA932f55CeB6b5c4b6E4257F', //TODO: deploy OraclesAggregator and use real address
    },
  },
  IncentivesConfig: {
    [eHydrationNetwork.hydration]: {
      '2-POOL-GDOT': [
        {
          emissionPerSecond: BigNumber.from('3757650000000000'),
          distributionEnd: Date.parse('17 Sep 2026 14:24:36 GMT') / 1000,
          reserve: '2-Pool-GDOT',
          ...gdotSupplyIncentive,
        },
        {
          emissionPerSecond: BigNumber.from('27557227366'),
          distributionEnd: Date.parse('30 Jul 2025 17:52:36 GMT') / 1000,
          reserve: '2-Pool-GDOT',
          incentivizedToken: AssetType.AToken,
          reward: tokenAddress(14),
          rewardOracle: 'BNC',
          transferStrategy: TransferStrategy.PotRewardsStrategy,
          emissionAdmin: POOL_ADMIN[eHydrationNetwork.hydration],
        },
        {
          emissionPerSecond: BigNumber.from('285779578189'),
          distributionEnd: Date.parse('30 Jul 2025 17:52:36 GMT') / 1000,
          reserve: '2-Pool-GDOT',
          incentivizedToken: AssetType.AToken,
          reward: tokenAddress(0),
          rewardOracle: 'HDX',
          transferStrategy: TransferStrategy.PotRewardsStrategy,
          emissionAdmin: POOL_ADMIN[eHydrationNetwork.hydration],
        },
      ],
      '3-POOL': [
        {
          emissionPerSecond: utils.parseEther('0.0002810529212').toString(),
          distributionEnd: Date.parse('17 Sep 2026 14:24:36 GMT') / 1000,
          reserve: '3-Pool',
          ...gdotSupplyIncentive,
        },
      ],
      '2-POOL-HUSDT': [
        {
          emissionPerSecond: BigNumber.from(
            '1,079,545,885,484,937'.replace(/,/g, ''),
          ).mul(3),
          distributionEnd: Date.parse('22 Oct 2026 14:22:22 GMT') / 1000,
          reserve: '2-Pool-HUSDT',
          ...gdotSupplyIncentive,
        },
      ],
      '2-POOL-HUSDC': [
        {
          emissionPerSecond: BigNumber.from(
            '1,079,545,885,484,937'.replace(/,/g, ''),
          ).mul(3),
          distributionEnd: Date.parse('22 Oct 2026 14:22:22 GMT') / 1000,
          reserve: '2-Pool-HUSDC',
          ...gdotSupplyIncentive,
        },
      ],
      '2-POOL-HUSDS': [
        {
          emissionPerSecond: BigNumber.from(
            '402,815,628,912,290'.replace(/,/g, ''),
          ).mul(3),
          distributionEnd: Date.parse('22 Oct 2026 14:22:22 GMT') / 1000,
          reserve: '2-Pool-HUSDS',
          ...gdotSupplyIncentive,
        },
      ],
      '2-POOL-HUSDE': [
        {
          emissionPerSecond: BigNumber.from(
            '402,815,628,912,290'.replace(/,/g, ''),
          ).mul(3),
          distributionEnd: Date.parse('22 Oct 2026 14:22:22 GMT') / 1000,
          reserve: '2-Pool-HUSDe',
          ...gdotSupplyIncentive,
        },
      ],
    },
  },
  USDOracleAdapter: {
    [eHydrationNetwork.hydration]: {
      '2-POOL-GDOT': {
        assetToX: '0x00000102737461626c657377000003e9000002b2', //hydration's chainlink precompile, stableswap 10min., aDOT(1001)/gDOTs(690)
        xToUSD: '0xFBCa0A6dC5B74C042DF23025D99ef0F1fcAC6702',
      },
      VDOT: {
        assetToX: '0x00000102626966726f73746f000000050000000f', //hydration's chainlink precompile, bifrosto 10min., DOT(5)/vDOT(15),
        xToUSD: '0xFBCa0A6dC5B74C042DF23025D99ef0F1fcAC6702',
      },
      HDX: {
        assetToX: '0x0000010200000000000000000000000a00000000', //hydration's chainlink precompile, 10min. USD(10)/HDX(0)
        xToUSD: '0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B',
      },
      BNC: {
        assetToX: '0x0000010200000000000000000000000a0000000e', //hydration's chainlink precompile, 10min. USDT(10)/BNC(14)
        xToUSD: '0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B',
      },
      '2-POOL-GETH': {
        assetToX: '0x00000102737461626c657377000003ef00001068', //hydration's chainlink precompile, stableswap 10min., aETH(1007)/gETHs(4200)
        xToUSD: '0x1AF549Fe19A9B73D094173C41e18BF7F357F594b',
      },
      '3-POOL': {
        assetToX: '0x00000102737461626c657377000003ea00000067', //hydration's chainlink precompile, stableswap 10min., aUSDT(1002)/3-POOL(103)
        xToUSD: '0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B', // DIA USDT/USD oracle
      },
    },
  },
  OraclesAggregator: {
    [eHydrationNetwork.hydration]: {
      WSTETH_ETH: {
        srcAssetToX: '0x52bBB0BC38C42D60b24EBF0C617E8218D2aB6d36', //wstETH -> USD
        destAssetToX: '0x1AF549Fe19A9B73D094173C41e18BF7F357F594b', //ETH -> USD
      },
    },
  },
}

export default HydrationConfig
