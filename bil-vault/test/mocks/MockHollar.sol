// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockHollar is ERC20 {
    /// @dev Test-only blocklist. When set, transfers to/from the address
    /// revert — simulates USDC/USDT-style sanctions/blacklist behavior.
    mapping(address => bool) public blocked;

    constructor() ERC20("HOLLAR", "HOLLAR") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        override
    {
        require(!blocked[from], "MockHollar: from blocked");
        require(!blocked[to], "MockHollar: to blocked");
        super._beforeTokenTransfer(from, to, amount);
    }
}
