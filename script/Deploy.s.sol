// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenSwapPool} from "../src/TokenSwapPool.sol";

/// @notice Test token with an open mint, so the frontend can offer a faucet.
///         For local chains and testnets only. Never deploy this to mainnet.
contract TestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Deploys two test tokens and a swap pool, then seeds the pool
///         with initial liquidity at a price of 1 TKA = 4 TKB.
contract Deploy is Script {
    uint256 constant FEE_BPS = 30; // 0.3%
    uint256 constant SEED_A = 100_000e18;
    uint256 constant SEED_B = 400_000e18;

    function run() external {
        vm.startBroadcast();

        (, address deployer,) = vm.readCallers();

        TestToken tokenA = new TestToken("Token A", "TKA");
        TestToken tokenB = new TestToken("Token B", "TKB");
        TokenSwapPool pool = new TokenSwapPool(address(tokenA), address(tokenB), FEE_BPS);

        // Seed the pool so swaps work immediately.
        tokenA.mint(deployer, SEED_A);
        tokenB.mint(deployer, SEED_B);
        tokenA.approve(address(pool), SEED_A);
        tokenB.approve(address(pool), SEED_B);
        pool.addLiquidity(SEED_A, SEED_B);

        vm.stopBroadcast();

        console.log("Token A:", address(tokenA));
        console.log("Token B:", address(tokenB));
        console.log("Pool   :", address(pool));
    }
}
