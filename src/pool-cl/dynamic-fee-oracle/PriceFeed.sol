// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {PriceFeedLib} from "./libraries/PriceFeedLib.sol";

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

contract PriceFeed is IPriceFeed, Ownable {
    PriceFeedInfo public info;

    IERC20Metadata public immutable token0;
    IERC20Metadata public immutable token1;

    uint256 private constant ORACLE_MAX_DECIMALS = 18;
    uint256 private constant PRECISION_DECIMALS = 18;
    /// @dev Default order of the oracle
    /// 0 means oracle order is same with v4 pool order
    /// 1 means oracle order is reverse with v4 pool order
    uint256 private constant ORACLE_DEFAULT_ORDER = 0;

    event PriceFeedUpdated(address indexed oracle, uint8 oracleTokenOrder, uint32 oracleExpirationThreshold);

    error InvalidoracleDecimalss();

    /// @dev Constructor
    /// @param token0_ The first token
    /// @param token1_ The second token
    /// @param oracle_ The oracle address
    /// @param oracleExpirationThreshold_ The oracle expiration threshold
    /// @param oracleTokenOrder_ The oracle token order, 0: oracle order is same with v4 pool order, 1: oracle order is reverse with v4 pool order
    constructor(
        address token0_,
        address token1_,
        address oracle_,
        uint8 oracleTokenOrder_,
        uint32 oracleExpirationThreshold_
    ) Ownable(msg.sender) {
        if (token0_ > token1_) {
            (token0_, token1_) = (token1_, token0_);
        }
        token0 = IERC20Metadata(token0_);
        token1 = IERC20Metadata(token1_);

        info.oracle = AggregatorV3Interface(oracle_);
        uint8 oracleDecimalss = info.oracle.decimals();
        if (oracleDecimalss > ORACLE_MAX_DECIMALS) {
            revert InvalidoracleDecimalss();
        }
        info.oracleExpirationThreshold = oracleExpirationThreshold_;
        info.oracleTokenOrder = oracleTokenOrder_;
        info.oracleDecimals = oracleDecimalss;
        info.token0Decimals = token0.decimals();
        info.token1Decimals = token1.decimals();
    }

    /// @dev Update the oracle and oracle expiration threshold
    /// @param oracle_ The new oracle address
    /// @param oracleTokenOrder_ The new oracle token order
    /// @param oracleExpirationThreshold_ The new oracle expiration threshold
    function updateOracle(address oracle_, uint8 oracleTokenOrder_, uint32 oracleExpirationThreshold_)
        external
        onlyOwner
    {
        info.oracle = AggregatorV3Interface(oracle_);
        uint8 oracleDecimalss = info.oracle.decimals();
        if (oracleDecimalss > ORACLE_MAX_DECIMALS) {
            revert InvalidoracleDecimalss();
        }
        info.oracleExpirationThreshold = oracleExpirationThreshold_;
        info.oracleTokenOrder = oracleTokenOrder_;
        info.oracleDecimals = oracleDecimalss;
        emit PriceFeedUpdated(oracle_, oracleTokenOrder_, oracleExpirationThreshold_);
    }

    /// @dev Get the latest price
    /// @return priceX96 The latest price
    function getPriceX96() external view virtual returns (uint256 priceX96) {
        PriceFeedInfo memory priceFeedInfo = info;
        (, int256 answer,, uint256 updatedAt,) = priceFeedInfo.oracle.latestRoundData();
        // can not revert, we must make sure hooks can still work even if the price is not available
        // valid answer should be between 1 and 10^(oracleDecimals + 18)
        // if answer is greater than 10^(oracleDecimals + 18), it is considered invalid
        if (
            answer <= 0 || answer > int256(10 ** (priceFeedInfo.oracleDecimals + ORACLE_MAX_DECIMALS))
                || block.timestamp > updatedAt + priceFeedInfo.oracleExpirationThreshold
        ) {
            return 0;
        }
        uint256 currentPrice = uint256(answer);
        if (priceFeedInfo.oracleTokenOrder != ORACLE_DEFAULT_ORDER) {
            currentPrice = PriceFeedLib.calculateReverseOrderPrice(currentPrice, priceFeedInfo.oracleDecimals);
        }

        priceX96 = PriceFeedLib.calculatePriceX96(
            currentPrice, priceFeedInfo.token0Decimals, priceFeedInfo.token1Decimals, priceFeedInfo.oracleDecimals
        );
    }
}
