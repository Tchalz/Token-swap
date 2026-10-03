# Token Swap Pool

A minimal constant-product automated market maker (AMM) for a single ERC-20 pair, written in Solidity and tested with Foundry. Built for the Capstone Group 10 project.

Liquidity providers deposit both tokens and receive pool shares. Traders swap one token for the other at a price set by the `x * y = k` formula, paying a small fee that accrues to liquidity providers.

## Features

- **Add / remove liquidity** with proportional share accounting (Uniswap V2 style).
- **Constant-product swaps** in both directions with slippage protection (`minAmountOut`).
- **Configurable swap fee** in basis points, set at deployment (capped at 10%).
- **Locked minimum liquidity** on the first deposit to prevent share-price manipulation.
- **Reentrancy protection** and safe ERC-20 transfers (OpenZeppelin `ReentrancyGuard`, `SafeERC20`).
- **Quote function** (`getAmountOut`) that returns exactly what a swap would pay out.

## Project structure

```
src/TokenSwapPool.sol                         The pool contract
test/TokenSwapPool.t.sol                      Unit and fuzz tests (+ MockERC20)
test/invariant/TokenSwapPool.invariant.t.sol  Invariant tests with a handler
foundry.toml                                  Compiler, fuzz, invariant and lint config
```

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone https://github.com/Tchalz/Token-swap.git
cd Token-swap
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std --no-commit
forge build
forge test
```

Useful extras:

```bash
forge test -vv                 # show logs and revert reasons
forge coverage                 # coverage table
forge test --gas-report        # per-function gas costs
forge lint                     # static lint checks
```

## Contract overview

### Constructor

```solidity
constructor(address _tokenA, address _tokenB, uint256 _swapFeeBps)
```

Reverts if either token is the zero address, if both tokens are the same, or if the fee exceeds 1,000 bps (10%). Use `30` for a 0.3% fee or `0` for no fee.

### Functions

| Function | Description |
|---|---|
| `addLiquidity(amountADesired, amountBDesired)` | Deposits both tokens and mints shares. After the first deposit, amounts are matched to the current ratio and only the required amounts are taken. |
| `removeLiquidity(sharesToBurn)` | Burns shares and returns a proportional amount of both tokens. |
| `swap(tokenIn, amountIn, minAmountOut)` | Swaps an exact input amount. Reverts if the output is below `minAmountOut`. |
| `getAmountOut(tokenIn, amountIn)` | Read-only quote for a swap. |
| `getReserves()` | Returns `(reserveA, reserveB)`. |

### Swap formula

With the fee applied to the input:

```
amountInWithFee = amountIn * (10000 - swapFeeBps)
amountOut       = (amountInWithFee * reserveOut) / (reserveIn * 10000 + amountInWithFee)
```

The full `amountIn` (fee included) is added to the reserves. Because the output is computed from the fee-adjusted amount, `k = reserveA * reserveB` grows with every swap, and liquidity providers collect that growth when they withdraw.

## Design decisions

- **First deposit sets the price.** Shares minted are `sqrt(amountA * amountB) - MINIMUM_LIQUIDITY`. This follows Uniswap V2.
- **1,000 shares are permanently locked** to `address(0)` on the first deposit. This blocks the classic attack where a tiny first deposit followed by a donation inflates the share price and rounds later depositors down to zero.
- **Shares use the smaller of the two ratios.** Later deposits mint `min(amountA * totalShares / reserveA, amountB * totalShares / reserveB)`, so rounding never favours the depositor.
- **Checks, effects, interactions.** State is updated before tokens move, and every state-changing function is `nonReentrant`.
- **Rounding always favours the pool.** All divisions round down, so a user can never extract more than they put in.
- **Simple shares instead of an LP token.** Shares are tracked in a mapping rather than an ERC-20. This is less composable but keeps the contract small and easy to audit.

## Testing

### Unit and fuzz tests (34 tests)

Covering the constructor, `addLiquidity`, `removeLiquidity`, `swap`, quotes and rounding edge cases. Four fuzz tests run 1,000 iterations each and check:

- `k` never decreases across a swap.
- `getAmountOut` always equals the amount actually received.
- Depositing and immediately withdrawing is never profitable.
- Tracked reserves equal real token balances after any mix of operations.

### Invariant tests (5 invariants)

A handler contract drives random, bounded calls to `addLiquidity`, `removeLiquidity` and `swap` from three actors (256 runs of 100 calls, 25,600 calls per invariant). After every sequence, these must hold:

| Invariant | Meaning |
|---|---|
| `reservesMatchBalances` | `reserveA` and `reserveB` equal the pool's token balances. |
| `sharesAddUp` | LP shares plus locked shares equal `totalShares`. |
| `kNeverDecreases` | No swap or deposit reduces `reserveA * reserveB`. |
| `lockedLiquidityIntact` | The 1,000 locked shares are never touched. |
| `reservesNeverZero` | The pool can never be drained to zero in either token. |

## Results

**Coverage**

| Metric | Result |
|---|---|
| Lines | 100% (79/79) |
| Statements | 100% (110/110) |
| Branches | 100% (18/18) |
| Functions | 100% (8/8) |

**Gas (average, from `forge test --gas-report`)**

| Function | Gas |
|---|---|
| `swap` | ~75,000 |
| `removeLiquidity` | ~77,000 |
| `addLiquidity` (normal deposit) | ~256,000 |
| `getAmountOut` | ~6,600 |

Deployed contract size is about 6.6 KB, well under the 24 KB limit.

## Known limitations

- **Standard ERC-20 tokens only.** Fee-on-transfer and rebasing tokens would break the reserve accounting, because reserves are updated from the requested amounts rather than measured balances.
- **No slippage parameters on `addLiquidity`.** A deposit can be front-run to a worse ratio. A production version would add `amountAMin` and `amountBMin`.
- **No deadline parameter** on swaps or deposits.
- **Fee is fixed at deployment** and there is no protocol fee or admin role.
- **No price oracle or flash swaps.**
- **Shares are not transferable**, since they are a mapping and not an ERC-20.
- **Not audited.** This is a learning project and should not hold real funds.

## Possible extensions

- Turn shares into an ERC-20 LP token.
- Add minimum-amount and deadline parameters to liquidity and swap calls.
- Add a TWAP price oracle.
- Support a factory that deploys one pool per token pair.
- Add a frontend that uses `getAmountOut` and `getReserves`.

## License

MIT
