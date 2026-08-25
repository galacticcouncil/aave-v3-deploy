// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {IPullRewardsTransferStrategy} from '@aave/periphery-v3/contracts/rewards/interfaces/IPullRewardsTransferStrategy.sol';
import {ITransferStrategyBase} from '@aave/periphery-v3/contracts/rewards/interfaces/ITransferStrategyBase.sol';
import {TransferStrategyBase} from '@aave/periphery-v3/contracts/rewards/transfer-strategies/TransferStrategyBase.sol';
import {GPv2SafeERC20} from '@aave/core-v3/contracts/dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

/**
 * @title PotRewardsTransferStrategy
 * @notice Transfer strategy that transfers ERC20 rewards from itself to the user address.
 **/
contract PotRewardsTransferStrategy is TransferStrategyBase, IPullRewardsTransferStrategy {
  using GPv2SafeERC20 for IERC20;

  constructor(
    address incentivesController,
    address rewardsAdmin
  ) TransferStrategyBase(incentivesController, rewardsAdmin) {}

  /// @inheritdoc TransferStrategyBase
  function performTransfer(
    address to,
    address reward,
    uint256 amount
  )
    external
    override(TransferStrategyBase, ITransferStrategyBase)
    onlyIncentivesController
    returns (bool)
  {
    IERC20(reward).safeTransfer(to, amount);

    return true;
  }

  /// @inheritdoc IPullRewardsTransferStrategy
  function getRewardsVault() external view returns (address) {
    return address(this);
  }
}
