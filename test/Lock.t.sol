// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LaunchFork} from "./LaunchFork.sol";
import {TicksToken} from "../src/TicksToken.sol";
import {LaunchPlan} from "../script/LaunchPlan.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

interface IUncxV4Locker {
    function lockNFTPosition(uint256 tokenId, uint256 unlockTime, bool mintLockNFT)
        external
        payable
        returns (uint256 lockId);
    function collect(uint256 lockId, address recipient)
        external
        returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1);
    function unlockLiquidity(uint256 lockId) external;
    function relock(uint256 lockId, uint256 newUnlockTime) external;
    function transferLockOwnership(uint256 lockId, address newOwner) external;
    function flatFee() external view returns (uint256);
    function FEE_ADDR_LP() external view returns (address);
    function FEE_ADDR_COLLECT() external view returns (address);
}

contract UncxLockForkTest is LaunchFork {
    IUncxV4Locker constant LOCKER = IUncxV4Locker(0x128A800cBc615cc110Bff16E475865c67631603A);
    IPositionManager constant POSM = IPositionManager(LaunchPlan.POSITION_MANAGER);

    function test_uncxLock_costs_rules_and_fees() public {
        TicksToken token = _deployToken(bytes32(0));
        (LaunchPlan.Plan memory p, uint256 tokenId) = _launch(token, address(0), 18, ETH_PRICE_E6);
        uint128 liquidityBefore = POSM.getPositionLiquidity(tokenId);
        address lpFeeTo = LOCKER.FEE_ADDR_LP();
        address collectFeeTo = LOCKER.FEE_ADDR_COLLECT();
        uint256 lpFeeToEthBefore = lpFeeTo.balance;

        vm.deal(owner, 1 ether);
        vm.startPrank(owner);
        IERC721(address(POSM)).approve(address(LOCKER), tokenId);
        uint256 unlockAt = block.timestamp + 365 days;
        uint256 lockId = LOCKER.lockNFTPosition{value: LOCKER.flatFee()}(tokenId, unlockAt, false);
        vm.stopPrank();

        assertEq(IERC721(address(POSM)).ownerOf(tokenId), address(LOCKER));
        assertEq(lpFeeTo.balance - lpFeeToEthBefore, 0.1 ether);
        assertApproxEqAbs(POSM.getPositionLiquidity(tokenId), liquidityBefore - liquidityBefore / 100, 1);
        assertApproxEqRel(token.balanceOf(lpFeeTo), POOL_TOKENS / 100, 0.001e18);
        console2.log("lock fee: 0.1 ETH plus TICKS taken from the position", token.balanceOf(lpFeeTo) / 1e18);

        _buy(p, 0.1 ether);
        uint256 ownerBefore = owner.balance;
        uint256 uncxBefore = collectFeeTo.balance;
        vm.prank(owner);
        LOCKER.collect(lockId, owner);
        uint256 received = owner.balance - ownerBefore;
        uint256 cut = collectFeeTo.balance - uncxBefore;
        assertApproxEqRel(received + cut, 0.003 ether, 0.01e18);
        assertApproxEqRel(cut * 10_000 / (received + cut), 400, 0.01e18);
        console2.log("fees from a 0.1 ETH buy, owner got (wei)", received);
        console2.log("fees from a 0.1 ETH buy, UNCX kept (wei)", cut);

        vm.prank(owner);
        vm.expectRevert();
        LOCKER.unlockLiquidity(lockId);

        vm.prank(buyer);
        vm.expectRevert();
        LOCKER.collect(lockId, buyer);

        vm.prank(owner);
        vm.expectRevert();
        LOCKER.relock(lockId, unlockAt - 1 days);

        vm.prank(owner);
        LOCKER.relock(lockId, unlockAt + 30 days);

        address next = makeAddr("next owner");
        vm.prank(owner);
        LOCKER.transferLockOwnership(lockId, next);

        vm.prank(owner);
        vm.expectRevert();
        LOCKER.collect(lockId, owner);

        _buy(p, 0.1 ether);
        vm.prank(next);
        LOCKER.collect(lockId, next);
        assertApproxEqRel(next.balance, 0.00288 ether, 0.02e18);

        vm.warp(unlockAt + 31 days);
        vm.prank(next);
        LOCKER.unlockLiquidity(lockId);
        assertEq(IERC721(address(POSM)).ownerOf(tokenId), next);
    }

    function _buy(LaunchPlan.Plan memory p, uint256 amount) internal {
        vm.deal(buyer, amount);
        vm.prank(buyer);
        router.swap{value: amount}(p.key, _exactIn(true, amount), _settings(), "");
    }
}

interface ITitanLockerManager {
    function createPositionLock(address positionManager, uint256 tokenId, uint40 unlockTime) external payable;
    function ethFee() external view returns (uint256);
    function feeReceiver() external view returns (address);
    function tokenLockerCount() external view returns (uint40);
    function getTokenLockAddress(uint40 id) external view returns (address);
}

interface ITitanLock {
    function collectFees() external returns (uint256 amount0, uint256 amount1);
    function withdraw() external;
    function withdrawNft(address collection, uint256 tokenId) external;
    function extendLock(uint40 newUnlockTime) external;
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
}

contract TitanLockForkTest is LaunchFork {
    ITitanLockerManager constant TITAN = ITitanLockerManager(0x102a70bDA2C833b3483A2eE55C14c7ea0fb7A01B);
    IPositionManager constant POSM = IPositionManager(LaunchPlan.POSITION_MANAGER);

    function test_titanLock_costs_rules_and_fees() public {
        TicksToken token = _deployToken(bytes32(0));
        (LaunchPlan.Plan memory p, uint256 tokenId) = _launch(token, address(0), 18, ETH_PRICE_E6);
        uint128 liquidityBefore = POSM.getPositionLiquidity(tokenId);
        address feeTo = TITAN.feeReceiver();
        uint256 feeToBefore = feeTo.balance;

        vm.deal(owner, 1 ether);
        vm.startPrank(owner);
        IERC721(address(POSM)).approve(address(TITAN), tokenId);
        uint40 unlockAt = uint40(block.timestamp + 365 days);
        uint40 id = TITAN.tokenLockerCount();
        TITAN.createPositionLock{value: TITAN.ethFee()}(address(POSM), tokenId, unlockAt);
        vm.stopPrank();
        ITitanLock lock = ITitanLock(TITAN.getTokenLockAddress(id));

        assertEq(IERC721(address(POSM)).ownerOf(tokenId), address(lock));
        assertEq(lock.owner(), owner);
        assertEq(POSM.getPositionLiquidity(tokenId), liquidityBefore);
        assertEq(feeTo.balance - feeToBefore, TITAN.ethFee());
        assertEq(token.balanceOf(feeTo), 0);
        console2.log("titan lock fee (wei), nothing taken from the position", TITAN.ethFee());

        _buy(p, 0.1 ether);
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        lock.collectFees();
        assertApproxEqRel(owner.balance - ownerBefore, 0.003 ether, 0.01e18);
        console2.log("fees from a 0.1 ETH buy, owner got (wei)", owner.balance - ownerBefore);

        vm.prank(owner);
        vm.expectRevert();
        lock.withdraw();

        vm.prank(owner);
        vm.expectRevert();
        lock.withdrawNft(address(POSM), tokenId);

        vm.prank(buyer);
        vm.expectRevert();
        lock.collectFees();

        vm.prank(owner);
        vm.expectRevert();
        lock.extendLock(unlockAt - 1 days);

        vm.prank(owner);
        lock.extendLock(unlockAt + 30 days);

        address next = makeAddr("next owner");
        vm.prank(owner);
        lock.transferOwnership(next);

        vm.prank(owner);
        vm.expectRevert();
        lock.collectFees();

        _buy(p, 0.1 ether);
        vm.prank(next);
        lock.collectFees();
        assertApproxEqRel(next.balance, 0.003 ether, 0.02e18);

        vm.warp(unlockAt + 31 days);
        vm.prank(next);
        lock.withdraw();
        assertEq(IERC721(address(POSM)).ownerOf(tokenId), next);
    }

    function _buy(LaunchPlan.Plan memory p, uint256 amount) internal {
        vm.deal(buyer, amount);
        vm.prank(buyer);
        router.swap{value: amount}(p.key, _exactIn(true, amount), _settings(), "");
    }
}
