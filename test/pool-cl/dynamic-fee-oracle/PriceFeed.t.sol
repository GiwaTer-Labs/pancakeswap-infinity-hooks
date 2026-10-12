// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {MockAggregatorV3} from "test/pool-cl/dynamic-fee-oracle/helpers/MockAggregatorV3.sol";
import {PriceFeed} from "src/pool-cl/dynamic-fee-oracle/PriceFeed.sol";
import {PriceFeedLib} from "src/pool-cl/dynamic-fee-oracle/libraries/PriceFeedLib.sol";

contract PriceFeedTest is Test {
    MockAggregatorV3 defaultOracle;
    MockAggregatorV3 defaultOracleReverseOrder;
    PriceFeed priceFeedContract;
    // priceFeed contract with reverse order
    PriceFeed priceFeedContractReverseOrder;

    MockERC20 token0;
    MockERC20 token1;

    uint256 constant PRECISION_DECIMALS = 18;
    uint8 public constant ORACLE_DEFAULT_DECIMALS = 18;
    int256 public constant ORACLE_DEFAULT_PRICE = int256(10 * 10 ** ORACLE_DEFAULT_DECIMALS);

    function setUp() public {
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        defaultOracle = new MockAggregatorV3(ORACLE_DEFAULT_DECIMALS, ORACLE_DEFAULT_PRICE);
        priceFeedContract = new PriceFeed(address(token0), address(token1), address(defaultOracle), 0, 3600 * 24);

        defaultOracleReverseOrder = new MockAggregatorV3(ORACLE_DEFAULT_DECIMALS, ORACLE_DEFAULT_PRICE);
        priceFeedContractReverseOrder =
            new PriceFeed(address(token1), address(token0), address(defaultOracleReverseOrder), 1, 3600 * 24);
    }

    function testFuzz_getPriceX96(uint256 oracle_price) public {
        vm.assume(oracle_price < 10 ** 36);
        defaultOracle.updateAnswer(int256(oracle_price));
        uint256 priceX96_expected = FullMath.mulDiv(oracle_price, FixedPoint96.Q96, 10 ** ORACLE_DEFAULT_DECIMALS);
        uint256 priceX96 = priceFeedContract.getPriceX96();
        assertEq(priceX96, priceX96_expected);
    }

    /// @notice fuzz test for getPriceX96 with reverse order
    function testFuzz_getPriceX96ReverseOrder(uint256 oracle_price) public {
        vm.assume(oracle_price < 10 ** 36);
        vm.assume(oracle_price > 0);
        defaultOracleReverseOrder.updateAnswer(int256(oracle_price));
        // calculate the reverse order price , 1/price
        uint256 real_price = 10 ** (ORACLE_DEFAULT_DECIMALS * 2) / oracle_price;
        uint256 priceX96_expected = FullMath.mulDiv(real_price, FixedPoint96.Q96, 10 ** ORACLE_DEFAULT_DECIMALS);
        uint256 priceX96 = priceFeedContractReverseOrder.getPriceX96();
        assertEq(priceX96, priceX96_expected);
    }
}
