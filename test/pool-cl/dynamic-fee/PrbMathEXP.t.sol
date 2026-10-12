// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {
    SD59x18,
    uUNIT,
    UNIT,
    convert,
    inv,
    exp,
    lt,
    gt,
    sub,
    uEXP_MIN_THRESHOLD,
    EXP_MAX_INPUT
} from "prb-math/SD59x18.sol";

contract PrbMathEXPTest is Test {
    using Strings for *;

    function testFuzz_exp(uint256 exponent) public view {
        exponent = bound(exponent, 1, 132);
        // EXPResult is a json file that contains the expected results of the exp function
        // result = e ^ exponent * 1e18
        string memory path = "test/pool-cl/dynamic-fee/test/EXPResult.json";
        string memory json = vm.readFile(path);
        bytes memory data = vm.parseJson(json, string.concat(".", exponent.toString()));
        uint256 result = abi.decode(data, (uint256));
        SD59x18 exp_result = exp(convert(int256(exponent)));
        assertApproxEqRel(SD59x18.unwrap(exp_result), int256(result), 1 ether / 100);
    }
}
