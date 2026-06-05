// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title SyntheticToken
/// @notice Propeller's synthetic collateral. Minted 1:1 against a Main
///         position's HOLLAR debt and supplied to the Aave money market so the
///         position's health factor is decoupled from collateral price — the
///         principal becomes un-liquidatable. Priced $1 by a fixed oracle and
///         registered as an Aave reserve with **LTV 0 / LT ~98% / borrowing
///         disabled / non-isolation** (lifts HF, grants zero borrow power).
///
/// @dev    Mint/burn are gated to MINTER_ROLE (the CollateralVaults). The token
///         is "soulbound by custody": only Propeller contracts ever hold
///         MINTER_ROLE, mint it, and supply it to Aave — it never reaches an
///         open holder. Standard ERC20 transfers remain enabled because Aave's
///         aToken pulls the underlying via `transferFrom` on `supply`. A
///         transfer allowlist can be layered later if governance wants hard
///         soulbinding (see _update hook note).
contract SyntheticToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    error ZeroAddress();

    constructor(string memory name_, string memory symbol_, address admin)
        ERC20(name_, symbol_)
    {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice HOLLAR is 18-dp; the synthetic is priced 1:1 with HOLLAR debt, so
    ///         it carries 18 decimals to match the debt unit.
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Mint synthetic to a vault. Only callable by MINTER_ROLE.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burn synthetic from a holder. Only callable by MINTER_ROLE.
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }

    // NOTE(soulbinding): to hard-restrict transfers to Propeller/Aave addresses,
    // override `_update(from, to, value)` to require from==0 || to==0 ||
    // hasRole(MINTER_ROLE, msg.sender) || isAllowlisted[from] || isAllowlisted[to].
    // Left as standard ERC20 in the scaffold to keep Aave `supply` compatibility
    // straightforward; revisit before audit.
}
