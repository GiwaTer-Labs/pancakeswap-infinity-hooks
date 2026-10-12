// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Library used to interact with the `Vault` to settle any open deltas.
 * To settle a positive delta (a credit to the user), a user may take or mint.
 * To settle a negative delta (a debt on the user), a user may transfer or burn to pay off a debt.
 *
 * NOTE: Deltas are synced before any ERC-20 transfers in {settle} function.
 */
library CurrencySettler {
    using SafeERC20 for IERC20;

    /**
     * @notice Settle (pay) a currency to the `Vault`
     * @param currency Currency to settle
     * @param vault `vault` to settle to
     * @param payer Address of the payer, which can be the hook itself or an external address.
     * @param amount Amount to send
     * @param burn If true, burn the ERC-6909 token, otherwise transfer ERC-20 to the `Vault`
     */
    function settle(Currency currency, IVault vault, address payer, uint256 amount, bool burn) internal {
        // Early return when amount is 0 given that some tokens may revert in this case
        if (amount == 0) return;

        // For native currencies or burns, calling sync is not required
        // Short circuit for ERC-6909 burns to support ERC-6909-wrapped native tokens
        if (burn) {
            vault.burn(payer, currency, amount);
        } else if (currency.isNative()) {
            vault.sync(currency);
            vault.settle{value: amount}();
        } else {
            vault.sync(currency);
            if (payer != address(this)) {
                IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(vault), amount);
            } else {
                IERC20(Currency.unwrap(currency)).safeTransfer(address(vault), amount);
            }
            vault.settle();
        }
    }
}
