// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";

interface IPriceFeed {
    struct PriceFeedInfo {
        AggregatorV3Interface oracle;
        /// @dev if oracle latest data is older than this, it is considered expired
        /// max is 4294967295(2^32 - 1) seconds , which is about 136 years
        uint32 oracleExpirationThreshold;
        /// @dev oracle token order, 0 means oracle base is token0, 1 means oracle base is token1
        /// For example , v4 pool is ETH/BTC (ETH token address is smaller than BTC token address), but oracle price is BTC/ETH
        /// Then we need to calculate the ETH/BTC price based on oracle price
        uint8 oracleTokenOrder;
        uint8 oracleDecimals;
        uint8 token0Decimals;
        uint8 token1Decimals;
    }

    function token0() external view returns (IERC20Metadata);

    function token1() external view returns (IERC20Metadata);

    function getPriceX96() external view returns (uint256 priceX96);
}
