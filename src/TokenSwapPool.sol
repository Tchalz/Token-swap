// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Simple Token Swap Pool
/// @notice Constant-product (x * y = k) AMM for a single tokenA/tokenB pair.
contract TokenSwapPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    // State
    // ---------------------------------------------------------------

    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;

    /// @dev Pool reserves. Kept in sync with actual balances after every
    ///      deposit/withdraw/swap. This is the invariant to test.
    uint256 public reserveA;
    uint256 public reserveB;

    /// @dev Simple proportional shares (not an ERC-20 LP token).
    mapping(address => uint256) public liquidityShares;
    uint256 public totalShares;

    /// @dev Swap fee in basis points (30 = 0.3%). Set once in the constructor.
    ///      The fee stays in the pool, so LPs earn it on withdrawal.
    uint256 public immutable swapFeeBps;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000; // 10% sanity cap

    /// @dev Shares permanently locked on the first deposit (Uniswap V2 trick)
    ///      so the share price can't be manipulated by a tiny first deposit.
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB, uint256 shares);
    event Swap(address indexed trader, address tokenIn, uint256 amountIn, uint256 amountOut);

    // ---------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------

    error InsufficientLiquidity();
    error InsufficientOutputAmount();
    error InsufficientShares();
    error InvalidToken();
    error InvalidFee();
    error ZeroAmount();

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    /// @param _swapFeeBps Fee in basis points, e.g. 30 for 0.3%. Pass 0 for no fee.
    constructor(address _tokenA, address _tokenB, uint256 _swapFeeBps) {
        if (_tokenA == address(0) || _tokenB == address(0) || _tokenA == _tokenB) revert InvalidToken();
        if (_swapFeeBps > MAX_FEE_BPS) revert InvalidFee();

        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
        swapFeeBps = _swapFeeBps;
    }

    // ---------------------------------------------------------------
    // Core functions
    // ---------------------------------------------------------------

    /// @notice Deposit both tokens in proportion to current reserves
    ///         (or in any ratio if the pool is empty) and mint the
    ///         caller a share of the pool.
    function addLiquidity(uint256 amountADesired, uint256 amountBDesired)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (amountADesired == 0 || amountBDesired == 0) revert ZeroAmount();

        uint256 amountA;
        uint256 amountB;

        if (totalShares == 0) {
            // First deposit sets the pool price.
            amountA = amountADesired;
            amountB = amountBDesired;

            uint256 initial = _sqrt(amountA * amountB);
            if (initial <= MINIMUM_LIQUIDITY) revert InsufficientLiquidity();

            shares = initial - MINIMUM_LIQUIDITY;

            // Lock the minimum liquidity forever.
            totalShares = MINIMUM_LIQUIDITY;
            liquidityShares[address(0)] = MINIMUM_LIQUIDITY;
        } else {
            // Must match the current ratio.
            uint256 amountBRequired = (amountADesired * reserveB) / reserveA;

            if (amountBRequired <= amountBDesired) {
                amountA = amountADesired;
                amountB = amountBRequired;
            } else {
                amountA = (amountBDesired * reserveA) / reserveB;
                amountB = amountBDesired;
            }

            // Shares proportional to the SMALLER of the two contribution
            // ratios, so rounding can never favour the depositor.
            uint256 sharesA = (amountA * totalShares) / reserveA;
            uint256 sharesB = (amountB * totalShares) / reserveB;
            shares = sharesA < sharesB ? sharesA : sharesB;
        }

        if (shares == 0 || amountA == 0 || amountB == 0) revert InsufficientLiquidity();

        // Effects before interactions.
        reserveA += amountA;
        reserveB += amountB;
        totalShares += shares;
        liquidityShares[msg.sender] += shares;

        tokenA.safeTransferFrom(msg.sender, address(this), amountA);
        tokenB.safeTransferFrom(msg.sender, address(this), amountB);

        emit LiquidityAdded(msg.sender, amountA, amountB, shares);
    }

    /// @notice Burn the caller's shares and return their proportional
    ///         amount of both tokens.
    function removeLiquidity(uint256 sharesToBurn) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        if (sharesToBurn == 0) revert ZeroAmount();
        if (liquidityShares[msg.sender] < sharesToBurn) revert InsufficientShares();

        amountA = (reserveA * sharesToBurn) / totalShares;
        amountB = (reserveB * sharesToBurn) / totalShares;
        if (amountA == 0 || amountB == 0) revert InsufficientLiquidity();

        liquidityShares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        reserveA -= amountA;
        reserveB -= amountB;

        tokenA.safeTransfer(msg.sender, amountA);
        tokenB.safeTransfer(msg.sender, amountB);

        emit LiquidityRemoved(msg.sender, amountA, amountB, sharesToBurn);
    }

    /// @notice Swap an exact amount of one token for the other.
    /// @param tokenIn Address of tokenA or tokenB.
    /// @param amountIn Amount of tokenIn the caller is sending.
    /// @param minAmountOut Slippage protection: revert if output is less.
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();

        bool aIn = tokenIn == address(tokenA);
        amountOut = _quote(tokenIn, amountIn);

        if (amountOut == 0 || amountOut < minAmountOut) revert InsufficientOutputAmount();

        // Full amountIn (fee included) goes into reserves; that is how LPs earn.
        if (aIn) {
            reserveA += amountIn;
            reserveB -= amountOut;
        } else {
            reserveB += amountIn;
            reserveA -= amountOut;
        }

        (IERC20 inToken, IERC20 outToken) = aIn ? (tokenA, tokenB) : (tokenB, tokenA);
        inToken.safeTransferFrom(msg.sender, address(this), amountIn);
        outToken.safeTransfer(msg.sender, amountOut);

        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
    }

    // ---------------------------------------------------------------
    // View helpers
    // ---------------------------------------------------------------

    /// @notice Quote how much output a given input would currently buy.
    function getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        return _quote(tokenIn, amountIn);
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserveA, reserveB);
    }

    // ---------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------

    /// @dev amountOut = (reserveOut * amountInAfterFee) / (reserveIn + amountInAfterFee)
    ///      computed in BPS units to avoid precision loss.
    function _quote(address tokenIn, uint256 amountIn) internal view returns (uint256) {
        if (tokenIn != address(tokenA) && tokenIn != address(tokenB)) revert InvalidToken();

        (uint256 reserveIn, uint256 reserveOut) =
            tokenIn == address(tokenA) ? (reserveA, reserveB) : (reserveB, reserveA);

        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        uint256 amountInWithFee = amountIn * (BPS - swapFeeBps);
        return (amountInWithFee * reserveOut) / (reserveIn * BPS + amountInWithFee);
    }

    /// @dev Integer square root (Babylonian method).
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
