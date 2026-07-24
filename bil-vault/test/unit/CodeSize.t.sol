// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {BILVault} from "../../src/BILVault.sol";

/// @title EIP-170 deploy-size guard
/// @notice Foundry's test EVM does NOT enforce the EIP-170 24,576-byte
///         runtime code-size cap on `CREATE`, so an over-limit contract
///         compiles and passes every behavioural test — then fails to deploy
///         on any real chain (the impl `CREATE` hits max-code-size, burns all
///         gas, and the proxy initialize reverts). This test closes that gap:
///         it deploys the impl in-EVM (allowed, unenforced), measures the
///         actual runtime bytecode length, and fails the suite if it exceeds
///         the limit. Run before any deploy — a red bar here means "will not
///         deploy," caught in CI instead of on a fork.
contract CodeSizeTest is Test {
    /// @dev EIP-170 runtime code-size cap.
    uint256 internal constant EIP170_LIMIT = 24_576;

    function test_BILVault_fitsEip170() public {
        // Foundry auto-deploys + links QueueLib for `new BILVault()`, so the
        // measured code is the real, library-linked runtime that ships.
        BILVault impl = new BILVault();
        uint256 size = address(impl).code.length;

        emit log_named_uint("BILVault runtime bytes", size);
        emit log_named_uint("EIP-170 limit         ", EIP170_LIMIT);
        if (size <= EIP170_LIMIT) {
            emit log_named_uint("headroom bytes        ", EIP170_LIMIT - size);
        } else {
            emit log_named_uint("OVER BY bytes         ", size - EIP170_LIMIT);
        }

        assertLe(
            size,
            EIP170_LIMIT,
            "BILVault runtime code exceeds EIP-170 24576-byte limit -- will NOT deploy on-chain"
        );
    }
}
