object "Harvester" {
    code {
        mstore(64, 128)
        if callvalue() {
            revert(0, 0)
        }
        function internal_internal_maintainPeg() {
            let debt := sload(3)
            sstore(2, debt)
            stop()
        }
        function internal_internal_deLever() {
            let h := sload(0)
            let trig := sload(1)
            if gt(h, trig) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 31)
                mstore(68, 0x484152563a206c6f6f70206865616c7468792c206e6f2064652d6c6576657200)
                revert(0, 100)
            }
            sstore(0, trig)
            stop()
        }
        function internal_internal_subHealth() -> __ret0 {
            let h := sload(0)
            __ret0 := h
            leave
        }
        function internal_internal_synthValue() -> __ret0 {
            let v := sload(2)
            __ret0 := v
            leave
        }
        function internal_internal_mainDebt() -> __ret0 {
            let d := sload(3)
            __ret0 := d
            leave
        }
        function internal_internal_deLeverTrigger() -> __ret0 {
            let t := sload(1)
            __ret0 := t
            leave
        }
        let argsOffset := add(dataoffset("runtime"), datasize("runtime"))
        let argsSize := sub(codesize(), argsOffset)
        codecopy(0, argsOffset, argsSize)
        if lt(argsSize, 32) {
            revert(0, 0)
        }
        let trigger := mload(0)
        let arg0 := trigger
        sstore(1, trigger)
        sstore(0, 0)
        sstore(2, 0)
        sstore(3, 0)
        datacopy(0, dataoffset("runtime"), datasize("runtime"))
        return(0, datasize("runtime"))
    }
    object "runtime" {
        code {
            function internal_internal_maintainPeg() {
                let debt := sload(3)
                sstore(2, debt)
                stop()
            }
            function internal_internal_deLever() {
                let h := sload(0)
                let trig := sload(1)
                if gt(h, trig) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 31)
                    mstore(68, 0x484152563a206c6f6f70206865616c7468792c206e6f2064652d6c6576657200)
                    revert(0, 100)
                }
                sstore(0, trig)
                stop()
            }
            function internal_internal_subHealth() -> __ret0 {
                let h := sload(0)
                __ret0 := h
                leave
            }
            function internal_internal_synthValue() -> __ret0 {
                let v := sload(2)
                __ret0 := v
                leave
            }
            function internal_internal_mainDebt() -> __ret0 {
                let d := sload(3)
                __ret0 := d
                leave
            }
            function internal_internal_deLeverTrigger() -> __ret0 {
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
                    case 0xeebca7b6 {
                        /* maintainPeg() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        let debt := sload(3)
                        sstore(2, debt)
                        stop()
                    }
                    case 0xf970ce69 {
                        /* deLever() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        let h := sload(0)
                        let trig := sload(1)
                        if gt(h, trig) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 31)
                            mstore(68, 0x484152563a206c6f6f70206865616c7468792c206e6f2064652d6c6576657200)
                            revert(0, 100)
                        }
                        sstore(0, trig)
                        stop()
                    }
                    case 0x50e3bbfb {
                        /* subHealth() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        let h := sload(0)
                        mstore(0, h)
                        return(0, 32)
                    }
                    case 0x82527c77 {
                        /* synthValue() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        let v := sload(2)
                        mstore(0, v)
                        return(0, 32)
                    }
                    case 0x28d79e05 {
                        /* mainDebt() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 4) {
                            revert(0, 0)
                        }
                        let d := sload(3)
                        mstore(0, d)
                        return(0, 32)
                    }
                    case 0x67cf84a9 {
                        /* deLeverTrigger() */
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