// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";

library PriceFeedLib {
    /// @dev Default target token index is 0, if index is not 0 ,need to calculate the reverse price
    uint256 constant ORACLE_DEFAULT_INDEX = 0;
    uint256 constant PRECISION_DECIMALS = 18;
    // Max price is 10^10, FixedPoint96.Q96 * 10 ** 10
    uint256 constant MAX_PRICEX96 = 792281625142643375935439503360000000000;
    // Min price is 10^-10, FixedPoint96.Q96 / 10 ** 10
    uint256 constant MIN_PRICEX96 = 7922816251426433759;

    /// @dev Calculate the reverse order price
    /// For exmaple , oracle default price is BTC/ETH , but we want to calculate the price of ETH/BTC
    /// @param price The oracle price
    /// @param oracleDecimals The oracle decimals
    /// @return The reverse order price with oracle decimals
    function calculateReverseOrderPrice(uint256 price, uint256 oracleDecimals) internal pure returns (uint256) {
        return 10 ** (oracleDecimals * 2 + PRECISION_DECIMALS) / price / 10 ** PRECISION_DECIMALS;
    }

    /// @dev calculate oracle price for two oracles
    /// @param oracle0Answer The oracle0 answer
    /// @param oracle0TargetTokenIndex The oracle0 target token index
    /// @param oracle0Decimals The oracle0 decimals
    /// @param oracle1Answer The oracle1 answer
    /// @param oracle1TargetTokenIndex The oracle1 target token index
    /// @param oracle1Decimals The oracle1 decimals
    /// @return The price for two oracles with PRECISION_DECIMALS(18)
    function calculatePriceForTwoOracles(
        int256 oracle0Answer,
        uint8 oracle0TargetTokenIndex,
        uint8 oracle0Decimals,
        int256 oracle1Answer,
        uint8 oracle1TargetTokenIndex,
        uint8 oracle1Decimals
    ) internal pure returns (uint256) {
        uint256 oracle0CurrentPrice = uint256(oracle0Answer);
        if (oracle0TargetTokenIndex != ORACLE_DEFAULT_INDEX) {
            oracle0CurrentPrice = calculateReverseOrderPrice(oracle0CurrentPrice, oracle0Decimals);
        }
        uint256 oracle1CurrentPrice = uint256(oracle1Answer);
        if (oracle1TargetTokenIndex != ORACLE_DEFAULT_INDEX) {
            oracle1CurrentPrice = calculateReverseOrderPrice(oracle1CurrentPrice, oracle1Decimals);
        }

        // need to calculate the price based on oracle0 and oracle1 price
        // price = (oracle0_price / oracle0_decimals)  / (oracle1_price / oracle1_decimals)
        // price = oracle0_price * oracle1_decimals / (oracle1_price * oracle0_decimals)
        // becasue oracle0 and oracle1 maybe will have different decimals,so we will calculate price with PRECISION_DECIMALS(18)
        // price = oracle0_price * 10^18 * oracle1_decimals / (oracle1_price * oracle0_decimals)
        return oracle0CurrentPrice * 10 ** (PRECISION_DECIMALS + oracle1Decimals) / oracle1CurrentPrice
            / 10 ** oracle0Decimals;
    }

    /// @dev Calculate the price based on the current price , token0 decimals, token1 decimals and oracle decimals
    /// @param price The current price
    /// @param token0Decimals The token0 decimals
    /// @param token1Decimals The token1 decimals
    /// @param oracleDecimals The oracle decimals
    /// @return priceX96 The price with oracleDecimals
    function calculatePriceX96(uint256 price, uint8 token0Decimals, uint8 token1Decimals, uint8 oracleDecimals)
        internal
        pure
        returns (uint256 priceX96)
    {
        // v4_pool_price = v4_pool_token1_amount / v4_pool_token0_amount
        // token1_real_amount = v4_pool_token1_amount / 10 ** token1Decimals
        // token0_real_amount = v4_pool_token0_amount / 10 ** token0Decimals
        // currentPrice = token1_real_amount * 10 ** oracleDecimals / token0_real_amount
        // currentPrice = v4_pool_token1_amount / 10 ** token1Decimals  * 10 ** oracleDecimals / (v4_pool_token0_amount / 10 ** token0Decimals)
        // v4_pool_price = v4_pool_token1_amount / v4_pool_token0_amount = currentPrice * 10 ** token1Decimals / 10 ** token0Decimals / 10 ** oracleDecimals
        // v4_pool_price_x96 = v4_pool_price * 2^96 = currentPrice * 2^96 / 10 ** oracleDecimals * 10 ** token1Decimals / 10 ** token0Decimals
        uint256 priceX96_u256 = FullMath.mulDiv(price, FixedPoint96.Q96, 10 ** oracleDecimals);
        priceX96_u256 = FullMath.mulDiv(priceX96_u256, 10 ** token1Decimals, 10 ** token0Decimals);

        return priceX96_u256;
    }
}
