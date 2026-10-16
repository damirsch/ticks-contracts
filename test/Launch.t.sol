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

/// @notice Runs the whole launch against the real Uniswap v4 deployment on a fork of Robinhood Chain mainnet.
contract LaunchForkTest is Test {
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

    function test_token_isAFixedSupplyErc20() public {
        TicksToken token = _deployToken(bytes32(0));
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.decimals(), 18);
        assertEq(token.symbol(), "TICKS");
    }

    function test_ethPair_launchesAtTheMarketCap_andPaysThePoolFeeToTheOwner() public {
        TicksToken token = _deployToken(bytes32(0));
        (LaunchPlan.Plan memory p, uint256 tokenId) = _launch(token, address(0), 18, ETH_PRICE_E6);

        assertFalse(p.tokenIsCurrency0);
        assertEq(IERC721(LaunchPlan.POSITION_MANAGER).ownerOf(tokenId), owner);
        assertApproxEqRel(_marketCapUsd(p, 18, ETH_PRICE_E6), START_MCAP_USD * 1e18, 0.03e18);
        assertApproxEqAbs(token.balanceOf(deployer), SUPPLY - POOL_TOKENS, 1e6);
        assertEq(IERC20(address(token)).allowance(deployer, LaunchPlan.PERMIT2), 0);

        // A 0.1 ETH buy: about 0.1 * 97% / ($75k / 1B / $2,500) TICKS, and 3% of the ETH to the owner.
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        router.swap{value: 0.1 ether}(p.key, _exactIn(true, 0.1 ether), _settings(), "");
        uint256 bought = token.balanceOf(buyer);
        uint256 expected = FullMath.mulDiv(0.097 ether, SUPPLY * ETH_PRICE_E6, START_MCAP_USD * 1e6 * 1e18);
        assertApproxEqRel(bought, expected, 0.05e18);

        uint256 before = owner.balance;
        _collect(p.key, tokenId);
        uint256 ethFee = owner.balance - before;
        console2.log("ETH fee on a 0.1 ETH buy (wei)", ethFee);
        assertApproxEqRel(ethFee, 0.003 ether, 0.01e18);

        // Selling half back pays the fee in TICKS.
        uint256 sold = bought / 2;
        vm.startPrank(buyer);
        token.approve(address(router), sold);
        router.swap(p.key, _exactIn(false, sold), _settings(), "");
        vm.stopPrank();
        assertGt(buyer.balance, 0.9 ether);

        uint256 tokensBefore = token.balanceOf(owner);
        _collect(p.key, tokenId);
        assertApproxEqRel(token.balanceOf(owner) - tokensBefore, sold * 3 / 100, 0.01e18);
    }

    function test_usdgPair_tokenAsCurrency0() public {
        _usdgRoundTrip(_deployToken(_saltFor(true)));
    }

    function test_usdgPair_tokenAsCurrency1() public {
        _usdgRoundTrip(_deployToken(_saltFor(false)));
    }

    function _usdgRoundTrip(TicksToken token) internal {
        (LaunchPlan.Plan memory p, uint256 tokenId) = _launch(token, USDG, 6, 1e6);
        assertEq(p.tokenIsCurrency0, address(token) < USDG);
        assertApproxEqRel(_marketCapUsd(p, 6, 1e6), START_MCAP_USD * 1e18, 0.03e18);

        // A $100 buy: about $97 / $0.000075 TICKS, and $3 to the owner.
        deal(USDG, buyer, 100e6);
        vm.startPrank(buyer);
        IERC20(USDG).approve(address(router), 100e6);
        router.swap(p.key, _exactIn(!p.tokenIsCurrency0, 100e6), _settings(), "");
        vm.stopPrank();
        assertApproxEqRel(token.balanceOf(buyer), FullMath.mulDiv(97e6, SUPPLY, START_MCAP_USD * 1e6), 0.05e18);

        uint256 before = IERC20(USDG).balanceOf(owner);
        _collect(p.key, tokenId);
        assertApproxEqRel(IERC20(USDG).balanceOf(owner) - before, 3e6, 0.01e18);
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
