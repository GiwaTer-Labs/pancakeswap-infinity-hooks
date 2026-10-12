// SPDX-License-Identifier: GPL-2.0-or-later
// Transient storage (`tstore`/`tload`, EIP-1153) requires Solidity >= 0.8.24 on a Cancun EVM. Pinned to 0.8.26
// to match the infinity-core dependency (which pins `pragma solidity 0.8.26`).
pragma solidity 0.8.26;

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {CurrencySettler} from "./libraries/CurrencySettler.sol";
import {CLSharedInventoryHookBase} from "./CLSharedInventoryHookBase.sol";

/// @title CLSharedInventoryHook
/// @notice The standard, self-custody implementation of {CLSharedInventoryHookBase}: inventory is simply the hook's
///         own live token balance. This is the concrete contract to deploy for the ordinary shared-inventory
///         market maker.
/// @dev It implements the abstract custody extension points ({_balanceOf}, {_settleToVault}, {_takeFromVault},
///      {_payOut}) with direct token-balance operations, so its behavior is byte-for-byte identical to the original
///      monolithic hook: funds are held by the hook itself, paid to the vault straight from that balance, taken back
///      into it, and withdrawn from it. To custody inventory elsewhere instead — e.g. routing idle funds into a
///      yield vault — subclass {CLSharedInventoryHookBase} directly and override the same four hooks; the JIT
///      lifecycle, config, controls and solvency checks all live in the base and need no changes.
contract CLSharedInventoryHook is CLSharedInventoryHookBase {
    using CurrencySettler for Currency;

    /// @param _poolManager the Infinity CL pool manager this hook binds to
    /// @param _owner the initial owner (Ownable2Step); reverts (via Ownable) if zero.
    constructor(ICLPoolManager _poolManager, address _owner) CLSharedInventoryHookBase(_poolManager, _owner) {}

    /// @inheritdoc CLSharedInventoryHookBase
    /// @dev The hook's live balance of `currency` (native-aware). This IS the available inventory.
    function _balanceOf(Currency currency) internal view override returns (uint256) {
        return currency.balanceOfSelf();
    }

    /// @inheritdoc CLSharedInventoryHookBase
    /// @dev Pays straight from the hook's own balance into the vault via flash-accounting `settle`.
    function _settleToVault(Currency currency, uint256 amount) internal override {
        currency.settle(vault, address(this), amount, false);
    }

    /// @inheritdoc CLSharedInventoryHookBase
    /// @dev Receives straight into the hook's own balance via flash-accounting `take`.
    function _takeFromVault(Currency currency, uint256 amount) internal override {
        vault.take(currency, address(this), amount);
    }

    /// @inheritdoc CLSharedInventoryHookBase
    /// @dev Sends from the hook's own balance. `Currency.transfer` is native-aware and reverts on insufficient
    ///      balance.
    function _payOut(Currency currency, address to, uint256 amount) internal override {
        currency.transfer(to, amount);
    }
}
