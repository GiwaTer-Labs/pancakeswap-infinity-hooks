// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockAggregatorV3} from "test/pool-cl/dynamic-fee-oracle/helpers/MockAggregatorV3.sol";
import {PriceFeedLib} from "src/pool-cl/dynamic-fee-oracle/libraries/PriceFeedLib.sol";

/// @dev This is a test contract for oracle price calculation
/// @notice Check if the reverse order price is calculated correctly
/// Check if the price of two oracles is calculated correctly
contract OraclePriceTest is Test {
    MockAggregatorV3 defaultOracle;
    MockAggregatorV3 oracle0;
    MockAggregatorV3 oracle1;

    uint256 constant PRECISION_DECIMALS = 18;
    uint8 public constant ORACLE_DEFAULT_DECIMALS = 18;
    // default price is 10
    int256 public constant ORACLE_DEFAULT_PRICE = int256(10 * 10 ** ORACLE_DEFAULT_DECIMALS);

    function setUp() public {
        defaultOracle = new MockAggregatorV3(ORACLE_DEFAULT_DECIMALS, ORACLE_DEFAULT_PRICE);
        // oracle0 decimals is 8, price is 1
        oracle0 = new MockAggregatorV3(8, 10 ** 8);
        // oracle1 decimals is 18, price is 1
        oracle1 = new MockAggregatorV3(18, 10 ** 18);
    }

    /// @dev default price is 10, so reverse order price is 0.1
    function test_oracle_order_case1() public view {
        (, int256 answer,,,) = defaultOracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertEq(reverseOrderPrice, 10 ** (ORACLE_DEFAULT_DECIMALS - 1));
    }

    /// @dev default price is 0.1, so reverse order price is 10
    function test_oracle_order_case2() public {
        defaultOracle.updateAnswer(int256(10 ** (ORACLE_DEFAULT_DECIMALS - 1)));
        (, int256 answer,,,) = defaultOracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertEq(reverseOrderPrice, 10 ** (ORACLE_DEFAULT_DECIMALS + 1));
    }
    /// @dev default price is 3, so reverse order price is 1/3

    function test_oracle_order_case3() public {
        defaultOracle.updateAnswer(int256(3 * 10 ** ORACLE_DEFAULT_DECIMALS));
        (, int256 answer,,,) = defaultOracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertEq(reverseOrderPrice, 10 ** ORACLE_DEFAULT_DECIMALS / 3);
    }

    /// @dev default price is 1/3, so reverse order price is 3
    function test_oracle_order_case4() public {
        defaultOracle.updateAnswer(int256(10 ** ORACLE_DEFAULT_DECIMALS / 3));
        (, int256 answer,,,) = defaultOracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertApproxEqRel(reverseOrderPrice, 3 * 10 ** ORACLE_DEFAULT_DECIMALS, 10);
    }

    /// @dev default price is 3000, so reverse order price is 1/3000
    function test_oracle_order_case5() public {
        defaultOracle.updateAnswer(int256(3000 * 10 ** ORACLE_DEFAULT_DECIMALS));
        (, int256 answer,,,) = defaultOracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertApproxEqRel(reverseOrderPrice, 10 ** ORACLE_DEFAULT_DECIMALS / 3000, 10);
    }

    /// @dev default price is 1/3000, so reverse order price is 3000
    function test_oracle_order_case6() public {
        defaultOracle.updateAnswer(int256(10 ** ORACLE_DEFAULT_DECIMALS / 3000));
        (, int256 answer,,,) = defaultOracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertApproxEqRel(reverseOrderPrice, 3000 * 10 ** ORACLE_DEFAULT_DECIMALS, 1000);
    }

    /// @dev oracleA is BTC/USD, oracleB is ETH/USD, v4 pool is BTC/ETH,
    /// oracle0 is oracleA, oracle1 is oracleB
    /// oracle0TargetTokenIndex is 0(BTC index), oracle1TargetTokenIndex is 0(ETH index)
    /// oracleA price is 1, oracleB price is 1, so v4 pool price is 1
    function test_calculate_price_for_two_oracles_case1() public view {
        uint256 price = calculate_price_for_two_oracles(oracle0, 0, oracle1, 0);
        assertEq(price, 10 ** PRECISION_DECIMALS);
    }

    /// @dev oracleA is BTC/USD, oracleB is ETH/USD, v4 pool is BTC/ETH,
    /// oracle0 is oracleA, oracle1 is oracleB
    /// oracle0TargetTokenIndex is 0(BTC index), oracle1TargetTokenIndex is 0(ETH index)
    /// oracleA price is 50000, oracleB price is 1000, so v4 pool price is 50
    function test_calculate_price_for_two_oracles_case2() public {
        oracle0.updateAnswer(int256(50000 * 10 ** 8));
        oracle1.updateAnswer(int256(1000 * 10 ** 18));
        uint256 price = calculate_price_for_two_oracles(oracle0, 0, oracle1, 0);
        assertEq(price, 50 * 10 ** PRECISION_DECIMALS);
    }

    /// @dev oracleA is BTC/USD, oracleB is USD/ETH, v4 pool is BTC/ETH,
    /// oracle0 is oracleA, oracle1 is oracleB
    /// oracle0TargetTokenIndex is 0(BTC index), oracle1TargetTokenIndex is 1(ETH index)
    /// oracleA price is 50000, oracleB price is 1/1000, so v4 pool price is 50
    function test_calculate_price_for_two_oracles_case3() public {
        oracle0.updateAnswer(int256(50000 * 10 ** 8));
        oracle1.updateAnswer(int256(10 ** 18 / 1000));
        uint256 price = calculate_price_for_two_oracles(oracle0, 0, oracle1, 1);
        assertEq(price, 50 * 10 ** PRECISION_DECIMALS);
    }

    /// @dev oracleA is USD/BTC, oracleB is USD/ETH, v4 pool is BTC/ETH,
    /// oracle0 is oracleA, oracle1 is oracleB
    /// oracle0TargetTokenIndex is 1(BTC index), oracle1TargetTokenIndex is 1(ETH index)
    /// oracleA price is 1/50000, oracleB price is 1/1000, so v4 pool price is 50
    function test_calculate_price_for_two_oracles_case4() public {
        oracle0.updateAnswer(int256(10 ** 8 / 50000));
        oracle1.updateAnswer(int256(10 ** 18 / 1000));
        uint256 price = calculate_price_for_two_oracles(oracle0, 1, oracle1, 1);
        assertEq(price, 50 * 10 ** PRECISION_DECIMALS);
    }

    /// @dev oracleA is USD/BTC, oracleB is USD/ETH, v4 pool is ETH/BTC,
    /// oracle0 is oracleB, oracle1 is oracleA
    /// oracle0TargetTokenIndex is 1(ETH index), oracle1TargetTokenIndex is 1(BTC index)
    /// oracleA price is 1/1000, oracleB price is 1/50000, so v4 pool price is 1/50
    function test_calculate_price_for_two_oracles_case5() public {
        oracle0.updateAnswer(int256(10 ** 8 / 1000));
        oracle1.updateAnswer(int256(10 ** 18 / 50000));
        uint256 price = calculate_price_for_two_oracles(oracle0, 1, oracle1, 1);
        assertEq(price, 10 ** PRECISION_DECIMALS / 50);
    }

    /// @dev Calculate the reverse order price
    function calaculate_reverse_order_price(uint256 price) public view returns (uint256) {
        uint8 oracleDecimals = defaultOracle.decimals();
        return PriceFeedLib.calculateReverseOrderPrice(price, oracleDecimals);
    }

    /// @dev calculate oracle price for two oracles
    function calculate_price_for_two_oracles(
        MockAggregatorV3 _oracle0,
        uint8 oracle0TargetTokenIndex,
        MockAggregatorV3 _oracle1,
        uint8 oracle1TargetTokenIndex
    ) public view returns (uint256) {
        (, int256 oracle0Answer,,,) = _oracle0.latestRoundData();
        (, int256 oracle1Answer,,,) = _oracle1.latestRoundData();
        uint8 oracle0Decimals = _oracle0.decimals();
        uint8 oracle1Decimals = _oracle1.decimals();

        return PriceFeedLib.calculatePriceForTwoOracles(
            oracle0Answer,
            oracle0TargetTokenIndex,
            oracle0Decimals,
            oracle1Answer,
            oracle1TargetTokenIndex,
            oracle1Decimals
        );
    }
}
