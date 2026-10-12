// SPDX-License-Identifier: GPL-2.0-or-later
// `tstore`/`tload` (EIP-1153) are available in inline assembly from Solidity 0.8.24 onward, on a Cancun EVM.
pragma solidity ^0.8.24;

/// @title TransientStorage
/// @notice Thin EIP-1153 transient-storage helpers (`TSTORE` / `TLOAD`) for value types. The caller chooses the
///         slot (e.g. a `keccak256` constant); stored values live for the current transaction only and clear
///         automatically at its end. Kept type-generic so more per-transaction fields can be added over time.
/// @dev Requires an EIP-1153 (Cancun) target. Reads/writes are `memory-safe`: `TSTORE`/`TLOAD` never touch memory.
library TransientStorage {
    function tstore(bytes32 slot, bool value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function tloadBool(bytes32 slot) internal view returns (bool value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function tstore(bytes32 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function tloadUint256(bytes32 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function tstore(bytes32 slot, address value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function tloadAddress(bytes32 slot) internal view returns (address value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function tstore(bytes32 slot, int256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function tloadInt256(bytes32 slot) internal view returns (int256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
