// SubLoop — PRIME-isolation loop + deploy-side controller guard on the pokes.
// constructor stores the controller (keeper/harvester); pokeBorrow/pokeRepay are onlyController.
// equity-neutrality (primeAmt-subDebt invariant) proven on the authorized path; pokes revert
// for a non-controller caller. stock verity-compiler output.

object "SubLoop" {
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
        function internal_internal_deposit(seed) {
            let sender := caller()
            let currentShares := sload(mappingSlot(3, sender))
            if lt(add(currentShares, seed), currentShares) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 20)
                mstore(68, 0x4c4f4f503a207368617265206f766572666c6f77000000000000000000000000)
                revert(0, 100)
            }
            let newShares := add(currentShares, seed)
            let currentPrime := sload(0)
            if lt(add(currentPrime, seed), currentPrime) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 20)
                mstore(68, 0x4c4f4f503a207072696d65206f766572666c6f77000000000000000000000000)
                revert(0, 100)
            }
            let newPrime := add(currentPrime, seed)
            let currentSupply := sload(2)
            if lt(add(currentSupply, seed), currentSupply) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 21)
                mstore(68, 0x4c4f4f503a20737570706c79206f766572666c6f770000000000000000000000)
                revert(0, 100)
            }
            let newSupply := add(currentSupply, seed)
            sstore(mappingSlot(3, sender), newShares)
            sstore(0, newPrime)
            sstore(2, newSupply)
            stop()
        }
        function internal_internal_pokeBorrow(amount) {
            let sender := caller()
            let ctrl := sload(4)
            if iszero(eq(sender, ctrl)) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 21)
                mstore(68, 0x4c4f4f503a206f6e6c7920636f6e74726f6c6c65720000000000000000000000)
                revert(0, 100)
            }
            let currentPrime := sload(0)
            if lt(add(currentPrime, amount), currentPrime) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 20)
                mstore(68, 0x4c4f4f503a207072696d65206f766572666c6f77000000000000000000000000)
                revert(0, 100)
            }
            let newPrime := add(currentPrime, amount)
            let currentDebt := sload(1)
            if lt(add(currentDebt, amount), currentDebt) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 19)
                mstore(68, 0x4c4f4f503a2064656274206f766572666c6f7700000000000000000000000000)
                revert(0, 100)
            }
            let newDebt := add(currentDebt, amount)
            sstore(0, newPrime)
            sstore(1, newDebt)
            stop()
        }
        function internal_internal_pokeRepay(amount) {
            let sender := caller()
            let ctrl := sload(4)
            if iszero(eq(sender, ctrl)) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 21)
                mstore(68, 0x4c4f4f503a206f6e6c7920636f6e74726f6c6c65720000000000000000000000)
                revert(0, 100)
            }
            let currentPrime := sload(0)
            if lt(currentPrime, amount) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 21)
                mstore(68, 0x4c4f4f503a207072696d6520756e646572666c6f770000000000000000000000)
                revert(0, 100)
            }
            let currentDebt := sload(1)
            if lt(currentDebt, amount) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 20)
                mstore(68, 0x4c4f4f503a206465627420756e646572666c6f77000000000000000000000000)
                revert(0, 100)
            }
            sstore(0, sub(currentPrime, amount))
            sstore(1, sub(currentDebt, amount))
            stop()
        }
        function internal_internal_requestUnwind(shares) {
            let sender := caller()
            let currentShares := sload(mappingSlot(3, sender))
            if lt(currentShares, shares) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 25)
                mstore(68, 0x4c4f4f503a20696e73756666696369656e742073686172657300000000000000)
                revert(0, 100)
            }
            let currentSupply := sload(2)
            if lt(currentSupply, shares) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 25)
                mstore(68, 0x4c4f4f503a20696e73756666696369656e7420737570706c7900000000000000)
                revert(0, 100)
            }
            sstore(mappingSlot(3, sender), sub(currentShares, shares))
            sstore(2, sub(currentSupply, shares))
            stop()
        }
        function internal_internal_primeAmt() -> __ret0 {
            let p := sload(0)
            __ret0 := p
            leave
        }
        function internal_internal_subDebt() -> __ret0 {
            let d := sload(1)
            __ret0 := d
            leave
        }
        function internal_internal_totalShares() -> __ret0 {
            let t := sload(2)
            __ret0 := t
            leave
        }
        function internal_internal_balanceOf(addr) -> __ret0 {
            let s := sload(mappingSlot(3, addr))
            __ret0 := s
            leave
        }
        let argsOffset := add(dataoffset("runtime"), datasize("runtime"))
        let argsSize := sub(codesize(), argsOffset)
        codecopy(0, argsOffset, argsSize)
        if lt(argsSize, 32) {
            revert(0, 0)
        }
        let controller := and(mload(0), 0xffffffffffffffffffffffffffffffffffffffff)
        let arg0 := controller
        sstore(0, 0)
        sstore(1, 0)
        sstore(2, 0)
        sstore(4, and(controller, 0xffffffffffffffffffffffffffffffffffffffff))
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
            function internal_internal_deposit(seed) {
                let sender := caller()
                let currentShares := sload(mappingSlot(3, sender))
                if lt(add(currentShares, seed), currentShares) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 20)
                    mstore(68, 0x4c4f4f503a207368617265206f766572666c6f77000000000000000000000000)
                    revert(0, 100)
                }
                let newShares := add(currentShares, seed)
                let currentPrime := sload(0)
                if lt(add(currentPrime, seed), currentPrime) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 20)
                    mstore(68, 0x4c4f4f503a207072696d65206f766572666c6f77000000000000000000000000)
                    revert(0, 100)
                }
                let newPrime := add(currentPrime, seed)
                let currentSupply := sload(2)
                if lt(add(currentSupply, seed), currentSupply) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 21)
                    mstore(68, 0x4c4f4f503a20737570706c79206f766572666c6f770000000000000000000000)
                    revert(0, 100)
                }
                let newSupply := add(currentSupply, seed)
                sstore(mappingSlot(3, sender), newShares)
                sstore(0, newPrime)
                sstore(2, newSupply)
                stop()
            }
            function internal_internal_pokeBorrow(amount) {
                let sender := caller()
                let ctrl := sload(4)
                if iszero(eq(sender, ctrl)) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 21)
                    mstore(68, 0x4c4f4f503a206f6e6c7920636f6e74726f6c6c65720000000000000000000000)
                    revert(0, 100)
                }
                let currentPrime := sload(0)
                if lt(add(currentPrime, amount), currentPrime) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 20)
                    mstore(68, 0x4c4f4f503a207072696d65206f766572666c6f77000000000000000000000000)
                    revert(0, 100)
                }
                let newPrime := add(currentPrime, amount)
                let currentDebt := sload(1)
                if lt(add(currentDebt, amount), currentDebt) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 19)
                    mstore(68, 0x4c4f4f503a2064656274206f766572666c6f7700000000000000000000000000)
                    revert(0, 100)
                }
                let newDebt := add(currentDebt, amount)
                sstore(0, newPrime)
                sstore(1, newDebt)
                stop()
            }
            function internal_internal_pokeRepay(amount) {
                let sender := caller()
                let ctrl := sload(4)
                if iszero(eq(sender, ctrl)) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 21)
                    mstore(68, 0x4c4f4f503a206f6e6c7920636f6e74726f6c6c65720000000000000000000000)
                    revert(0, 100)
                }
                let currentPrime := sload(0)
                if lt(currentPrime, amount) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 21)
                    mstore(68, 0x4c4f4f503a207072696d6520756e646572666c6f770000000000000000000000)
                    revert(0, 100)
                }
                let currentDebt := sload(1)
                if lt(currentDebt, amount) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 20)
                    mstore(68, 0x4c4f4f503a206465627420756e646572666c6f77000000000000000000000000)
                    revert(0, 100)
                }
                sstore(0, sub(currentPrime, amount))
                sstore(1, sub(currentDebt, amount))
                stop()
            }
            function internal_internal_requestUnwind(shares) {
                let sender := caller()
                let currentShares := sload(mappingSlot(3, sender))
                if lt(currentShares, shares) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 25)
                    mstore(68, 0x4c4f4f503a20696e73756666696369656e742073686172657300000000000000)
                    revert(0, 100)
                }
                let currentSupply := sload(2)
                if lt(currentSupply, shares) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 25)
                    mstore(68, 0x4c4f4f503a20696e73756666696369656e7420737570706c7900000000000000)
                    revert(0, 100)
                }
                sstore(mappingSlot(3, sender), sub(currentShares, shares))
                sstore(2, sub(currentSupply, shares))
                stop()
            }
            function internal_internal_primeAmt() -> __ret0 {
                let p := sload(0)
                __ret0 := p
                leave
            }
            function internal_internal_subDebt() -> __ret0 {
                let d := sload(1)
                __ret0 := d
                leave
            }
            function internal_internal_totalShares() -> __ret0 {
                let t := sload(2)
                __ret0 := t
                leave
            }
            function internal_internal_balanceOf(addr) -> __ret0 {
                let s := sload(mappingSlot(3, addr))
                __ret0 := s
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
                        let seed := calldataload(4)
                        let sender := caller()
                        let currentShares := sload(mappingSlot(3, sender))
                        if lt(add(currentShares, seed), currentShares) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 20)
                            mstore(68, 0x4c4f4f503a207368617265206f766572666c6f77000000000000000000000000)
                            revert(0, 100)
                        }
                        let newShares := add(currentShares, seed)
                        let currentPrime := sload(0)
                        if lt(add(currentPrime, seed), currentPrime) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 20)
                            mstore(68, 0x4c4f4f503a207072696d65206f766572666c6f77000000000000000000000000)
                            revert(0, 100)
                        }
                        let newPrime := add(currentPrime, seed)
                        let currentSupply := sload(2)
                        if lt(add(currentSupply, seed), currentSupply) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 21)
                            mstore(68, 0x4c4f4f503a20737570706c79206f766572666c6f770000000000000000000000)
                            revert(0, 100)
                        }
                        let newSupply := add(currentSupply, seed)
                        sstore(mappingSlot(3, sender), newShares)
                        sstore(0, newPrime)
                        sstore(2, newSupply)
                        stop()
                    }
                    case 0x388f76ac {
                        /* pokeBorrow() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        let amount := calldataload(4)
                        let sender := caller()
                        let ctrl := sload(4)
                        if iszero(eq(sender, ctrl)) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 21)
                            mstore(68, 0x4c4f4f503a206f6e6c7920636f6e74726f6c6c65720000000000000000000000)
                            revert(0, 100)
                        }
                        let currentPrime := sload(0)
                        if lt(add(currentPrime, amount), currentPrime) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 20)
                            mstore(68, 0x4c4f4f503a207072696d65206f766572666c6f77000000000000000000000000)
                            revert(0, 100)
                        }
                        let newPrime := add(currentPrime, amount)
                        let currentDebt := sload(1)
                        if lt(add(currentDebt, amount), currentDebt) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 19)
                            mstore(68, 0x4c4f4f503a2064656274206f766572666c6f7700000000000000000000000000)
                            revert(0, 100)
                        }
                        let newDebt := add(currentDebt, amount)
                        sstore(0, newPrime)
                        sstore(1, newDebt)
                        stop()
                    }
                    case 0xc858d9d4 {
                        /* pokeRepay() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 36) {
                            revert(0, 0)
                        }
                        let amount := calldataload(4)
                        let sender := caller()
                        let ctrl := sload(4)
                        if iszero(eq(sender, ctrl)) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 21)
                            mstore(68, 0x4c4f4f503a206f6e6c7920636f6e74726f6c6c65720000000000000000000000)
                            revert(0, 100)
                        }
                        let currentPrime := sload(0)
                        if lt(currentPrime, amount) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 21)
                            mstore(68, 0x4c4f4f503a207072696d6520756e646572666c6f770000000000000000000000)
                            revert(0, 100)
                        }
                        let currentDebt := sload(1)
                        if lt(currentDebt, amount) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 20)
                            mstore(68, 0x4c4f4f503a206465627420756e646572666c6f77000000000000000000000000)
                            revert(0, 100)
                        }
                        sstore(0, sub(currentPrime, amount))
                        sstore(1, sub(currentDebt, amount))
                        stop()
                    }
                    case 0xca64972c {
                        /* requestUnwind() */
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
                        let currentShares := sload(mappingSlot(3, sender))
                        if lt(currentShares, shares) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 25)
                            mstore(68, 0x4c4f4f503a20696e73756666696369656e742073686172657300000000000000)
                            revert(0, 100)
                        }
                        let currentSupply := sload(2)
                        if lt(currentSupply, shares) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 25)
                            mstore(68, 0x4c4f4f503a20696e73756666696369656e7420737570706c7900000000000000)
                            revert(0, 100)
                        }
                        sstore(mappingSlot(3, sender), sub(currentShares, shares))
                        sstore(2, sub(currentSupply, shares))
                        stop()
                    }
                    case 0x4d1dce0a {
                        /* primeAmt() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        let p := sload(0)
                        mstore(0, p)
                        return(0, 32)
                    }
                    case 0x05a63998 {
                        /* subDebt() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        let d := sload(1)
                        mstore(0, d)
                        return(0, 32)
                    }
                    case 0x3a98ef39 {
                        /* totalShares() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        let t := sload(2)
                        mstore(0, t)
                        return(0, 32)
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
                        let s := sload(mappingSlot(3, addr))
                        mstore(0, s)
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