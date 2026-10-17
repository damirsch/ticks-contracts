// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TicksToken} from "../src/TicksToken.sol";
import {LaunchPlan} from "../script/LaunchPlan.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

abstract contract LaunchFork is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant POOL_TOKENS = 100_000_000e18;
    uint24 constant FEE = 30_000;
    uint256 constant START_MCAP_USD = 75_000;
    uint256 constant ETH_PRICE_E6 = 2_500e6;

    IPoolManager manager = IPoolManager(LaunchPlan.POOL_MANAGER);
    PoolSwapTest router;

    address deployer = makeAddr("deployer");
    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork("robinhood");
        router = new PoolSwapTest(manager);
    }

    function _deployToken(bytes32 salt) internal returns (TicksToken) {
        return new TicksToken{salt: salt}("TICKS", "TICKS", SUPPLY, deployer);
    }

    /// @dev A CREATE2 salt that lands the token below (or above) USDG, to cover both pool orderings.
    function _saltFor(bool below) internal view returns (bytes32 salt) {
        bytes32 initCode =
            keccak256(abi.encodePacked(type(TicksToken).creationCode, abi.encode("TICKS", "TICKS", SUPPLY, deployer)));
        for (uint256 i = 1;; i++) {
            salt = bytes32(i);
            address predicted = vm.computeCreate2Address(salt, initCode, address(this));
            if ((predicted < USDG) == below) return salt;
        }
    }

    function _launch(TicksToken token, address pair, uint8 pairDecimals, uint256 pairPriceE6)
        internal
        returns (LaunchPlan.Plan memory p, uint256 tokenId)
    {
        LaunchPlan.Config memory cfg = LaunchPlan.Config({
            token: address(token),
            tokenSupply: SUPPLY,
            pair: pair,
            pairDecimals: pairDecimals,
            fee: FEE,
            tickSpacing: 200,
            startMarketCapUsd: START_MCAP_USD,
            pairPriceUsdE6: pairPriceE6,
            poolTokens: POOL_TOKENS,
            rangeMultiple: 1000,
            owner: owner
        });
        p = LaunchPlan.plan(cfg);
        vm.startPrank(deployer);
        tokenId = LaunchPlan.execute(cfg, p, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function _collect(PoolKey memory key, uint256 tokenId) internal {
        vm.startPrank(owner);
        LaunchPlan.collectFees(key, tokenId, owner, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    /// @dev The pool's current price as a whole-supply market cap in USD, scaled by 1e18.
    function _marketCapUsd(LaunchPlan.Plan memory p, uint8 pairDecimals, uint256 pairPriceE6)
        internal
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(p.key.toId());
        uint256 priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        // Pair raw units per token raw unit, times 2^128.
        uint256 pairPerTokenX128 = p.tokenIsCurrency0 ? priceX128 : FullMath.mulDiv(1 << 128, 1 << 128, priceX128);
        uint256 pairForSupply = FullMath.mulDiv(pairPerTokenX128, SUPPLY, 1 << 128);
        return FullMath.mulDiv(pairForSupply, pairPriceE6 * 1e12, 10 ** pairDecimals);
    }

    function _exactIn(bool zeroForOne, uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}
