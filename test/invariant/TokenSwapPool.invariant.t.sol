// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {TokenSwapPool} from "../../src/TokenSwapPool.sol";
import {MockERC20} from "../TokenSwapPool.t.sol";

/// @notice Drives the pool with random, bounded actions from several actors.
///         Reverting calls are swallowed so the fuzzer keeps exploring, and
///         ghost variables record anything that should never happen.
contract Handler is CommonBase, StdCheats, StdUtils {
    uint256 public constant ACTOR_COUNT = 3;

    TokenSwapPool public pool;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    address[] public actors;

    /// Ghost: set if k = reserveA * reserveB ever drops after a swap or deposit.
    bool public kDecreased;

    uint256 public addCalls;
    uint256 public removeCalls;
    uint256 public swapCalls;

    constructor(TokenSwapPool _pool, MockERC20 _tokenA, MockERC20 _tokenB) {
        pool = _pool;
        tokenA = _tokenA;
        tokenB = _tokenB;

        for (uint256 i; i < ACTOR_COUNT; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(actor);

            tokenA.mint(actor, 1e40);
            tokenB.mint(actor, 1e40);

            vm.startPrank(actor);
            tokenA.approve(address(pool), type(uint256).max);
            tokenB.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _k() internal view returns (uint256) {
        return pool.reserveA() * pool.reserveB();
    }

    function addLiquidity(uint256 actorSeed, uint256 amountA, uint256 amountB) external {
        address actor = _actor(actorSeed);
        amountA = bound(amountA, 1e6, 1e24);
        amountB = bound(amountB, 1e6, 1e24);

        uint256 kBefore = _k();

        vm.prank(actor);
        try pool.addLiquidity(amountA, amountB) returns (uint256) {
            addCalls++;
        } catch {
            return;
        }

        if (_k() < kBefore) kDecreased = true;
    }

    function removeLiquidity(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = _actor(actorSeed);

        uint256 owned = pool.liquidityShares(actor);
        if (owned == 0) return;

        uint256 sharesToBurn = bound(sharesSeed, 1, owned);

        vm.prank(actor);
        try pool.removeLiquidity(sharesToBurn) returns (uint256, uint256) {
            removeCalls++;
        } catch {}
    }

    function swap(uint256 actorSeed, bool aToB, uint256 amountIn) external {
        address actor = _actor(actorSeed);
        amountIn = bound(amountIn, 1e6, 1e24);
        address tokenIn = aToB ? address(tokenA) : address(tokenB);

        uint256 kBefore = _k();

        vm.prank(actor);
        try pool.swap(tokenIn, amountIn, 0) returns (uint256) {
            swapCalls++;
        } catch {
            return;
        }

        if (_k() < kBefore) kDecreased = true;
    }
}

contract TokenSwapPoolInvariantTest is Test {
    MockERC20 tokenA;
    MockERC20 tokenB;
    TokenSwapPool pool;
    Handler handler;

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        pool = new TokenSwapPool(address(tokenA), address(tokenB), 30);
        handler = new Handler(pool, tokenA, tokenB);

        // Seed the pool so swaps and withdrawals are reachable immediately.
        handler.addLiquidity(0, 100e18, 400e18);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = Handler.addLiquidity.selector;
        selectors[1] = Handler.removeLiquidity.selector;
        selectors[2] = Handler.swap.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// Tracked reserves always equal the pool's real token balances.
    function invariant_reservesMatchBalances() public view {
        assertEq(pool.reserveA(), tokenA.balanceOf(address(pool)), "reserveA != balance");
        assertEq(pool.reserveB(), tokenB.balanceOf(address(pool)), "reserveB != balance");
    }

    /// Every share is accounted for: LP shares + locked shares == totalShares.
    function invariant_sharesAddUp() public view {
        uint256 sum = pool.liquidityShares(address(0));
        for (uint256 i; i < handler.ACTOR_COUNT(); i++) {
            sum += pool.liquidityShares(handler.actors(i));
        }
        assertEq(sum, pool.totalShares(), "share accounting broken");
    }

    /// Swaps and deposits never reduce k (fees and rounding favour the pool).
    function invariant_kNeverDecreases() public view {
        assertFalse(handler.kDecreased(), "k decreased");
    }

    /// The permanently locked shares can never be touched.
    function invariant_lockedLiquidityIntact() public view {
        assertEq(pool.liquidityShares(address(0)), pool.MINIMUM_LIQUIDITY());
        assertGe(pool.totalShares(), pool.MINIMUM_LIQUIDITY());
    }

    /// Once seeded, the pool can never be drained to zero in either token.
    function invariant_reservesNeverZero() public view {
        assertGt(pool.reserveA(), 0, "reserveA drained");
        assertGt(pool.reserveB(), 0, "reserveB drained");
    }
}
