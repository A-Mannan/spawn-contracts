// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/// @notice Toolchain smoke test: proves the pinned v4-core/v4-periphery remappings resolve and
/// that the dependency pair compiles under solc 0.8.26 / cancun.
///
/// It also pins down the hook flag bitmask the protocol needs, which the address miner
/// (task 14.1) and the hook's own permission declaration (task 3.1) must both agree with.
contract SmokeTest is Test {
    /// @dev The flag set declared by openspec token-launch spec, "Hook address encodes required
    /// permissions": before/after initialize, before add/remove liquidity, before/after swap.
    uint160 internal constant EXPECTED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG;

    function test_remappingsResolve() public pure {
        // Referencing the nested param structs proves v4-core@5f00c84 still nests them under
        // IPoolManager, which is what v4-periphery@9628c36's BaseHook signatures require.
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        IPoolManager.ModifyLiquidityParams memory liqParams =
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)});

        assertTrue(swapParams.zeroForOne, "swap params readable");
        assertEq(liqParams.tickUpper, int24(60), "liquidity params readable");
    }

    function test_expectedHookFlagBitmask() public pure {
        // 1<<13 | 1<<12 | 1<<11 | 1<<9 | 1<<7 | 1<<6
        assertEq(uint256(EXPECTED_HOOK_FLAGS), 15040, "hook flag bitmask");
        assertEq(uint256(EXPECTED_HOOK_FLAGS) & uint256(Hooks.ALL_HOOK_MASK), 15040, "flags fit the hook mask");
    }

    function test_flagsExcludeUnusedCallbacks() public pure {
        assertEq(EXPECTED_HOOK_FLAGS & Hooks.AFTER_ADD_LIQUIDITY_FLAG, 0, "no afterAddLiquidity");
        assertEq(EXPECTED_HOOK_FLAGS & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG, 0, "no afterRemoveLiquidity");
        assertEq(EXPECTED_HOOK_FLAGS & Hooks.BEFORE_DONATE_FLAG, 0, "no beforeDonate");
        assertEq(EXPECTED_HOOK_FLAGS & Hooks.AFTER_DONATE_FLAG, 0, "no afterDonate");
        // The protocol returns no hook deltas; it settles through take/settle instead.
        assertEq(EXPECTED_HOOK_FLAGS & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG, 0, "no beforeSwap delta");
        assertEq(EXPECTED_HOOK_FLAGS & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG, 0, "no afterSwap delta");
    }

    /// @dev The dynamic fee flag lives in PoolKey.fee, not in the hook address.
    function test_dynamicFeeFlagIsAPoolFeeFlag() public pure {
        assertEq(uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG), 0x800000, "dynamic fee flag");
        assertTrue(LPFeeLibrary.isDynamicFee(LPFeeLibrary.DYNAMIC_FEE_FLAG), "flag marks a dynamic fee");
    }
}
