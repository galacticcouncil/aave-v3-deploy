object "CollateralVault" {
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
        function internal_internal_deposit(assets) {
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
            stop()
        }
        function internal_internal_requestRedeem(shares) {
            let sender := caller()
            let currentShares := sload(mappingSlot(2, sender))
            if lt(currentShares, shares) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 26)
                mstore(68, 0x5641554c543a20696e73756666696369656e7420736861726573000000000000)
                revert(0, 100)
            }
            let currentEscrow := sload(mappingSlot(3, sender))
            if lt(add(currentEscrow, shares), currentEscrow) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 22)
                mstore(68, 0x5641554c543a20657363726f77206f766572666c6f7700000000000000000000)
                revert(0, 100)
            }
            let newEscrow := add(currentEscrow, shares)
            sstore(mappingSlot(2, sender), sub(currentShares, shares))
            sstore(mappingSlot(3, sender), newEscrow)
            stop()
        }
        function internal_internal_claim(shares) {
            let sender := caller()
            let currentEscrow := sload(mappingSlot(3, sender))
            if lt(currentEscrow, shares) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 26)
                mstore(68, 0x5641554c543a20696e73756666696369656e7420657363726f77000000000000)
                revert(0, 100)
            }
            let currentAssets := sload(0)
            if lt(currentAssets, shares) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 26)
                mstore(68, 0x5641554c543a20696e73756666696369656e7420617373657473000000000000)
                revert(0, 100)
            }
            let currentSupply := sload(1)
            if lt(currentSupply, shares) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 26)
                mstore(68, 0x5641554c543a20696e73756666696369656e7420737570706c79000000000000)
                revert(0, 100)
            }
            sstore(mappingSlot(3, sender), sub(currentEscrow, shares))
            sstore(0, sub(currentAssets, shares))
            sstore(1, sub(currentSupply, shares))
            stop()
        }
        function internal_internal_balanceOf(addr) -> __ret0 {
            let s := sload(mappingSlot(2, addr))
            __ret0 := s
            leave
        }
        function internal_internal_escrowOf(addr) -> __ret0 {
            let e := sload(mappingSlot(3, addr))
            __ret0 := e
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
            function internal_internal_deposit(assets) {
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
                stop()
            }
            function internal_internal_requestRedeem(shares) {
                let sender := caller()
                let currentShares := sload(mappingSlot(2, sender))
                if lt(currentShares, shares) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 26)
                    mstore(68, 0x5641554c543a20696e73756666696369656e7420736861726573000000000000)
                    revert(0, 100)
                }
                let currentEscrow := sload(mappingSlot(3, sender))
                if lt(add(currentEscrow, shares), currentEscrow) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 22)
                    mstore(68, 0x5641554c543a20657363726f77206f766572666c6f7700000000000000000000)
                    revert(0, 100)
                }
                let newEscrow := add(currentEscrow, shares)
                sstore(mappingSlot(2, sender), sub(currentShares, shares))
                sstore(mappingSlot(3, sender), newEscrow)
                stop()
            }
            function internal_internal_claim(shares) {
                let sender := caller()
                let currentEscrow := sload(mappingSlot(3, sender))
                if lt(currentEscrow, shares) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 26)
                    mstore(68, 0x5641554c543a20696e73756666696369656e7420657363726f77000000000000)
                    revert(0, 100)
                }
                let currentAssets := sload(0)
                if lt(currentAssets, shares) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 26)
                    mstore(68, 0x5641554c543a20696e73756666696369656e7420617373657473000000000000)
                    revert(0, 100)
                }
                let currentSupply := sload(1)
                if lt(currentSupply, shares) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 26)
                    mstore(68, 0x5641554c543a20696e73756666696369656e7420737570706c79000000000000)
                    revert(0, 100)
                }
                sstore(mappingSlot(3, sender), sub(currentEscrow, shares))
                sstore(0, sub(currentAssets, shares))
                sstore(1, sub(currentSupply, shares))
                stop()
            }
            function internal_internal_balanceOf(addr) -> __ret0 {
                let s := sload(mappingSlot(2, addr))
                __ret0 := s
                leave
            }
            function internal_internal_escrowOf(addr) -> __ret0 {
                let e := sload(mappingSlot(3, addr))
                __ret0 := e
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
                    case 0xb6b55f25 {
                        /* deposit() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        let assets := calldataload(4)
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
                        stop()
                    }
                    case 0xaa2f892d {
                        /* requestRedeem() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        let shares := calldataload(4)
                        let sender := caller()
                        let currentShares := sload(mappingSlot(2, sender))
                        if lt(currentShares, shares) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 26)
                            mstore(68, 0x5641554c543a20696e73756666696369656e7420736861726573000000000000)
                            revert(0, 100)
                        }
                        let currentEscrow := sload(mappingSlot(3, sender))
                        if lt(add(currentEscrow, shares), currentEscrow) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 22)
                            mstore(68, 0x5641554c543a20657363726f77206f766572666c6f7700000000000000000000)
                            revert(0, 100)
                        }
                        let newEscrow := add(currentEscrow, shares)
                        sstore(mappingSlot(2, sender), sub(currentShares, shares))
                        sstore(mappingSlot(3, sender), newEscrow)
                        stop()
                    }
                    case 0x379607f5 {
                        /* claim() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        let shares := calldataload(4)
                        let sender := caller()
                        let currentEscrow := sload(mappingSlot(3, sender))
                        if lt(currentEscrow, shares) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 26)
                            mstore(68, 0x5641554c543a20696e73756666696369656e7420657363726f77000000000000)
                            revert(0, 100)
                        }
                        let currentAssets := sload(0)
                        if lt(currentAssets, shares) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 26)
                            mstore(68, 0x5641554c543a20696e73756666696369656e7420617373657473000000000000)
                            revert(0, 100)
                        }
                        let currentSupply := sload(1)
                        if lt(currentSupply, shares) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 26)
                            mstore(68, 0x5641554c543a20696e73756666696369656e7420737570706c79000000000000)
                            revert(0, 100)
                        }
                        sstore(mappingSlot(3, sender), sub(currentEscrow, shares))
                        sstore(0, sub(currentAssets, shares))
                        sstore(1, sub(currentSupply, shares))
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
                    case 0xe038c3da {
                        /* escrowOf() */
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
                        let e := sload(mappingSlot(3, addr))
                        mstore(0, e)
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