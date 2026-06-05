object "SyntheticToken" {
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
        function internal_internal_mint(toAddr, amount) {
            let sender := caller()
            let vault := sload(0)
            if iszero(eq(sender, vault)) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 17)
                mstore(68, 0x53594e54483a206f6e6c79207661756c74000000000000000000000000000000)
                revert(0, 100)
            }
            let currentBalance := sload(mappingSlot(2, toAddr))
            if lt(add(currentBalance, amount), currentBalance) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 23)
                mstore(68, 0x53594e54483a2062616c616e6365206f766572666c6f77000000000000000000)
                revert(0, 100)
            }
            let newBalance := add(currentBalance, amount)
            let currentSupply := sload(1)
            if lt(add(currentSupply, amount), currentSupply) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 22)
                mstore(68, 0x53594e54483a20737570706c79206f766572666c6f7700000000000000000000)
                revert(0, 100)
            }
            let newSupply := add(currentSupply, amount)
            sstore(mappingSlot(2, toAddr), newBalance)
            sstore(1, newSupply)
            stop()
        }
        function internal_internal_burn(fromAddr, amount) {
            let sender := caller()
            let vault := sload(0)
            if iszero(eq(sender, vault)) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 17)
                mstore(68, 0x53594e54483a206f6e6c79207661756c74000000000000000000000000000000)
                revert(0, 100)
            }
            let currentBalance := sload(mappingSlot(2, fromAddr))
            if lt(currentBalance, amount) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 27)
                mstore(68, 0x53594e54483a206275726e20657863656564732062616c616e63650000000000)
                revert(0, 100)
            }
            let currentSupply := sload(1)
            sstore(mappingSlot(2, fromAddr), sub(currentBalance, amount))
            sstore(1, sub(currentSupply, amount))
            stop()
        }
        function internal_internal_balanceOf(addr) -> __ret0 {
            let currentBalance := sload(mappingSlot(2, addr))
            __ret0 := currentBalance
            leave
        }
        function internal_internal_totalSupply() -> __ret0 {
            let currentSupply := sload(1)
            __ret0 := currentSupply
            leave
        }
        function internal_internal_vault() -> __ret0 {
            let v := sload(0)
            __ret0 := v
            leave
        }
        let argsOffset := add(dataoffset("runtime"), datasize("runtime"))
        let argsSize := sub(codesize(), argsOffset)
        codecopy(0, argsOffset, argsSize)
        if lt(argsSize, 32) {
            revert(0, 0)
        }
        let vault := and(mload(0), 0xffffffffffffffffffffffffffffffffffffffff)
        let arg0 := vault
        sstore(0, and(vault, 0xffffffffffffffffffffffffffffffffffffffff))
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
            function internal_internal_mint(toAddr, amount) {
                let sender := caller()
                let vault := sload(0)
                if iszero(eq(sender, vault)) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 17)
                    mstore(68, 0x53594e54483a206f6e6c79207661756c74000000000000000000000000000000)
                    revert(0, 100)
                }
                let currentBalance := sload(mappingSlot(2, toAddr))
                if lt(add(currentBalance, amount), currentBalance) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 23)
                    mstore(68, 0x53594e54483a2062616c616e6365206f766572666c6f77000000000000000000)
                    revert(0, 100)
                }
                let newBalance := add(currentBalance, amount)
                let currentSupply := sload(1)
                if lt(add(currentSupply, amount), currentSupply) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 22)
                    mstore(68, 0x53594e54483a20737570706c79206f766572666c6f7700000000000000000000)
                    revert(0, 100)
                }
                let newSupply := add(currentSupply, amount)
                sstore(mappingSlot(2, toAddr), newBalance)
                sstore(1, newSupply)
                stop()
            }
            function internal_internal_burn(fromAddr, amount) {
                let sender := caller()
                let vault := sload(0)
                if iszero(eq(sender, vault)) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 17)
                    mstore(68, 0x53594e54483a206f6e6c79207661756c74000000000000000000000000000000)
                    revert(0, 100)
                }
                let currentBalance := sload(mappingSlot(2, fromAddr))
                if lt(currentBalance, amount) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 27)
                    mstore(68, 0x53594e54483a206275726e20657863656564732062616c616e63650000000000)
                    revert(0, 100)
                }
                let currentSupply := sload(1)
                sstore(mappingSlot(2, fromAddr), sub(currentBalance, amount))
                sstore(1, sub(currentSupply, amount))
                stop()
            }
            function internal_internal_balanceOf(addr) -> __ret0 {
                let currentBalance := sload(mappingSlot(2, addr))
                __ret0 := currentBalance
                leave
            }
            function internal_internal_totalSupply() -> __ret0 {
                let currentSupply := sload(1)
                __ret0 := currentSupply
                leave
            }
            function internal_internal_vault() -> __ret0 {
                let v := sload(0)
                __ret0 := v
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
                    case 0x40c10f19 {
                        /* mint() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 68) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 68) {
                            revert(0, 0)
                        }
                        let toAddr := and(calldataload(4), 0xffffffffffffffffffffffffffffffffffffffff)
                        let amount := calldataload(36)
                        let sender := caller()
                        let vault := sload(0)
                        if iszero(eq(sender, vault)) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 17)
                            mstore(68, 0x53594e54483a206f6e6c79207661756c74000000000000000000000000000000)
                            revert(0, 100)
                        }
                        let currentBalance := sload(mappingSlot(2, toAddr))
                        if lt(add(currentBalance, amount), currentBalance) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 23)
                            mstore(68, 0x53594e54483a2062616c616e6365206f766572666c6f77000000000000000000)
                            revert(0, 100)
                        }
                        let newBalance := add(currentBalance, amount)
                        let currentSupply := sload(1)
                        if lt(add(currentSupply, amount), currentSupply) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 22)
                            mstore(68, 0x53594e54483a20737570706c79206f766572666c6f7700000000000000000000)
                            revert(0, 100)
                        }
                        let newSupply := add(currentSupply, amount)
                        sstore(mappingSlot(2, toAddr), newBalance)
                        sstore(1, newSupply)
                        stop()
                    }
                    case 0x9dc29fac {
                        /* burn() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 68) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 68) {
                            revert(0, 0)
                        }
                        let fromAddr := and(calldataload(4), 0xffffffffffffffffffffffffffffffffffffffff)
                        let amount := calldataload(36)
                        let sender := caller()
                        let vault := sload(0)
                        if iszero(eq(sender, vault)) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 17)
                            mstore(68, 0x53594e54483a206f6e6c79207661756c74000000000000000000000000000000)
                            revert(0, 100)
                        }
                        let currentBalance := sload(mappingSlot(2, fromAddr))
                        if lt(currentBalance, amount) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 27)
                            mstore(68, 0x53594e54483a206275726e20657863656564732062616c616e63650000000000)
                            revert(0, 100)
                        }
                        let currentSupply := sload(1)
                        sstore(mappingSlot(2, fromAddr), sub(currentBalance, amount))
                        sstore(1, sub(currentSupply, amount))
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
                        let currentBalance := sload(mappingSlot(2, addr))
                        mstore(0, currentBalance)
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
                        let currentSupply := sload(1)
                        mstore(0, currentSupply)
                        return(0, 32)
                    }
                    case 0xfbfa77cf {
                        /* vault() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        let v := sload(0)
                        mstore(0, v)
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