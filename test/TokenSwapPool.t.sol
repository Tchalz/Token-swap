// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenSwapPool} from "../src/TokenSwapPool.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TokenSwapPoolTest is Test {
    MockERC20 tokenA;
    MockERC20 tokenB;
    TokenSwapPool pool;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address trader = makeAddr("trader");

    uint256 constant FEE = 30; // 0.3%
    uint256 constant MIN_LIQ = 1_000;
    uint256 constant START = 1e30;

    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB, uint256 shares);
    event Swap(address indexed trader, address tokenIn, uint256 amountIn, uint256 amountOut);

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        pool = new TokenSwapPool(address(tokenA), address(tokenB), FEE);

        address[3] memory users = [alice, bob, trader];
        for (uint256 i; i < users.length; i++) {
            tokenA.mint(users[i], START);
            tokenB.mint(users[i], START);
            vm.startPrank(users[i]);
            tokenA.approve(address(pool), type(uint256).max);
            tokenB.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// Alice seeds the pool at 100 A : 400 B (price 1 A = 4 B).
    function _seed() internal returns (uint256 shares) {
        vm.prank(alice);
        shares = pool.addLiquidity(100e18, 400e18);
    }

    /// Core invariant: tracked reserves always equal real token balances.
    function _assertReservesMatchBalances() internal view {
        assertEq(pool.reserveA(), tokenA.balanceOf(address(pool)), "reserveA != balance");
        assertEq(pool.reserveB(), tokenB.balanceOf(address(pool)), "reserveB != balance");
    }

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    function test_constructor_setsState() public view {
        assertEq(address(pool.tokenA()), address(tokenA));
        assertEq(address(pool.tokenB()), address(tokenB));
        assertEq(pool.swapFeeBps(), FEE);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(TokenSwapPool.InvalidToken.selector);
        new TokenSwapPool(address(0), address(tokenB), FEE);
    }

    function test_constructor_revertsOnIdenticalTokens() public {
        vm.expectRevert(TokenSwapPool.InvalidToken.selector);
        new TokenSwapPool(address(tokenA), address(tokenA), FEE);
    }

    function test_constructor_revertsOnExcessiveFee() public {
        vm.expectRevert(TokenSwapPool.InvalidFee.selector);
        new TokenSwapPool(address(tokenA), address(tokenB), 1_001);
    }

    // ---------------------------------------------------------------
    // addLiquidity
    // ---------------------------------------------------------------

    function test_addLiquidity_first_mintsSqrtMinusLocked() public {
        // sqrt(100e18 * 400e18) = 200e18
        uint256 shares = _seed();

        assertEq(shares, 200e18 - MIN_LIQ);
        assertEq(pool.liquidityShares(alice), 200e18 - MIN_LIQ);
        assertEq(pool.liquidityShares(address(0)), MIN_LIQ);
        assertEq(pool.totalShares(), 200e18);
        assertEq(pool.reserveA(), 100e18);
        assertEq(pool.reserveB(), 400e18);
        _assertReservesMatchBalances();
    }

    function test_addLiquidity_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit LiquidityAdded(alice, 100e18, 400e18, 200e18 - MIN_LIQ);
        vm.prank(alice);
        pool.addLiquidity(100e18, 400e18);
    }

    function test_addLiquidity_revertsOnZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(TokenSwapPool.ZeroAmount.selector);
        pool.addLiquidity(0, 100e18);
        vm.expectRevert(TokenSwapPool.ZeroAmount.selector);
        pool.addLiquidity(100e18, 0);
        vm.stopPrank();
    }

    function test_addLiquidity_first_revertsIfTooSmall() public {
        // sqrt(1000 * 1000) = 1000 <= MINIMUM_LIQUIDITY
        vm.prank(alice);
        vm.expectRevert(TokenSwapPool.InsufficientLiquidity.selector);
        pool.addLiquidity(1_000, 1_000);
    }

    function test_addLiquidity_second_proportional_usesOnlyRequired() public {
        _seed();

        // Bob offers way more B than needed; only 200e18 B is taken.
        uint256 bobA = tokenA.balanceOf(bob);
        uint256 bobB = tokenB.balanceOf(bob);

        vm.prank(bob);
        uint256 shares = pool.addLiquidity(50e18, 1_000e18);

        assertEq(shares, 100e18); // 50/100 of 200e18 total shares
        assertEq(bobA - tokenA.balanceOf(bob), 50e18);
        assertEq(bobB - tokenB.balanceOf(bob), 200e18);
        assertEq(pool.reserveA(), 150e18);
        assertEq(pool.reserveB(), 600e18);
        _assertReservesMatchBalances();
    }

    function test_addLiquidity_second_scalesDownA() public {
        _seed();

        // Bob only has 40 B, so A is scaled down to 10.
        vm.prank(bob);
        uint256 shares = pool.addLiquidity(100e18, 40e18);

        assertEq(shares, 20e18);
        assertEq(pool.reserveA(), 110e18);
        assertEq(pool.reserveB(), 440e18);
        _assertReservesMatchBalances();
    }

    function test_addLiquidity_preservesPrice() public {
        _seed();
        vm.prank(bob);
        pool.addLiquidity(33e18, 500e18);

        // Ratio B/A should still be 4 (within integer rounding).
        assertApproxEqRel(pool.reserveB() * 1e18 / pool.reserveA(), 4e18, 1e6);
    }

    // ---------------------------------------------------------------
    // removeLiquidity
    // ---------------------------------------------------------------

    function test_removeLiquidity_full_leavesOnlyLockedShares() public {
        uint256 shares = _seed();

        vm.prank(alice);
        (uint256 a, uint256 b) = pool.removeLiquidity(shares);

        assertEq(a, 100e18 - 500);
        assertEq(b, 400e18 - 2_000);
        assertEq(pool.liquidityShares(alice), 0);
        assertEq(pool.totalShares(), MIN_LIQ);
        assertEq(pool.reserveA(), 500);
        assertEq(pool.reserveB(), 2_000);
        _assertReservesMatchBalances();
    }

    function test_removeLiquidity_partial() public {
        uint256 shares = _seed();

        vm.prank(alice);
        (uint256 a, uint256 b) = pool.removeLiquidity(shares / 2);

        assertApproxEqAbs(a, 50e18, 1_000);
        assertApproxEqAbs(b, 200e18, 4_000);
        assertEq(pool.liquidityShares(alice), shares - shares / 2);
        _assertReservesMatchBalances();
    }

    function test_removeLiquidity_emitsEvent() public {
        uint256 shares = _seed();

        vm.expectEmit(true, false, false, true);
        emit LiquidityRemoved(alice, 100e18 - 500, 400e18 - 2_000, shares);
        vm.prank(alice);
        pool.removeLiquidity(shares);
    }

    function test_removeLiquidity_revertsOnZero() public {
        _seed();
        vm.prank(alice);
        vm.expectRevert(TokenSwapPool.ZeroAmount.selector);
        pool.removeLiquidity(0);
    }

    function test_removeLiquidity_revertsIfNotEnoughShares() public {
        uint256 shares = _seed();

        vm.prank(alice);
        vm.expectRevert(TokenSwapPool.InsufficientShares.selector);
        pool.removeLiquidity(shares + 1);

        vm.prank(bob); // bob has none
        vm.expectRevert(TokenSwapPool.InsufficientShares.selector);
        pool.removeLiquidity(1);
    }

    function test_removeLiquidity_earnsSwapFees() public {
        uint256 shares = _seed();

        uint256 aliceBefore = tokenA.balanceOf(alice) + tokenB.balanceOf(alice) / 4;

        // Round-trip volume through the pool to generate fees.
        vm.startPrank(trader);
        for (uint256 i; i < 10; i++) {
            uint256 outB = pool.swap(address(tokenA), 5e18, 0);
            pool.swap(address(tokenB), outB, 0);
        }
        vm.stopPrank();

        vm.prank(alice);
        pool.removeLiquidity(shares);

        // Valued at the original 1 A = 4 B price, Alice's position grew.
        uint256 aliceAfter = tokenA.balanceOf(alice) + tokenB.balanceOf(alice) / 4;
        assertGt(aliceAfter, aliceBefore);
    }

    // ---------------------------------------------------------------
    // swap
    // ---------------------------------------------------------------

    function test_swap_AtoB_matchesFormula() public {
        _seed();

        uint256 amountIn = 10e18;
        uint256 withFee = amountIn * (10_000 - FEE);
        uint256 expected = (withFee * 400e18) / (100e18 * 10_000 + withFee);

        // Sanity check on the formula itself: roughly 36.26 B for 10 A.
        assertGt(expected, 36e18);
        assertLt(expected, 37e18);

        assertEq(pool.getAmountOut(address(tokenA), amountIn), expected);

        uint256 balBefore = tokenB.balanceOf(trader);
        vm.prank(trader);
        uint256 out = pool.swap(address(tokenA), amountIn, expected);

        assertEq(out, expected);
        assertEq(tokenB.balanceOf(trader) - balBefore, expected);
        assertEq(pool.reserveA(), 110e18);
        assertEq(pool.reserveB(), 400e18 - expected);
        _assertReservesMatchBalances();
    }

    function test_swap_BtoA() public {
        _seed();

        uint256 quote = pool.getAmountOut(address(tokenB), 40e18);
        vm.prank(trader);
        uint256 out = pool.swap(address(tokenB), 40e18, quote);

        assertEq(out, quote);
        assertEq(pool.reserveB(), 440e18);
        assertEq(pool.reserveA(), 100e18 - quote);
        _assertReservesMatchBalances();
    }

    function test_swap_emitsEvent() public {
        _seed();
        uint256 quote = pool.getAmountOut(address(tokenA), 1e18);

        vm.expectEmit(true, false, false, true);
        emit Swap(trader, address(tokenA), 1e18, quote);
        vm.prank(trader);
        pool.swap(address(tokenA), 1e18, 0);
    }

    function test_swap_revertsOnSlippage() public {
        _seed();
        uint256 quote = pool.getAmountOut(address(tokenA), 10e18);

        vm.prank(trader);
        vm.expectRevert(TokenSwapPool.InsufficientOutputAmount.selector);
        pool.swap(address(tokenA), 10e18, quote + 1);
    }

    function test_swap_revertsOnInvalidToken() public {
        _seed();
        vm.prank(trader);
        vm.expectRevert(TokenSwapPool.InvalidToken.selector);
        pool.swap(address(0xdead), 1e18, 0);

        vm.expectRevert(TokenSwapPool.InvalidToken.selector);
        pool.getAmountOut(address(0xdead), 1e18);
    }

    function test_swap_revertsOnZeroAmount() public {
        _seed();
        vm.prank(trader);
        vm.expectRevert(TokenSwapPool.ZeroAmount.selector);
        pool.swap(address(tokenA), 0, 0);
    }

    function test_swap_revertsOnEmptyPool() public {
        vm.prank(trader);
        vm.expectRevert(TokenSwapPool.InsufficientLiquidity.selector);
        pool.swap(address(tokenA), 1e18, 0);
    }

    function test_swap_revertsIfOutputRoundsToZero() public {
        _seed();
        // 1 wei of A buys 3.99 wei of B at fee-adjusted price; 1 wei of B buys 0 A.
        vm.prank(trader);
        vm.expectRevert(TokenSwapPool.InsufficientOutputAmount.selector);
        pool.swap(address(tokenB), 1, 0);
    }

    function test_swap_hugeInputNeverDrainsPool() public {
        _seed();
        vm.prank(trader);
        uint256 out = pool.swap(address(tokenA), 1e27, 0);

        assertLt(out, 400e18); // always strictly less than reserveOut
        assertGt(pool.reserveB(), 0);
        _assertReservesMatchBalances();
    }

    function test_swap_zeroFeePool() public {
        TokenSwapPool p0 = new TokenSwapPool(address(tokenA), address(tokenB), 0);
        vm.startPrank(alice);
        tokenA.approve(address(p0), type(uint256).max);
        tokenB.approve(address(p0), type(uint256).max);
        p0.addLiquidity(100e18, 400e18);
        vm.stopPrank();

        // Pure x*y=k: 100 in 100 => out 200 (400 * 100 / 200)
        assertEq(p0.getAmountOut(address(tokenA), 100e18), 200e18);
    }

    // ---------------------------------------------------------------
    // Edge cases / coverage
    // ---------------------------------------------------------------

    function test_getReserves() public {
        (uint256 a, uint256 b) = pool.getReserves();
        assertEq(a, 0);
        assertEq(b, 0);

        _seed();

        (a, b) = pool.getReserves();
        assertEq(a, 100e18);
        assertEq(b, 400e18);
    }

    function test_addLiquidity_revertsIfSharesRoundToZero() public {
        // Extreme price: 1e18 A : 1e30 B
        vm.prank(alice);
        pool.addLiquidity(1e18, 1e30);

        // amountA is scaled down to (1 * 1e18) / 1e30 = 0, so shares == 0.
        vm.prank(bob);
        vm.expectRevert(TokenSwapPool.InsufficientLiquidity.selector);
        pool.addLiquidity(1, 1);
    }

    function test_removeLiquidity_revertsIfPayoutRoundsToZero() public {
        uint256 aliceShares = _seed();

        // Alice exits: pool keeps 500 A / 2000 B and 1000 locked shares.
        vm.prank(alice);
        pool.removeLiquidity(aliceShares);

        // Bob deposits 1000 A / 4000 B -> totalShares = 3000, reserveA = 1500.
        vm.prank(bob);
        pool.addLiquidity(1_000, 4_000);

        // Burning 1 share: 1500 * 1 / 3000 = 0 A out, so it must revert.
        vm.prank(bob);
        vm.expectRevert(TokenSwapPool.InsufficientLiquidity.selector);
        pool.removeLiquidity(1);
    }

    // ---------------------------------------------------------------
    // Fuzz / invariants
    // ---------------------------------------------------------------

    /// k = reserveA * reserveB must never decrease after a swap.
    function testFuzz_swap_kNeverDecreases(uint256 amountIn, bool aToB) public {
        _seed();
        amountIn = bound(amountIn, 1e6, 1e24);

        uint256 kBefore = pool.reserveA() * pool.reserveB();

        vm.prank(trader);
        pool.swap(aToB ? address(tokenA) : address(tokenB), amountIn, 0);

        assertGe(pool.reserveA() * pool.reserveB(), kBefore, "k decreased");
        _assertReservesMatchBalances();
    }

    /// Quote must always equal the executed amount.
    function testFuzz_swap_quoteMatchesExecution(uint256 amountIn) public {
        _seed();
        amountIn = bound(amountIn, 1e6, 1e24);

        uint256 quote = pool.getAmountOut(address(tokenA), amountIn);
        vm.prank(trader);
        assertEq(pool.swap(address(tokenA), amountIn, quote), quote);
    }

    /// Depositing then immediately withdrawing must never be profitable.
    function testFuzz_addRemove_noFreeMoney(uint256 amtA, uint256 amtB) public {
        _seed();
        amtA = bound(amtA, 1e12, 1e24);
        amtB = bound(amtB, 1e12, 1e24);

        uint256 a0 = tokenA.balanceOf(bob);
        uint256 b0 = tokenB.balanceOf(bob);

        vm.startPrank(bob);
        uint256 shares = pool.addLiquidity(amtA, amtB);
        pool.removeLiquidity(shares);
        vm.stopPrank();

        assertLe(tokenA.balanceOf(bob), a0, "profited in A");
        assertLe(tokenB.balanceOf(bob), b0, "profited in B");
        _assertReservesMatchBalances();
    }

    /// Mixed sequence of operations; reserves must always match balances.
    function testFuzz_sequence_reservesMatchBalances(uint256 s1, uint256 s2, uint256 s3) public {
        _seed();

        vm.prank(trader);
        pool.swap(address(tokenA), bound(s1, 1e6, 1e24), 0);
        _assertReservesMatchBalances();

        vm.prank(bob);
        uint256 shares = pool.addLiquidity(bound(s2, 1e12, 1e24), bound(s2, 1e12, 1e24));
        _assertReservesMatchBalances();

        vm.prank(trader);
        pool.swap(address(tokenB), bound(s3, 1e6, 1e24), 0);
        _assertReservesMatchBalances();

        vm.prank(bob);
        pool.removeLiquidity(shares);
        _assertReservesMatchBalances();
    }
}
