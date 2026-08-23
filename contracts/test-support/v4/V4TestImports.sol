// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Compile-time imports so Hardhat emits artifacts for the Uniswap V4 stack
// used by local behavior tests (PoolManager + periphery lenses + test routers).

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

contract V4TestImports {}
