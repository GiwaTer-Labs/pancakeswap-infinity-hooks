// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {PriceFeedLib} from "./libraries/PriceFeedLib.sol";

import {IPriceFeedTwoOracle} from "./interfaces/IPriceFeedTwoOracle.sol";

/// @title PriceFeedTwoOracle
/// @notice This contract is used to calculate the price from two oracles
/// This contract supports that two oracles must have a common currency
/// OracleA pair is A/C or C/A , OracleB pair is B/C or C/B, v4 pool pair is A/B or B/A , OracleA and OracleB must have a common currency C
/// If v4 pool is A/B, Oracle0 is OracleA, Oracle1 is OracleB
/// If v4 pool is B/A, Oracle0 is OracleB, Oracle1 is OracleA
contract PriceFeedTwoOracle is IPriceFeedTwoOracle, Ownable {
    PriceFeedInfo public info;

    IERC20Metadata public immutable token0;
    IERC20Metadata public immutable token1;

    uint256 constant ORACLE_MAX_DECIMALS = 18;
    /// @dev Default target token index is 0, if index is not 0 ,need to calculate the reverse price
    uint256 constant ORACLE_DEFAULT_INDEX = 0;

    error InvalidOracleDecimals();

    /// @dev Constructor
    /// @param token0_ The first token
    /// @param token1_ The second token
    /// @param oracle0_ The oracle0 address
    /// @param oracle1_ The oracle1 address
    /// @param oracle0ExpirationThreshold_ The oracle0 expiration threshold
    /// @param oracle1ExpirationThreshold_ The oracle1 expiration threshold
    constructor(
        address token0_,
        address token1_,
        address oracle0_,
        address oracle1_,
        uint8 oracle0TargetTokenIndex_,
        uint8 oracle1TargetTokenIndex_,
        uint32 oracle0ExpirationThreshold_,
        uint32 oracle1ExpirationThreshold_
    ) Ownable(msg.sender) {
        if (token0_ > token1_) {
            (token0_, token1_) = (token1_, token0_);
        }
        token0 = IERC20Metadata(token0_);
        token1 = IERC20Metadata(token1_);
        info.oracle0 = AggregatorV3Interface(oracle0_);
        uint8 oracle0Decimals = info.oracle0.decimals();
        info.oracle1 = AggregatorV3Interface(oracle1_);
        uint8 oracle1Decimals = info.oracle1.decimals();
        if (oracle0Decimals > ORACLE_MAX_DECIMALS || oracle1Decimals > ORACLE_MAX_DECIMALS) {
            revert InvalidOracleDecimals();
        }

        info.oracle0ExpirationThreshold = oracle0ExpirationThreshold_;
        info.oracle1ExpirationThreshold = oracle1ExpirationThreshold_;
        info.oracle0Decimals = oracle0Decimals;
        info.oracle1Decimals = oracle1Decimals;
        info.oracle0TargetTokenIndex = oracle0TargetTokenIndex_;
        info.oracle1TargetTokenIndex = oracle1TargetTokenIndex_;
        info.token0Decimals = token0.decimals();
        info.token1Decimals = token1.decimals();
    }

    /// @dev Update the oracles , oracles target token index, and oracles expiration threshold
    /// @param oracle0_ The new oracle0 address
    /// @param oracle1_ The new oracle1 address
    /// @param oracle0TargetTokenIndex_ The new oracle0 target token index
    /// @param oracle1TargetTokenIndex_ The new oracle1 target token index
    /// @param oracle0ExpirationThreshold_ The new oracle0 expiration threshold
    /// @param oracle1ExpirationThreshold_ The new oracle1 expiration threshold
    function updateOracles(
        address oracle0_,
        address oracle1_,
        uint8 oracle0TargetTokenIndex_,
        uint8 oracle1TargetTokenIndex_,
        uint32 oracle0ExpirationThreshold_,
        uint32 oracle1ExpirationThreshold_
    ) external onlyOwner {
        info.oracle0 = AggregatorV3Interface(oracle0_);
        uint8 oracle0Decimals = info.oracle0.decimals();
        info.oracle1 = AggregatorV3Interface(oracle1_);
        uint8 oracle1Decimals = info.oracle1.decimals();
        if (oracle0Decimals > ORACLE_MAX_DECIMALS || oracle1Decimals > ORACLE_MAX_DECIMALS) {
            revert InvalidOracleDecimals();
        }
        info.oracle0ExpirationThreshold = oracle0ExpirationThreshold_;
        info.oracle1ExpirationThreshold = oracle1ExpirationThreshold_;
        info.oracle0Decimals = oracle0Decimals;
        info.oracle1Decimals = oracle1Decimals;
        info.oracle0TargetTokenIndex = oracle0TargetTokenIndex_;
        info.oracle1TargetTokenIndex = oracle1TargetTokenIndex_;
    }

    /// @dev Get the latest price
    /// @return priceX96 The latest price
    function getPriceX96() external view virtual returns (uint160 priceX96) {
        PriceFeedInfo memory priceFeedInfo = info;
        (, int256 oracle0Answer,, uint256 oracle0UpdatedAt,) = priceFeedInfo.oracle0.latestRoundData();
        (, int256 oracle1Answer,, uint256 oracle1UpdatedAt,) = priceFeedInfo.oracle1.latestRoundData();
        // can not revert, we must make sure hooks can still work even if the price is not available
        if (
            oracle0Answer <= 0 || oracle1Answer <= 0
                || block.timestamp > oracle0UpdatedAt + priceFeedInfo.oracle0ExpirationThreshold
                || block.timestamp > oracle1UpdatedAt + priceFeedInfo.oracle1ExpirationThreshold
        ) {
            return 0;
        }

        // becasue oracle0 and oracle1 maybe will have different decimals,so we will calculate price with PriceFeedLib.PRECISION_DECIMALS(18)
        uint256 currentPrice = PriceFeedLib.calculatePriceForTwoOracles(
            oracle0Answer,
            priceFeedInfo.oracle0TargetTokenIndex,
            priceFeedInfo.oracle0Decimals,
            oracle1Answer,
            priceFeedInfo.oracle1TargetTokenIndex,
            priceFeedInfo.oracle1Decimals
        );

        priceX96 = PriceFeedLib.calculatePriceX96(
            currentPrice,
            priceFeedInfo.token0Decimals,
            priceFeedInfo.token1Decimals,
            uint8(PriceFeedLib.PRECISION_DECIMALS)
        );
    }
}
