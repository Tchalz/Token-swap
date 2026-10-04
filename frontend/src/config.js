import { parseAbi } from 'viem'
import { foundry, sepolia } from 'viem/chains'

// Pick the network with VITE_NETWORK (default: anvil).
//   npm run dev                         -> local Anvil chain
//   VITE_NETWORK=sepolia npm run dev    -> Sepolia testnet
const NETWORKS = {
  anvil: {
    chain: foundry,
    rpcUrl: 'http://127.0.0.1:8545',
    // MetaMask doesn't know this chain, so the app offers to add it.
    chainParams: {
      chainId: '0x7a69',
      chainName: 'Anvil Local',
      rpcUrls: ['http://127.0.0.1:8545'],
      nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    },
    // From a fresh Anvil chain + `forge script script/Deploy.s.sol --tc Deploy --broadcast`.
    pool: '0x9fe46736679d2d9a65f0992f2272de9f3c7fa6e0',
    tokenA: '0x5fbdb2315678afecb367f032d93f642f64180aa3',
    tokenB: '0xe7f1725e7734ce288f8367e1bb143e90bb3f0512',
  },
  sepolia: {
    chain: sepolia,
    rpcUrl: 'https://ethereum-sepolia-rpc.publicnode.com',
    chainParams: {
      chainId: '0xaa36a7',
      chainName: 'Sepolia',
      rpcUrls: ['https://ethereum-sepolia-rpc.publicnode.com'],
      nativeCurrency: { name: 'Sepolia ETH', symbol: 'ETH', decimals: 18 },
      blockExplorerUrls: ['https://sepolia.etherscan.io'],
    },
    // TODO: paste the addresses printed by your Sepolia deploy.
    pool: '0x199cdccb51ddff0dbfdce4d21af4f41d94dafbb2',
    tokenA: '0x8536a0b2daffbb9e22e6ac55e1cfd739b8c5c62f',
    tokenB: '0x9b43c9a0f7aeb471e3859e8dca1c85ee5a53adbd',
  },
}

const net = NETWORKS[import.meta.env.VITE_NETWORK || 'anvil']

export const CHAIN = net.chain
export const RPC_URL = net.rpcUrl
export const CHAIN_PARAMS = net.chainParams
export const POOL = net.pool
export const TOKEN_A = net.tokenA
export const TOKEN_B = net.tokenB

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
