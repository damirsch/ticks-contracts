// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TicksToken} from "../src/TicksToken.sol";
import {LaunchPlan} from "./LaunchPlan.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Testnet only. Runs the real launch (token, pool, position to `OWNER`) and adds what the test page
///         needs: Uniswap's test swap router (the Universal Router is not on Robinhood testnet) and some TICKS
///         for `TESTER` to try selling. Writes the addresses to deployments/testnet.json.
///
///         forge script script/TestnetSetup.s.sol --rpc-url robinhood_testnet --broadcast --private-key $TESTNET_DEPLOYER_KEY
contract TestnetSetup is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        address tester = vm.envOr("TESTER", owner);
        uint256 supply = 1_000_000_000e18;
        uint256 ethPriceE6 = vm.envOr("PAIR_PRICE_USD_E6", uint256(2_500e6));
        uint256 startMarketCap = vm.envOr("START_MARKET_CAP_USD", uint256(75_000));

        vm.startBroadcast();
        TicksToken token = new TicksToken("TICKS Test", "tTICKS", supply, msg.sender);
        LaunchPlan.Config memory cfg = LaunchPlan.Config({
            token: address(token),
            tokenSupply: supply,
            pair: address(0),
            pairDecimals: 18,
            fee: uint24(vm.envOr("POOL_FEE", uint256(30_000))),
            tickSpacing: 200,
            startMarketCapUsd: startMarketCap,
            pairPriceUsdE6: ethPriceE6,
            poolTokens: 800_000_000e18,
            rangeMultiple: 1000,
            owner: owner
        });
        LaunchPlan.Plan memory p = LaunchPlan.plan(cfg);
        uint256 tokenId = LaunchPlan.execute(cfg, p, block.timestamp + 30 minutes);
        PoolSwapTest router = new PoolSwapTest(IPoolManager(LaunchPlan.POOL_MANAGER));
        token.transfer(tester, 1_000_000e18);
        vm.stopBroadcast();

        string memory o = "deployment";
        vm.serializeAddress(o, "token", address(token));
        vm.serializeAddress(o, "router", address(router));
        vm.serializeAddress(o, "owner", owner);
        vm.serializeAddress(o, "positionManager", LaunchPlan.POSITION_MANAGER);
        vm.serializeAddress(o, "currency0", Currency.unwrap(p.key.currency0));
        vm.serializeAddress(o, "currency1", Currency.unwrap(p.key.currency1));
        vm.serializeUint(o, "fee", cfg.fee);
        vm.serializeInt(o, "tickSpacing", cfg.tickSpacing);
        vm.serializeUint(o, "positionId", tokenId);
        vm.serializeUint(o, "supply", supply);
        vm.serializeUint(o, "ethPriceUsdE6", ethPriceE6);
        vm.serializeUint(o, "startMarketCapUsd", startMarketCap);
        vm.serializeUint(o, "launchSqrtPriceX96", p.sqrtPriceX96);
        string memory json = vm.serializeBytes32(o, "poolId", PoolId.unwrap(PoolIdLibrary.toId(p.key)));
        vm.writeJson(json, "deployments/testnet.json");

        console2.log("token", address(token));
        console2.log("router", address(router));
        console2.log("position NFT as simulated, confirm with tools/find-position.mjs", tokenId);
    }
}
