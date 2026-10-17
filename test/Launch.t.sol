// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {LaunchFork} from "./LaunchFork.sol";
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
contract LaunchForkTest is LaunchFork {
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
}
