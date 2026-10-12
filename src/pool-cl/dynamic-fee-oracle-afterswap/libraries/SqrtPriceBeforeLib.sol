// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library SqrtPriceBeforeLib {
    /// @dev uint256 internal constant SQRT_PRICE_BEFORE_SLOT = uint256(keccak256("SQRT_PRICE_BEFORE_SLOT")) - 1;
    uint256 internal constant SQRT_PRICE_BEFORE_SLOT =
        0x3475d03ff636ef3544b383162d3fd05f4a2fe01c9be83d7a102babb4fb442357;

    function setSqrtPriceBefore(uint256 sqrtPriceX96) internal {
        assembly {
            tstore(SQRT_PRICE_BEFORE_SLOT, sqrtPriceX96)
        }
    }

    function getSqrtPriceBefore() internal view returns (uint256 sqrtPriceX96) {
        assembly {
            sqrtPriceX96 := tload(SQRT_PRICE_BEFORE_SLOT)
        }
    }
}
