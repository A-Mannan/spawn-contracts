// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {SwapAndFlushHelper} from "../../src/SwapAndFlushHelper.sol";
import {IPayoutFlusher} from "../../src/interfaces/IPayoutPlugin.sol";
import {MockPayoutHook, MockPoolManager} from "../mocks/PayoutReferenceMocks.sol";

contract SwapAndFlushHelperTest is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager internal manager;
    MockPayoutHook internal hook;
    SwapAndFlushHelper internal helper;
    MilestoneToken internal token;
    PoolKey internal key;
    PoolId internal poolId;

    address internal constant USER = address(0xA11CE);
    uint256 internal constant INPUT = 2 ether;
    uint256 internal constant OUTPUT = 500 ether;
    uint256 internal constant TIP = 0.01 ether;

    function setUp() public {
        manager = new MockPoolManager();
        hook = new MockPayoutHook();
        token = new MilestoneToken("Launch", "LCH", 1_000_000 ether, address(this));

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 10_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        hook.setSource(poolId, key, address(token));
        hook.setManager(manager);
        helper = new SwapAndFlushHelper(IPoolManager(address(manager)), IPayoutFlusher(address(hook)));

        token.transfer(address(manager), 10_000 ether);
        manager.configureSwap(INPUT, OUTPUT, key.currency1);
        vm.deal(address(hook), 100 ether);
        vm.deal(USER, 100 ether);
    }

    function _request() internal view returns (SwapAndFlushHelper.SwapRequest memory request) {
        request = SwapAndFlushHelper.SwapRequest({
            key: key,
            zeroForOne: true,
            amountSpecified: -int256(INPUT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }

    // --- Scenario: Opted-in caller swaps then flushes ---

    function test_optedInCallerSwapsThenFlushes() public {
        vm.prank(USER);
        helper.swapAndFlush{value: INPUT}(_request());

        assertEq(manager.swapCount(), 1, "ordinary swap executed");
        assertTrue(hook.flushCalled(), "flush followed settlement");
        assertEq(token.balanceOf(USER), OUTPUT, "swap output forwarded");
    }

    // --- Scenario: Helper uses a separate flush unlock ---

    function test_helperUsesSeparateFlushUnlock() public {
        vm.prank(USER);
        helper.swapAndFlush{value: INPUT}(_request());

        assertEq(manager.unlockCount(), 1, "helper opened only the swap unlock");
        assertEq(manager.settleCount(), 1, "swap settled before helper returned");
        assertTrue(hook.flushCalled(), "hook owns any later payout-pot unlock");
        assertTrue(hook.settlementCompleteAtFlush(), "swap unlock completed before flush");
    }

    // --- Scenario: Helper cannot alter routing ---

    function test_helperCannotAlterRouting() public {
        bytes4 selector =
            bytes4(keccak256("swapAndFlush((address,address,uint24,int24,address),bool,int256,uint160,uint256)"));
        (bool callable,) =
            address(helper).call(abi.encodeWithSelector(selector, key, true, -int256(INPUT), uint160(1), 1));

        assertFalse(callable, "no routing parameter overload exists");
        assertEq(address(helper.hook()), address(hook), "flush target is immutable");
    }

    // --- Scenario: Helper forwards the tip ---

    function test_helperForwardsTipAndRefund() public {
        hook.configureFlush(TIP, false);
        uint256 userBefore = USER.balance;

        vm.prank(USER);
        helper.swapAndFlush{value: INPUT + 1 ether}(_request());

        assertEq(USER.balance, userBefore - INPUT + TIP, "refund and tip returned");
        assertEq(address(helper).balance, 0, "helper retains no native value");
    }

    function test_helperDoesNotSweepPrefundedBalances() public {
        uint256 prefundedNative = 3 ether;
        uint256 prefundedToken = 17 ether;
        vm.deal(address(helper), prefundedNative);
        token.transfer(address(helper), prefundedToken);

        vm.prank(USER);
        helper.swapAndFlush{value: INPUT}(_request());

        assertEq(address(helper).balance, prefundedNative, "prefunded native remains isolated");
        assertEq(token.balanceOf(address(helper)), prefundedToken, "prefunded token remains isolated");
        assertEq(token.balanceOf(USER), OUTPUT, "only this swap's output forwarded");
    }

    // --- Scenario: Plugin failure does not undo the settled swap ---

    function test_pluginFailureDoesNotUndoSettledSwap() public {
        // The hook models plugin failure as successful flush completion with carry. The helper observes
        // only the narrow `flush(poolId)` success and therefore cannot reinterpret or reroute the carry.
        hook.configureFlush(0, false);

        vm.prank(USER);
        helper.swapAndFlush{value: INPUT}(_request());

        assertEq(manager.swapCount(), 1, "settled swap remains complete");
        assertEq(token.balanceOf(USER), OUTPUT, "output remains delivered");
        assertTrue(hook.flushCalled(), "failure-isolated flush returned successfully");
    }
}
