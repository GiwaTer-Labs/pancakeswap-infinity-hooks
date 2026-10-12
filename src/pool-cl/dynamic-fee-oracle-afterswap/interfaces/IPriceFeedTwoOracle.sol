// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";

interface IPriceFeedTwoOracle {
    struct PriceFeedInfo {
        /// @dev Please confirm the oracle0 and oracle1 order before depoying.
        /// For example, if thare are two oracles, OracleA is BTC/USD, OracleB is ETH/USD, v4 pool is BTC/ETH, so oracle0 is OracleA, oracle1 is OracleB
        /// If OracleA is ETH/USD, OracleB is BTC/USD, v4 pool is BTC/ETH, so oracle0 is OracleB, oracle1 is OracleA
        AggregatorV3Interface oracle0;
        AggregatorV3Interface oracle1;
        /// @dev if oracle latest data is older than this, it is considered expired
        /// max is 4294967295(2^32 - 1) seconds , which is about 136 years
        uint32 oracle0ExpirationThreshold;
        uint32 oracle1ExpirationThreshold;
        uint8 oracle0Decimals;
        uint8 oracle1Decimals;
        /// @dev target token index in oracle default order.
        /// For example, if oracle0 is BTC/USD, oracle1 is USD/ETH, v4 pool is BTC/ETH
        /// Then oracle0TargetTokenIndex is 0(BTC index), oracle1TargetTokenIndex is 1(ETH index)
        uint8 oracle0TargetTokenIndex;
        uint8 oracle1TargetTokenIndex;
        uint8 token0Decimals;
        uint8 token1Decimals;
    }

    function token0() external view returns (IERC20Metadata);

    function token1() external view returns (IERC20Metadata);

    function getPriceX96() external view returns (uint160 priceX96);
}
