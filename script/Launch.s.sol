// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TicksToken} from "../src/TicksToken.sol";
import {LaunchPlan} from "./LaunchPlan.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Deploys TICKS and opens its Uniswap v4 pool in one run. The whole supply is minted to the
///         broadcasting wallet, `POOL_TOKENS` of it go into the pool, and the rest stays with that wallet
///         for the distribution step. The position NFT, and every fee it earns, goes to `OWNER`.
///
///         forge script script/Launch.s.sol --rpc-url robinhood --broadcast
contract Launch is Script {
    function run() external returns (address token, uint256 tokenId) {
        uint256 supply = vm.envOr("TOKEN_SUPPLY", uint256(1_000_000_000)) * 1e18;
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast();
        token = address(new TicksToken(vm.envString("TOKEN_NAME"), vm.envString("TOKEN_SYMBOL"), supply, msg.sender));

        LaunchPlan.Config memory cfg = LaunchPlan.Config({
            token: token,
            tokenSupply: supply,
            pair: vm.envOr("PAIR", address(0)),
            pairDecimals: uint8(vm.envOr("PAIR_DECIMALS", uint256(18))),
            fee: uint24(vm.envOr("POOL_FEE", uint256(30_000))),
            tickSpacing: int24(int256(vm.envOr("TICK_SPACING", uint256(200)))),
            startMarketCapUsd: vm.envUint("START_MARKET_CAP_USD"),
            pairPriceUsdE6: vm.envUint("PAIR_PRICE_USD_E6"),
            poolTokens: vm.envUint("POOL_TOKENS") * 1e18,
            rangeMultiple: vm.envOr("RANGE_MULTIPLE", uint256(1000)),
            owner: owner
        });
        LaunchPlan.Plan memory p = LaunchPlan.plan(cfg);
        tokenId = LaunchPlan.execute(cfg, p, block.timestamp + 30 minutes);
        vm.stopBroadcast();

        console2.log("token", token);
        console2.log("position NFT as simulated, confirm with tools/find-position.mjs", tokenId);
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(PoolIdLibrary.toId(p.key)));
        console2.log("tick lower", int256(p.tickLower));
        console2.log("tick upper", int256(p.tickUpper));
    }
}
