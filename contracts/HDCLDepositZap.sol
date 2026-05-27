// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IHDCLVault {
    /// @notice ERC-4626 deposit. Pulls `assets` HOLLAR from msg.sender and
    ///         mints the corresponding shares to `receiver`.
    /// @return shares Exact number of HDCL shares minted to `receiver`.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

interface IAavePool {
    /// @notice Supply `amount` of `asset` and credit aTokens to `onBehalfOf`.
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
}

/// @title HDCLDepositZap
/// @notice Atomic single-call helper that bundles HOLLAR deposit + HDCL supply
///         into one EVM transaction.
///
///         Without this contract the UI has to predict `vault.deposit`'s mint
///         amount off-chain (via `previewDeposit`) and pass that to
///         `pool.supply` in a substrate batch. Because yield accrues between
///         the prediction and on-chain execution, the actual mint can come
///         out a few wei smaller than predicted, causing the supply step to
///         revert with insufficient balance — and `Utility.batch_all` is not
///         atomic across `evm.ExecutedFailed` so partial state can land.
///
///         By reading the exact mint return value here on-chain and passing
///         it straight to `pool.supply`, the precision gap is eliminated and
///         the whole flow either fully succeeds or fully reverts.
///
/// @dev Holds no funds between calls. The constructor pre-approves
///      `HOLLAR -> VAULT` with max allowance because the only way HOLLAR
///      enters this contract is via `transferFrom` inside `depositAndSupply`
///      and is consumed by `vault.deposit` in the same call. There's no
///      window where leftover HOLLAR sits in this contract waiting to be
///      drained, so the max approval is safe.
///
///      No HDCL allowance to POOL is set: Hydration's Aave V3 pool reaches
///      HDCL via the substrate-asset precompile, and the pool itself is on
///      the `pallet_evm_accounts::approved_contracts` whitelist, which lets
///      the precompile bypass ERC20 allowance for that spender. The supply
///      step routes through `pallet_currencies` → `Erc20Currency::transfer`
///      → `vault.transfer(aToken, amount)` from `msg.sender = this contract`.
contract HDCLDepositZap {
    IERC20 public immutable HOLLAR;
    IHDCLVault public immutable VAULT;
    IAavePool public immutable POOL;
    /// @notice Substrate-asset precompile for HDCL. The Aave reserve is
    ///         registered under this address in `getReservesList()`, so this
    ///         is the address `pool.supply` expects as the underlying.
    address public immutable HDCL_PRECOMPILE;

    error HollarTransferFailed();

    event DepositAndSupply(
        address indexed user,
        uint256 hollarAmount,
        uint256 hdclMinted
    );

    constructor(
        address _hollar,
        address _vault,
        address _pool,
        address _hdclPrecompile
    ) {
        require(_hollar != address(0), "Zero HOLLAR");
        require(_vault != address(0), "Zero VAULT");
        require(_pool != address(0), "Zero POOL");
        require(_hdclPrecompile != address(0), "Zero precompile");

        HOLLAR = IERC20(_hollar);
        VAULT = IHDCLVault(_vault);
        POOL = IAavePool(_pool);
        HDCL_PRECOMPILE = _hdclPrecompile;

        // Pre-approve HOLLAR for the vault once at deploy. Vault is fixed
        // and immutable on this contract, the approval can never be
        // redirected. Since the contract holds no HOLLAR between calls,
        // there's nothing for an attacker to extract via the allowance.
        require(
            IERC20(_hollar).approve(_vault, type(uint256).max),
            "HOLLAR approve failed"
        );
    }

    /// @notice Deposit HOLLAR -> mint HDCL -> supply HDCL as collateral, all in
    ///         one transaction. The aTokens are minted to `msg.sender` (the
    ///         caller), the underlying HDCL is held by the Aave aToken contract.
    ///
    /// @dev    The caller must first approve this contract to spend
    ///         `hollarAmount` of HOLLAR (via standard ERC20.approve, or in a
    ///         substrate batch alongside this call).
    ///
    /// @param hollarAmount  Amount of HOLLAR to deposit, in wei (18 decimals).
    function depositAndSupply(uint256 hollarAmount) external {
        // 1. Pull HOLLAR from the caller. Reverting on `false` covers any
        //    non-standard ERC20 that returns a bool instead of reverting on
        //    insufficient balance / allowance.
        if (!HOLLAR.transferFrom(msg.sender, address(this), hollarAmount)) {
            revert HollarTransferFailed();
        }

        // 2. Deposit into the vault. ERC-4626 `deposit(assets, receiver)`
        //    mints HDCL to *this* contract (receiver = address(this)) and
        //    returns the exact amount minted — no off-chain prediction
        //    needed.
        uint256 hdclMinted = VAULT.deposit(hollarAmount, address(this));

        // 3. Supply the freshly-minted HDCL into the pool, crediting the
        //    aTokens to the original caller. `pool.supply` will pull the
        //    HDCL from msg.sender (= this contract) via the precompile;
        //    no allowance is required because the pool is whitelisted in
        //    pallet_evm_accounts. See contract-level docs above.
        POOL.supply(HDCL_PRECOMPILE, hdclMinted, msg.sender, 0);

        emit DepositAndSupply(msg.sender, hollarAmount, hdclMinted);
    }
}
