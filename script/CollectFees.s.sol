// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchPlan} from "./LaunchPlan.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Collects the fees the TICKS position has earned to `RECIPIENT`. Run it from the wallet that owns
///         the position NFT. The same can be done in the Uniswap app under Positions.
///
///         forge script script/CollectFees.s.sol --rpc-url robinhood --broadcast
contract CollectFees is Script {
    function run() external {
        address token = vm.envAddress("TOKEN");
        address pair = vm.envOr("PAIR", address(0));
        (address c0, address c1) = token < pair ? (token, pair) : (pair, token);
        PoolKey memory key = PoolKey(
            Currency.wrap(c0),
            Currency.wrap(c1),
            uint24(vm.envOr("POOL_FEE", uint256(30_000))),
            int24(int256(vm.envOr("TICK_SPACING", uint256(200)))),
            IHooks(address(0))
        );

        vm.startBroadcast();
        LaunchPlan.collectFees(key, vm.envUint("POSITION_ID"), vm.envAddress("RECIPIENT"), block.timestamp + 30 minutes);
        vm.stopBroadcast();
    }
}
