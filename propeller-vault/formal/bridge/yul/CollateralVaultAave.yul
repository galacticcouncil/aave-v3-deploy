// CollateralVaultAave.deposit — Aave-wired, compiler output (Verity → Yul).
// Provenance: emitted via static-reference codegen (bypasses the CLI evalConstCheck gap) plus a
// one-line local relaxation of Verity's external-identifier check for dotted ABI externals.
// See AAVE_ECM_DIAGNOSIS.md. CEI-ordered: storage effects precede the external call() to the pool.
// Selector 0xe9c7359c = supply(address,uint256,address,uint256); real Aave V3 uses uint16
// referralCode → 0x617ba037 (the uint16→Uint256 modelling gap).

object "CollateralVaultAave" {
    code {
        mstore(64, 128)
        if callvalue() {
            revert(0, 0)
        }
        function mappingSlot(baseSlot, key) -> slot {
            mstore(0, key)
            mstore(32, baseSlot)
            slot := keccak256(0, 64)
        }
        function internal_internal_deposit(pool, asset, onBehalfOf, assets) {
            let sender := caller()
            let currentShares := sload(mappingSlot(2, sender))
            if lt(add(currentShares, assets), currentShares) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 21)
                mstore(68, 0x5641554c543a207368617265206f766572666c6f770000000000000000000000)
                revert(0, 100)
            }
            let newShares := add(currentShares, assets)
            let currentAssets := sload(0)
            if lt(add(currentAssets, assets), currentAssets) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 22)
                mstore(68, 0x5641554c543a20617373657473206f766572666c6f7700000000000000000000)
                revert(0, 100)
            }
            let newAssets := add(currentAssets, assets)
            let currentSupply := sload(1)
            if lt(add(currentSupply, assets), currentSupply) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 22)
                mstore(68, 0x5641554c543a20737570706c79206f766572666c6f7700000000000000000000)
                revert(0, 100)
            }
            let newSupply := add(currentSupply, assets)
            sstore(mappingSlot(2, sender), newShares)
            sstore(0, newAssets)
            sstore(1, newSupply)
            let _ok := 0
            {
                let __ecwr_ptr := mload(64)
                mstore(__ecwr_ptr, shl(224, 0xe9c7359c))
                mstore(add(__ecwr_ptr, 4), asset)
                mstore(add(__ecwr_ptr, 36), assets)
                mstore(add(__ecwr_ptr, 68), onBehalfOf)
                mstore(add(__ecwr_ptr, 100), 0)
                mstore(64, add(__ecwr_ptr, 160))
                let __ecwr_success := call(gas(), pool, 0, __ecwr_ptr, 132, __ecwr_ptr, 32)
                if iszero(__ecwr_success) {
                    let __ecwr_rds := returndatasize()
                    returndatacopy(0, 0, __ecwr_rds)
                    revert(0, __ecwr_rds)
                }
                if lt(returndatasize(), 32) {
                    revert(0, 0)
                }
                _ok := mload(__ecwr_ptr)
            }
            stop()
        }
        function internal_internal_balanceOf(addr) -> __ret0 {
            let s := sload(mappingSlot(2, addr))
            __ret0 := s
            leave
        }
        function internal_internal_totalAssets() -> __ret0 {
            let a := sload(0)
            __ret0 := a
            leave
        }
        function internal_internal_totalSupply() -> __ret0 {
            let t := sload(1)
            __ret0 := t
            leave
        }
        sstore(0, 0)
        sstore(1, 0)
        datacopy(0, dataoffset("runtime"), datasize("runtime"))
        return(0, datasize("runtime"))
    }
    object "runtime" {
        code {
            function mappingSlot(baseSlot, key) -> slot {
                mstore(0, key)
                mstore(32, baseSlot)
                slot := keccak256(0, 64)
            }
            function internal_internal_deposit(pool, asset, onBehalfOf, assets) {
                let sender := caller()
                let currentShares := sload(mappingSlot(2, sender))
                if lt(add(currentShares, assets), currentShares) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 21)
                    mstore(68, 0x5641554c543a207368617265206f766572666c6f770000000000000000000000)
                    revert(0, 100)
                }
                let newShares := add(currentShares, assets)
                let currentAssets := sload(0)
                if lt(add(currentAssets, assets), currentAssets) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 22)
                    mstore(68, 0x5641554c543a20617373657473206f766572666c6f7700000000000000000000)
                    revert(0, 100)
                }
                let newAssets := add(currentAssets, assets)
                let currentSupply := sload(1)
                if lt(add(currentSupply, assets), currentSupply) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 22)
                    mstore(68, 0x5641554c543a20737570706c79206f766572666c6f7700000000000000000000)
                    revert(0, 100)
                }
                let newSupply := add(currentSupply, assets)
                sstore(mappingSlot(2, sender), newShares)
                sstore(0, newAssets)
                sstore(1, newSupply)
                let _ok := 0
                {
                    let __ecwr_ptr := mload(64)
                    mstore(__ecwr_ptr, shl(224, 0xe9c7359c))
                    mstore(add(__ecwr_ptr, 4), asset)
                    mstore(add(__ecwr_ptr, 36), assets)
                    mstore(add(__ecwr_ptr, 68), onBehalfOf)
                    mstore(add(__ecwr_ptr, 100), 0)
                    mstore(64, add(__ecwr_ptr, 160))
                    let __ecwr_success := call(gas(), pool, 0, __ecwr_ptr, 132, __ecwr_ptr, 32)
                    if iszero(__ecwr_success) {
                        let __ecwr_rds := returndatasize()
                        returndatacopy(0, 0, __ecwr_rds)
                        revert(0, __ecwr_rds)
                    }
                    if lt(returndatasize(), 32) {
                        revert(0, 0)
                    }
                    _ok := mload(__ecwr_ptr)
                }
                stop()
            }
            function internal_internal_balanceOf(addr) -> __ret0 {
                let s := sload(mappingSlot(2, addr))
                __ret0 := s
                leave
            }
            function internal_internal_totalAssets() -> __ret0 {
                let a := sload(0)
                __ret0 := a
                leave
            }
            function internal_internal_totalSupply() -> __ret0 {
                let t := sload(1)
                __ret0 := t
                leave
            }
            mstore(64, 128)
            {
                let __has_selector := iszero(lt(calldatasize(), 4))
                if iszero(__has_selector) {
                    revert(0, 0)
                }
                if __has_selector {
                    switch shr(224, calldataload(0))
                    case 0x0284c3f5 {
                        /* deposit() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 132) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 132) {
                            revert(0, 0)
                        }
                        let pool := and(calldataload(4), 0xffffffffffffffffffffffffffffffffffffffff)
                        let asset := and(calldataload(36), 0xffffffffffffffffffffffffffffffffffffffff)
                        let onBehalfOf := and(calldataload(68), 0xffffffffffffffffffffffffffffffffffffffff)
                        let assets := calldataload(100)
                        let sender := caller()
                        let currentShares := sload(mappingSlot(2, sender))
                        if lt(add(currentShares, assets), currentShares) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 21)
                            mstore(68, 0x5641554c543a207368617265206f766572666c6f770000000000000000000000)
                            revert(0, 100)
                        }
                        let newShares := add(currentShares, assets)
                        let currentAssets := sload(0)
                        if lt(add(currentAssets, assets), currentAssets) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 22)
                            mstore(68, 0x5641554c543a20617373657473206f766572666c6f7700000000000000000000)
                            revert(0, 100)
                        }
                        let newAssets := add(currentAssets, assets)
                        let currentSupply := sload(1)
                        if lt(add(currentSupply, assets), currentSupply) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 22)
                            mstore(68, 0x5641554c543a20737570706c79206f766572666c6f7700000000000000000000)
                            revert(0, 100)
                        }
                        let newSupply := add(currentSupply, assets)
                        sstore(mappingSlot(2, sender), newShares)
                        sstore(0, newAssets)
                        sstore(1, newSupply)
                        let _ok := 0
                        {
                            let __ecwr_ptr := mload(64)
                            mstore(__ecwr_ptr, shl(224, 0xe9c7359c))
                            mstore(add(__ecwr_ptr, 4), asset)
                            mstore(add(__ecwr_ptr, 36), assets)
                            mstore(add(__ecwr_ptr, 68), onBehalfOf)
                            mstore(add(__ecwr_ptr, 100), 0)
                            mstore(64, add(__ecwr_ptr, 160))
                            let __ecwr_success := call(gas(), pool, 0, __ecwr_ptr, 132, __ecwr_ptr, 32)
                            if iszero(__ecwr_success) {
                                let __ecwr_rds := returndatasize()
                                returndatacopy(0, 0, __ecwr_rds)
                                revert(0, __ecwr_rds)
                            }
                            if lt(returndatasize(), 32) {
                                revert(0, 0)
                            }
                            _ok := mload(__ecwr_ptr)
                        }
                        stop()
                    }
                    case 0x70a08231 {
                        /* balanceOf() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        let addr := and(calldataload(4), 0xffffffffffffffffffffffffffffffffffffffff)
                        let s := sload(mappingSlot(2, addr))
                        mstore(0, s)
                        return(0, 32)
                    }
                    case 0x01e1d114 {
                        /* totalAssets() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        let a := sload(0)
                        mstore(0, a)
                        return(0, 32)
                    }
                    case 0x18160ddd {
                        /* totalSupply() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        let t := sload(1)
                        mstore(0, t)
                        return(0, 32)
                    }
                    default {
                        revert(0, 0)
                    }
                }
            }
        }
    }
}