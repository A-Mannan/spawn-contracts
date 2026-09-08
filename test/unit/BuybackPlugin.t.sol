// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BuybackAndBurnPlugin} from "../../src/BuybackAndBurnPlugin.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {MockPayoutHook, MockPoolManager} from "../mocks/PayoutReferenceMocks.sol";

contract RevertingBurnToken is ERC20 {
    error BurnFailed();

    constructor(uint256 supply) ERC20("Reverting", "RVT") {
        _mint(msg.sender, supply);
    }

    function burn(uint256) external pure {
        revert BurnFailed();
    }
}

contract BuybackPluginTest is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager internal manager;
    MockPayoutHook internal hook;
    BuybackAndBurnPlugin internal plugin;
    MilestoneToken internal token;
    PoolKey internal key;
    PoolId internal poolId;

    uint256 internal constant PAYOUT = 2 ether;
    uint256 internal constant TOKENS_OUT = 500 ether;
    uint256 internal constant PREFUND = 7 ether;

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

        plugin = new BuybackAndBurnPlugin(IPoolManager(address(manager)), address(hook), TickMath.MIN_SQRT_PRICE + 1);
        token.transfer(address(manager), 10_000 ether);
        vm.deal(address(hook), 100 ether);
        vm.deal(address(plugin), PREFUND);
    }

    // --- Scenario: Buyback spends only delivered ETH ---

    function test_buybackSpendsOnlyDeliveredEth() public {
        manager.configureSwap(PAYOUT, TOKENS_OUT, key.currency1);
        uint256 prefundBefore = address(plugin).balance;

        (bool success,) = hook.payPlugin{value: PAYOUT}(address(plugin), poolId, address(token));

        assertTrue(success, "payout accepted");
        assertEq(manager.settleCount(), 1, "one settlement");
        assertEq(address(plugin).balance, prefundBefore, "prefunded ETH untouched");
    }

    function test_rejectsUnauthenticatedPayout() public {
        vm.expectRevert(abi.encodeWithSelector(BuybackAndBurnPlugin.UnauthorizedHook.selector, address(this)));
        plugin.onPayout{value: PAYOUT}(poolId, address(token));
    }

    // --- Scenario: Buyback burns acquired tokens ---

    function test_buybackBurnsAcquiredTokens() public {
        manager.configureSwap(PAYOUT, TOKENS_OUT, key.currency1);
        uint256 supplyBefore = token.totalSupply();

        (bool success,) = hook.payPlugin{value: PAYOUT}(address(plugin), poolId, address(token));

        assertTrue(success, "buyback succeeds");
        assertEq(token.totalSupply(), supplyBefore - TOKENS_OUT, "every output token burned");
        assertEq(token.balanceOf(address(plugin)), 0, "plugin retains no launch token");
    }

    // --- Scenario: Failed buyback carries the entire share ---

    function test_failedBoundedBuybackRevertsAtomically() public {
        manager.configureSwap(PAYOUT - 1, TOKENS_OUT, key.currency1);
        uint256 hookBefore = address(hook).balance;
        uint256 managerTokensBefore = token.balanceOf(address(manager));
        uint256 supplyBefore = token.totalSupply();

        (bool success,) = hook.payPlugin{value: PAYOUT}(address(plugin), poolId, address(token));

        assertFalse(success, "partial fill rejected");
        assertEq(address(hook).balance, hookBefore + PAYOUT, "hook retains complete attempted allocation");
        assertEq(token.balanceOf(address(manager)), managerTokensBefore, "manager state rolled back");
        assertEq(token.totalSupply(), supplyBefore, "burn rolled back");
    }

    function test_burnFailureRevertsAtomicPurchase() public {
        RevertingBurnToken revertingToken = new RevertingBurnToken(20_000 ether);
        PoolKey memory revertingKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(revertingToken)),
            fee: 10_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId revertingPoolId = revertingKey.toId();
        hook.setSource(revertingPoolId, revertingKey, address(revertingToken));
        revertingToken.transfer(address(manager), 10_000 ether);
        manager.configureSwap(PAYOUT, TOKENS_OUT, revertingKey.currency1);
        uint256 hookBefore = address(hook).balance;
        uint256 managerTokensBefore = revertingToken.balanceOf(address(manager));
        uint256 supplyBefore = revertingToken.totalSupply();

        (bool success,) = hook.payPlugin{value: PAYOUT}(address(plugin), revertingPoolId, address(revertingToken));

        assertFalse(success, "burn revert propagated");
        assertEq(address(hook).balance, hookBefore + PAYOUT, "whole share remains at hook");
        assertEq(revertingToken.balanceOf(address(manager)), managerTokensBefore, "purchase rolled back");
        assertEq(revertingToken.totalSupply(), supplyBefore, "supply remains unchanged");
    }

    // --- Scenario: Zero delivery performs no swap ---

    function test_zeroDeliveryPerformsNoSwap() public {
        (bool success,) = hook.payPlugin(address(plugin), poolId, address(token));

        assertTrue(success, "zero payout is harmless");
        assertEq(manager.unlockCount(), 0, "no unlock");
        assertEq(manager.swapCount(), 0, "no swap");
    }
}
