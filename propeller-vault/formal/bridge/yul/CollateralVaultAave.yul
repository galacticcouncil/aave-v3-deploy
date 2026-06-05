// CollateralVaultAave — full Propeller deposit flow + unwind, compiler output (Verity → Yul).
// deposit: effects → IPool.supply + IPool.borrow + SyntheticToken.mint + SubLoop.deposit.
// pokeSettle: effects → IPool.repay + IPool.withdraw.
// Emitted by the STOCK verity-compiler CLI (verity#1951+#1952 fixes applied to the checkout).
// Selectors: Aave repay 0x573ade81 / withdraw 0x69328dec match mainnet; supply 0xe9c7359c /
// borrow 0xa2b86e7b differ (uint16→Uint256). Inter-contract mint 0x40c10f19 = mint(address,
// uint256) and SubLoop deposit 0xb6b55f25 = deposit(uint256) match our SyntheticToken/SubLoop.

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
        function internal_internal_deposit(pool, synth, loop, asset, hollar, onBehalfOf, assets, borrowAmount, synthAmount) {
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
            let currentDebt := sload(3)
            if lt(add(currentDebt, borrowAmount), currentDebt) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 20)
                mstore(68, 0x5641554c543a2064656274206f766572666c6f77000000000000000000000000)
                revert(0, 100)
            }
            let newDebt := add(currentDebt, borrowAmount)
            let currentSynth := sload(4)
            if lt(add(currentSynth, synthAmount), currentSynth) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 21)
                mstore(68, 0x5641554c543a2073796e7468206f766572666c6f770000000000000000000000)
                revert(0, 100)
            }
            let newSynth := add(currentSynth, synthAmount)
            sstore(mappingSlot(2, sender), newShares)
            sstore(0, newAssets)
            sstore(1, newSupply)
            sstore(3, newDebt)
            sstore(4, newSynth)
            let _supplied := 0
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
                _supplied := mload(__ecwr_ptr)
            }
            let _borrowed := 0
            {
                let __ecwr_ptr := mload(64)
                mstore(__ecwr_ptr, shl(224, 0xa2b86e7b))
                mstore(add(__ecwr_ptr, 4), hollar)
                mstore(add(__ecwr_ptr, 36), borrowAmount)
                mstore(add(__ecwr_ptr, 68), 2)
                mstore(add(__ecwr_ptr, 100), 0)
                mstore(add(__ecwr_ptr, 132), onBehalfOf)
                mstore(64, add(__ecwr_ptr, 192))
                let __ecwr_success := call(gas(), pool, 0, __ecwr_ptr, 164, __ecwr_ptr, 32)
                if iszero(__ecwr_success) {
                    let __ecwr_rds := returndatasize()
                    returndatacopy(0, 0, __ecwr_rds)
                    revert(0, __ecwr_rds)
                }
                if lt(returndatasize(), 32) {
                    revert(0, 0)
                }
                _borrowed := mload(__ecwr_ptr)
            }
            let _minted := 0
            {
                let __ecwr_ptr := mload(64)
                mstore(__ecwr_ptr, shl(224, 0x40c10f19))
                mstore(add(__ecwr_ptr, 4), onBehalfOf)
                mstore(add(__ecwr_ptr, 36), synthAmount)
                mstore(64, add(__ecwr_ptr, 96))
                let __ecwr_success := call(gas(), synth, 0, __ecwr_ptr, 68, __ecwr_ptr, 32)
                if iszero(__ecwr_success) {
                    let __ecwr_rds := returndatasize()
                    returndatacopy(0, 0, __ecwr_rds)
                    revert(0, __ecwr_rds)
                }
                if lt(returndatasize(), 32) {
                    revert(0, 0)
                }
                _minted := mload(__ecwr_ptr)
            }
            let _seeded := 0
            {
                let __ecwr_ptr := mload(64)
                mstore(__ecwr_ptr, shl(224, 0xb6b55f25))
                mstore(add(__ecwr_ptr, 4), borrowAmount)
                mstore(64, add(__ecwr_ptr, 64))
                let __ecwr_success := call(gas(), loop, 0, __ecwr_ptr, 36, __ecwr_ptr, 32)
                if iszero(__ecwr_success) {
                    let __ecwr_rds := returndatasize()
                    returndatacopy(0, 0, __ecwr_rds)
                    revert(0, __ecwr_rds)
                }
                if lt(returndatasize(), 32) {
                    revert(0, 0)
                }
                _seeded := mload(__ecwr_ptr)
            }
            stop()
        }
        function internal_internal_pokeSettle(pool, hollar, asset, onBehalfOf, recipient, repayAmount, withdrawAmount) {
            let currentDebt := sload(3)
            if lt(currentDebt, repayAmount) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 25)
                mstore(68, 0x5641554c543a2072657061792065786365656473206465627400000000000000)
                revert(0, 100)
            }
            let currentAssets := sload(0)
            if lt(currentAssets, withdrawAmount) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 30)
                mstore(68, 0x5641554c543a2077697468647261772065786365656473206173736574730000)
                revert(0, 100)
            }
            let currentSupply := sload(1)
            if lt(currentSupply, withdrawAmount) {
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(4, 32)
                mstore(36, 30)
                mstore(68, 0x5641554c543a207769746864726177206578636565647320737570706c790000)
                revert(0, 100)
            }
            sstore(3, sub(currentDebt, repayAmount))
            sstore(0, sub(currentAssets, withdrawAmount))
            sstore(1, sub(currentSupply, withdrawAmount))
            let _repaid := 0
            {
                let __ecwr_ptr := mload(64)
                mstore(__ecwr_ptr, shl(224, 0x573ade81))
                mstore(add(__ecwr_ptr, 4), hollar)
                mstore(add(__ecwr_ptr, 36), repayAmount)
                mstore(add(__ecwr_ptr, 68), 2)
                mstore(add(__ecwr_ptr, 100), onBehalfOf)
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
                _repaid := mload(__ecwr_ptr)
            }
            let _withdrawn := 0
            {
                let __ecwr_ptr := mload(64)
                mstore(__ecwr_ptr, shl(224, 0x69328dec))
                mstore(add(__ecwr_ptr, 4), asset)
                mstore(add(__ecwr_ptr, 36), withdrawAmount)
                mstore(add(__ecwr_ptr, 68), recipient)
                mstore(64, add(__ecwr_ptr, 128))
                let __ecwr_success := call(gas(), pool, 0, __ecwr_ptr, 100, __ecwr_ptr, 32)
                if iszero(__ecwr_success) {
                    let __ecwr_rds := returndatasize()
                    returndatacopy(0, 0, __ecwr_rds)
                    revert(0, __ecwr_rds)
                }
                if lt(returndatasize(), 32) {
                    revert(0, 0)
                }
                _withdrawn := mload(__ecwr_ptr)
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
        function internal_internal_mainDebt() -> __ret0 {
            let d := sload(3)
            __ret0 := d
            leave
        }
        sstore(0, 0)
        sstore(1, 0)
        sstore(3, 0)
        sstore(4, 0)
        datacopy(0, dataoffset("runtime"), datasize("runtime"))
        return(0, datasize("runtime"))
    }
    object "runtime" {
        code {
            /* verity linked external IPool.supply linkMode=external */
            /* verity linked external IPool.borrow linkMode=external */
            /* verity linked external IPool.repay linkMode=external */
            /* verity linked external IPool.withdraw linkMode=external */
            /* verity linked external ISynth.mint linkMode=external */
            /* verity linked external ISubLoop.deposit linkMode=external */
            function mappingSlot(baseSlot, key) -> slot {
                mstore(0, key)
                mstore(32, baseSlot)
                slot := keccak256(0, 64)
            }
            function internal_internal_deposit(pool, synth, loop, asset, hollar, onBehalfOf, assets, borrowAmount, synthAmount) {
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
                let currentDebt := sload(3)
                if lt(add(currentDebt, borrowAmount), currentDebt) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 20)
                    mstore(68, 0x5641554c543a2064656274206f766572666c6f77000000000000000000000000)
                    revert(0, 100)
                }
                let newDebt := add(currentDebt, borrowAmount)
                let currentSynth := sload(4)
                if lt(add(currentSynth, synthAmount), currentSynth) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 21)
                    mstore(68, 0x5641554c543a2073796e7468206f766572666c6f770000000000000000000000)
                    revert(0, 100)
                }
                let newSynth := add(currentSynth, synthAmount)
                sstore(mappingSlot(2, sender), newShares)
                sstore(0, newAssets)
                sstore(1, newSupply)
                sstore(3, newDebt)
                sstore(4, newSynth)
                let _supplied := 0
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
                    _supplied := mload(__ecwr_ptr)
                }
                let _borrowed := 0
                {
                    let __ecwr_ptr := mload(64)
                    mstore(__ecwr_ptr, shl(224, 0xa2b86e7b))
                    mstore(add(__ecwr_ptr, 4), hollar)
                    mstore(add(__ecwr_ptr, 36), borrowAmount)
                    mstore(add(__ecwr_ptr, 68), 2)
                    mstore(add(__ecwr_ptr, 100), 0)
                    mstore(add(__ecwr_ptr, 132), onBehalfOf)
                    mstore(64, add(__ecwr_ptr, 192))
                    let __ecwr_success := call(gas(), pool, 0, __ecwr_ptr, 164, __ecwr_ptr, 32)
                    if iszero(__ecwr_success) {
                        let __ecwr_rds := returndatasize()
                        returndatacopy(0, 0, __ecwr_rds)
                        revert(0, __ecwr_rds)
                    }
                    if lt(returndatasize(), 32) {
                        revert(0, 0)
                    }
                    _borrowed := mload(__ecwr_ptr)
                }
                let _minted := 0
                {
                    let __ecwr_ptr := mload(64)
                    mstore(__ecwr_ptr, shl(224, 0x40c10f19))
                    mstore(add(__ecwr_ptr, 4), onBehalfOf)
                    mstore(add(__ecwr_ptr, 36), synthAmount)
                    mstore(64, add(__ecwr_ptr, 96))
                    let __ecwr_success := call(gas(), synth, 0, __ecwr_ptr, 68, __ecwr_ptr, 32)
                    if iszero(__ecwr_success) {
                        let __ecwr_rds := returndatasize()
                        returndatacopy(0, 0, __ecwr_rds)
                        revert(0, __ecwr_rds)
                    }
                    if lt(returndatasize(), 32) {
                        revert(0, 0)
                    }
                    _minted := mload(__ecwr_ptr)
                }
                let _seeded := 0
                {
                    let __ecwr_ptr := mload(64)
                    mstore(__ecwr_ptr, shl(224, 0xb6b55f25))
                    mstore(add(__ecwr_ptr, 4), borrowAmount)
                    mstore(64, add(__ecwr_ptr, 64))
                    let __ecwr_success := call(gas(), loop, 0, __ecwr_ptr, 36, __ecwr_ptr, 32)
                    if iszero(__ecwr_success) {
                        let __ecwr_rds := returndatasize()
                        returndatacopy(0, 0, __ecwr_rds)
                        revert(0, __ecwr_rds)
                    }
                    if lt(returndatasize(), 32) {
                        revert(0, 0)
                    }
                    _seeded := mload(__ecwr_ptr)
                }
                stop()
            }
            function internal_internal_pokeSettle(pool, hollar, asset, onBehalfOf, recipient, repayAmount, withdrawAmount) {
                let currentDebt := sload(3)
                if lt(currentDebt, repayAmount) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 25)
                    mstore(68, 0x5641554c543a2072657061792065786365656473206465627400000000000000)
                    revert(0, 100)
                }
                let currentAssets := sload(0)
                if lt(currentAssets, withdrawAmount) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 30)
                    mstore(68, 0x5641554c543a2077697468647261772065786365656473206173736574730000)
                    revert(0, 100)
                }
                let currentSupply := sload(1)
                if lt(currentSupply, withdrawAmount) {
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(4, 32)
                    mstore(36, 30)
                    mstore(68, 0x5641554c543a207769746864726177206578636565647320737570706c790000)
                    revert(0, 100)
                }
                sstore(3, sub(currentDebt, repayAmount))
                sstore(0, sub(currentAssets, withdrawAmount))
                sstore(1, sub(currentSupply, withdrawAmount))
                let _repaid := 0
                {
                    let __ecwr_ptr := mload(64)
                    mstore(__ecwr_ptr, shl(224, 0x573ade81))
                    mstore(add(__ecwr_ptr, 4), hollar)
                    mstore(add(__ecwr_ptr, 36), repayAmount)
                    mstore(add(__ecwr_ptr, 68), 2)
                    mstore(add(__ecwr_ptr, 100), onBehalfOf)
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
                    _repaid := mload(__ecwr_ptr)
                }
                let _withdrawn := 0
                {
                    let __ecwr_ptr := mload(64)
                    mstore(__ecwr_ptr, shl(224, 0x69328dec))
                    mstore(add(__ecwr_ptr, 4), asset)
                    mstore(add(__ecwr_ptr, 36), withdrawAmount)
                    mstore(add(__ecwr_ptr, 68), recipient)
                    mstore(64, add(__ecwr_ptr, 128))
                    let __ecwr_success := call(gas(), pool, 0, __ecwr_ptr, 100, __ecwr_ptr, 32)
                    if iszero(__ecwr_success) {
                        let __ecwr_rds := returndatasize()
                        returndatacopy(0, 0, __ecwr_rds)
                        revert(0, __ecwr_rds)
                    }
                    if lt(returndatasize(), 32) {
                        revert(0, 0)
                    }
                    _withdrawn := mload(__ecwr_ptr)
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
            function internal_internal_mainDebt() -> __ret0 {
                let d := sload(3)
                __ret0 := d
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
                    case 0x5d75d427 {
                        /* deposit() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 292) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 292) {
                            revert(0, 0)
                        }
                        let pool := and(calldataload(4), 0xffffffffffffffffffffffffffffffffffffffff)
                        let synth := and(calldataload(36), 0xffffffffffffffffffffffffffffffffffffffff)
                        let loop := and(calldataload(68), 0xffffffffffffffffffffffffffffffffffffffff)
                        let asset := and(calldataload(100), 0xffffffffffffffffffffffffffffffffffffffff)
                        let hollar := and(calldataload(132), 0xffffffffffffffffffffffffffffffffffffffff)
                        let onBehalfOf := and(calldataload(164), 0xffffffffffffffffffffffffffffffffffffffff)
                        let assets := calldataload(196)
                        let borrowAmount := calldataload(228)
                        let synthAmount := calldataload(260)
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
                        let currentDebt := sload(3)
                        if lt(add(currentDebt, borrowAmount), currentDebt) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 20)
                            mstore(68, 0x5641554c543a2064656274206f766572666c6f77000000000000000000000000)
                            revert(0, 100)
                        }
                        let newDebt := add(currentDebt, borrowAmount)
                        let currentSynth := sload(4)
                        if lt(add(currentSynth, synthAmount), currentSynth) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 21)
                            mstore(68, 0x5641554c543a2073796e7468206f766572666c6f770000000000000000000000)
                            revert(0, 100)
                        }
                        let newSynth := add(currentSynth, synthAmount)
                        sstore(mappingSlot(2, sender), newShares)
                        sstore(0, newAssets)
                        sstore(1, newSupply)
                        sstore(3, newDebt)
                        sstore(4, newSynth)
                        let _supplied := 0
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
                            _supplied := mload(__ecwr_ptr)
                        }
                        let _borrowed := 0
                        {
                            let __ecwr_ptr := mload(64)
                            mstore(__ecwr_ptr, shl(224, 0xa2b86e7b))
                            mstore(add(__ecwr_ptr, 4), hollar)
                            mstore(add(__ecwr_ptr, 36), borrowAmount)
                            mstore(add(__ecwr_ptr, 68), 2)
                            mstore(add(__ecwr_ptr, 100), 0)
                            mstore(add(__ecwr_ptr, 132), onBehalfOf)
                            mstore(64, add(__ecwr_ptr, 192))
                            let __ecwr_success := call(gas(), pool, 0, __ecwr_ptr, 164, __ecwr_ptr, 32)
                            if iszero(__ecwr_success) {
                                let __ecwr_rds := returndatasize()
                                returndatacopy(0, 0, __ecwr_rds)
                                revert(0, __ecwr_rds)
                            }
                            if lt(returndatasize(), 32) {
                                revert(0, 0)
                            }
                            _borrowed := mload(__ecwr_ptr)
                        }
                        let _minted := 0
                        {
                            let __ecwr_ptr := mload(64)
                            mstore(__ecwr_ptr, shl(224, 0x40c10f19))
                            mstore(add(__ecwr_ptr, 4), onBehalfOf)
                            mstore(add(__ecwr_ptr, 36), synthAmount)
                            mstore(64, add(__ecwr_ptr, 96))
                            let __ecwr_success := call(gas(), synth, 0, __ecwr_ptr, 68, __ecwr_ptr, 32)
                            if iszero(__ecwr_success) {
                                let __ecwr_rds := returndatasize()
                                returndatacopy(0, 0, __ecwr_rds)
                                revert(0, __ecwr_rds)
                            }
                            if lt(returndatasize(), 32) {
                                revert(0, 0)
                            }
                            _minted := mload(__ecwr_ptr)
                        }
                        let _seeded := 0
                        {
                            let __ecwr_ptr := mload(64)
                            mstore(__ecwr_ptr, shl(224, 0xb6b55f25))
                            mstore(add(__ecwr_ptr, 4), borrowAmount)
                            mstore(64, add(__ecwr_ptr, 64))
                            let __ecwr_success := call(gas(), loop, 0, __ecwr_ptr, 36, __ecwr_ptr, 32)
                            if iszero(__ecwr_success) {
                                let __ecwr_rds := returndatasize()
                                returndatacopy(0, 0, __ecwr_rds)
                                revert(0, __ecwr_rds)
                            }
                            if lt(returndatasize(), 32) {
                                revert(0, 0)
                            }
                            _seeded := mload(__ecwr_ptr)
                        }
                        stop()
                    }
                    case 0xde572de4 {
                        /* pokeSettle() */
                        if callvalue() {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 228) {
                            revert(0, 0)
                        }
                        if lt(calldatasize(), 228) {
                            revert(0, 0)
                        }
                        let pool := and(calldataload(4), 0xffffffffffffffffffffffffffffffffffffffff)
                        let hollar := and(calldataload(36), 0xffffffffffffffffffffffffffffffffffffffff)
                        let asset := and(calldataload(68), 0xffffffffffffffffffffffffffffffffffffffff)
                        let onBehalfOf := and(calldataload(100), 0xffffffffffffffffffffffffffffffffffffffff)
                        let recipient := and(calldataload(132), 0xffffffffffffffffffffffffffffffffffffffff)
                        let repayAmount := calldataload(164)
                        let withdrawAmount := calldataload(196)
                        let currentDebt := sload(3)
                        if lt(currentDebt, repayAmount) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 25)
                            mstore(68, 0x5641554c543a2072657061792065786365656473206465627400000000000000)
                            revert(0, 100)
                        }
                        let currentAssets := sload(0)
                        if lt(currentAssets, withdrawAmount) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 30)
                            mstore(68, 0x5641554c543a2077697468647261772065786365656473206173736574730000)
                            revert(0, 100)
                        }
                        let currentSupply := sload(1)
                        if lt(currentSupply, withdrawAmount) {
                            mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                            mstore(4, 32)
                            mstore(36, 30)
                            mstore(68, 0x5641554c543a207769746864726177206578636565647320737570706c790000)
                            revert(0, 100)
                        }
                        sstore(3, sub(currentDebt, repayAmount))
                        sstore(0, sub(currentAssets, withdrawAmount))
                        sstore(1, sub(currentSupply, withdrawAmount))
                        let _repaid := 0
                        {
                            let __ecwr_ptr := mload(64)
                            mstore(__ecwr_ptr, shl(224, 0x573ade81))
                            mstore(add(__ecwr_ptr, 4), hollar)
                            mstore(add(__ecwr_ptr, 36), repayAmount)
                            mstore(add(__ecwr_ptr, 68), 2)
                            mstore(add(__ecwr_ptr, 100), onBehalfOf)
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
                            _repaid := mload(__ecwr_ptr)
                        }
                        let _withdrawn := 0
                        {
                            let __ecwr_ptr := mload(64)
                            mstore(__ecwr_ptr, shl(224, 0x69328dec))
                            mstore(add(__ecwr_ptr, 4), asset)
                            mstore(add(__ecwr_ptr, 36), withdrawAmount)
                            mstore(add(__ecwr_ptr, 68), recipient)
                            mstore(64, add(__ecwr_ptr, 128))
                            let __ecwr_success := call(gas(), pool, 0, __ecwr_ptr, 100, __ecwr_ptr, 32)
                            if iszero(__ecwr_success) {
                                let __ecwr_rds := returndatasize()
                                returndatacopy(0, 0, __ecwr_rds)
                                revert(0, __ecwr_rds)
                            }
                            if lt(returndatasize(), 32) {
                                revert(0, 0)
                            }
                            _withdrawn := mload(__ecwr_ptr)
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
                    default {
                        revert(0, 0)
                    }
                }
            }
        }
    }
}