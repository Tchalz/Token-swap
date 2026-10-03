import { parseAbi } from 'viem'

// Addresses from a fresh Anvil chain + `forge script script/Deploy.s.sol --tc Deploy --broadcast`.
// If you restart Anvil and redeploy from a different account/nonce, update these.
export const POOL = '0x9fe46736679d2d9a65f0992f2272de9f3c7fa6e0'
export const TOKEN_A = '0x5fbdb2315678afecb367f032d93f642f64180aa3'
export const TOKEN_B = '0xe7f1725e7734ce288f8367e1bb143e90bb3f0512'

export const poolAbi = parseAbi([
  'function getReserves() view returns (uint256, uint256)',
  'function getAmountOut(address tokenIn, uint256 amountIn) view returns (uint256)',
  'function liquidityShares(address) view returns (uint256)',
  'function totalShares() view returns (uint256)',
  'function addLiquidity(uint256 amountADesired, uint256 amountBDesired) returns (uint256)',
  'function removeLiquidity(uint256 sharesToBurn) returns (uint256, uint256)',
  'function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut) returns (uint256)',
])

export const tokenAbi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function mint(address to, uint256 amount)',
])
