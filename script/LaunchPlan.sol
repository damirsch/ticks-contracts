// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title LaunchPlan
/// @notice Opens the TICKS pool on Uniswap v4 with standard contracts only: no hook, a static pool fee, and a
///         position that holds only TICKS, so the launch needs no capital on the other side.
///
///         The position starts at the launch price and reaches `rangeMultiple` times higher. Every buy moves
///         the price into it and sells TICKS from it, and the pool fee on every trade accrues to the position,
///         which belongs to `owner`.
library LaunchPlan {
    /// @notice Uniswap v4 and Permit2 on Robinhood Chain (the same addresses on mainnet and testnet).
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 internal constant USD_SCALE = 1e6;

    struct Config {
        address token;
        uint256 tokenSupply;
        /// @dev address(0) pairs the token with native ETH.
        address pair;
        uint8 pairDecimals;
        /// @dev In hundredths of a basis point: 30_000 is 3%.
        uint24 fee;
        int24 tickSpacing;
        /// @dev Whole US dollars, for the whole supply.
        uint256 startMarketCapUsd;
        /// @dev The USD price of one whole unit of the pair asset, times 1e6.
        uint256 pairPriceUsdE6;
        uint256 poolTokens;
        /// @dev How many times above the launch price the position still sells TICKS.
        uint256 rangeMultiple;
        address owner;
    }

    struct Plan {
        PoolKey key;
        bool tokenIsCurrency0;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    error RangeTooWide();

    function plan(Config memory cfg) internal pure returns (Plan memory p) {
        p.tokenIsCurrency0 = cfg.token < cfg.pair;
        (Currency c0, Currency c1) = p.tokenIsCurrency0
            ? (Currency.wrap(cfg.token), Currency.wrap(cfg.pair))
            : (Currency.wrap(cfg.pair), Currency.wrap(cfg.token));
        p.key = PoolKey(c0, c1, cfg.fee, cfg.tickSpacing, IHooks(address(0)));

        // The launch price in raw units, as pair per token: market cap / supply / pair price.
        uint256 pairPerToken = cfg.startMarketCapUsd * USD_SCALE * 10 ** cfg.pairDecimals;
        uint256 tokenPerPair = cfg.pairPriceUsdE6 * cfg.tokenSupply;
        uint160 sqrtTarget = p.tokenIsCurrency0
            ? uint160(Math.sqrt(FullMath.mulDiv(pairPerToken, 1 << 192, tokenPerPair)))
            : uint160(Math.sqrt(FullMath.mulDiv(tokenPerPair, 1 << 192, pairPerToken)));

        int24 spacing = cfg.tickSpacing;
        int24 range = _rangeTicks(cfg.rangeMultiple, spacing);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtTarget);

        if (p.tokenIsCurrency0) {
            // The token's price rises with the pool price: the position sits above the launch tick.
            p.tickLower = _ceil(tick, spacing);
            p.tickUpper = _min(p.tickLower + range, TickMath.maxUsableTick(spacing));
            p.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(p.tickLower);
            p.liquidity = LiquidityAmounts.getLiquidityForAmount0(
                p.sqrtPriceX96, TickMath.getSqrtPriceAtTick(p.tickUpper), cfg.poolTokens
            );
        } else {
            // The token's price rises as the pool price falls: the position sits below the launch tick.
            p.tickUpper = _floor(tick, spacing);
            p.tickLower = _max(p.tickUpper - range, TickMath.minUsableTick(spacing));
            p.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(p.tickUpper);
            p.liquidity = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(p.tickLower), p.sqrtPriceX96, cfg.poolTokens
            );
        }
    }

    /// @notice Creates the pool and mints the position to `cfg.owner`. The caller must hold `cfg.poolTokens`.
    ///         Approvals given for the mint are revoked before returning.
    function execute(Config memory cfg, Plan memory p, uint256 deadline) internal returns (uint256 tokenId) {
        IPositionManager posm = IPositionManager(POSITION_MANAGER);

        IERC20(cfg.token).approve(PERMIT2, cfg.poolTokens);
        IAllowanceTransfer(PERMIT2).approve(cfg.token, POSITION_MANAGER, uint160(cfg.poolTokens), uint48(deadline));

        // Straight to the PoolManager, not the PositionManager's initializePool: that one swallows a failed
        // initialize, so a transaction sent with a tight gas estimate can succeed without creating the pool.
        IPoolManager(POOL_MANAGER).initialize(p.key, p.sqrtPriceX96);

        (uint128 amount0Max, uint128 amount1Max) =
            p.tokenIsCurrency0 ? (uint128(cfg.poolTokens), uint128(0)) : (uint128(0), uint128(cfg.poolTokens));

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            p.key, p.tickLower, p.tickUpper, uint256(p.liquidity), amount0Max, amount1Max, cfg.owner, bytes("")
        );
        params[1] = abi.encode(p.key.currency0, p.key.currency1);

        tokenId = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, params), deadline);

        IAllowanceTransfer(PERMIT2).approve(cfg.token, POSITION_MANAGER, 0, 0);
        IERC20(cfg.token).approve(PERMIT2, 0);
    }

    /// @notice Collects the fees a position has earned, in both currencies, to `recipient`.
    ///         The caller must own the position or be approved for it.
    function collectFees(PoolKey memory key, uint256 tokenId, address recipient, uint256 deadline) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        IPositionManager(POSITION_MANAGER).modifyLiquidities(abi.encode(actions, params), deadline);
    }

    function _rangeTicks(uint256 multiple, int24 spacing) private pure returns (int24) {
        if (multiple < 2 || multiple >= 1 << 64) revert RangeTooWide();
        int24 ticks = TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(multiple << 192)));
        return ticks / spacing * spacing;
    }

    function _floor(int24 tick, int24 spacing) private pure returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q--;
        return q * spacing;
    }

    function _ceil(int24 tick, int24 spacing) private pure returns (int24) {
        int24 q = tick / spacing;
        if (tick > 0 && tick % spacing != 0) q++;
        return q * spacing;
    }

    function _min(int24 a, int24 b) private pure returns (int24) {
        return a < b ? a : b;
    }

    function _max(int24 a, int24 b) private pure returns (int24) {
        return a > b ? a : b;
    }
}
