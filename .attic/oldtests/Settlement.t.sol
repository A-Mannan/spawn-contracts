// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {MilestoneColdPaths} from "../../src/MilestoneColdPaths.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {MilestoneHookHarness} from "../harness/MilestoneHookHarness.sol";

/// @notice Unit tests for task 3.7: native-ETH and ERC20 settlement against a real `PoolManager`.
///
/// Uses a genuine `PoolManager` rather than a mock, because the property under test — "no unsettled
/// delta" — is enforced by core's `CurrencyNotSettled` check and cannot be observed against a stub.
contract SettlementTest is Test {
    address internal constant HOOK_ADDR = address(uint160((uint160(0xBEEF) << 20) | 15040));
    address internal constant PROTOCOL_ADMIN = address(0xADD1);
    address internal constant PROTOCOL_RECIPIENT = address(0xFEE5);

    PoolManager internal manager;
    MilestoneHookHarness internal hook;
    RevenueNFT internal nft;
    LaunchSupport internal support;
    MilestoneToken internal token;

    Currency internal nativeCurrency = Currency.wrap(address(0));
    Currency internal tokenCurrency;
    MilestoneColdPaths internal coldPaths;

    function setUp() public {
        manager = new PoolManager(address(this));
        nft = new RevenueNFT();
        support = new LaunchSupport();

        coldPaths = new MilestoneColdPaths(IPoolManager(address(manager)), nft, support);

        deployCodeTo(
            "MilestoneHookHarness.sol:MilestoneHookHarness",
            abi.encode(IPoolManager(address(manager)), nft, support, coldPaths, PROTOCOL_ADMIN, PROTOCOL_RECIPIENT),
            HOOK_ADDR
        );
        hook = MilestoneHookHarness(payable(HOOK_ADDR));
        nft.setMinter(HOOK_ADDR);

        token = new MilestoneToken("Milestone", "MILE", 1_000_000 ether, HOOK_ADDR);
        tokenCurrency = Currency.wrap(address(token));
    }

    // --- Native ETH ---

    function test_nativeEthRoundTripLeavesNoUnsettledDelta() public {
        // The manager must hold the ETH being taken, and the hook must hold enough to settle it back.
        vm.deal(address(manager), 10 ether);
        vm.deal(HOOK_ADDR, 10 ether);

        uint256 managerBefore = address(manager).balance;
        uint256 hookBefore = HOOK_ADDR.balance;

        hook.settleTakeRoundTrip(nativeCurrency, 3 ether);

        // Net zero on both sides: the take and the settle cancel exactly.
        assertEq(address(manager).balance, managerBefore, "manager balance restored");
        assertEq(HOOK_ADDR.balance, hookBefore, "hook balance restored");
    }

    /// @dev The negative control: without the settle, core must reject the unlock. This is what makes
    /// the passing case above meaningful rather than vacuous.
    function test_unsettledNativeDeltaIsRejected() public {
        vm.deal(address(manager), 10 ether);
        vm.deal(HOOK_ADDR, 10 ether);

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        hook.takeWithoutSettling(nativeCurrency, 3 ether);
    }

    function testFuzz_nativeRoundTripAtAnyAmount(uint96 amount) public {
        amount = uint96(bound(amount, 1, 100 ether));

        vm.deal(address(manager), 200 ether);
        vm.deal(HOOK_ADDR, 200 ether);

        uint256 managerBefore = address(manager).balance;
        hook.settleTakeRoundTrip(nativeCurrency, amount);

        assertEq(address(manager).balance, managerBefore, "manager balance restored");
    }

    function test_zeroAmountIsANoOp() public {
        vm.deal(address(manager), 1 ether);
        uint256 managerBefore = address(manager).balance;

        hook.settleTakeRoundTrip(nativeCurrency, 0);

        assertEq(address(manager).balance, managerBefore, "nothing moved");
    }

    // --- ERC20, exercising the sync -> transfer -> settle sequence ---

    function test_erc20RoundTripLeavesNoUnsettledDelta() public {
        // Seed the manager so there is something to take.
        vm.prank(HOOK_ADDR);
        token.transfer(address(manager), 1_000 ether);

        uint256 managerBefore = token.balanceOf(address(manager));
        uint256 hookBefore = token.balanceOf(HOOK_ADDR);

        hook.settleTakeRoundTrip(tokenCurrency, 250 ether);

        assertEq(token.balanceOf(address(manager)), managerBefore, "manager token balance restored");
        assertEq(token.balanceOf(HOOK_ADDR), hookBefore, "hook token balance restored");
    }

    function test_unsettledErc20DeltaIsRejected() public {
        vm.prank(HOOK_ADDR);
        token.transfer(address(manager), 1_000 ether);

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        hook.takeWithoutSettling(tokenCurrency, 250 ether);
    }

    // --- Access control on the callback ---

    function test_unlockCallbackRejectsNonManager() public {
        vm.expectRevert(MilestoneBase.NotPoolManagerUnlock.selector);
        hook.unlockCallback("");
    }

    function test_unlockCallbackRejectsNonManagerEvenFromAdmin() public {
        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(MilestoneBase.NotPoolManagerUnlock.selector);
        hook.unlockCallback("");
    }

    /// @dev The production dispatch defines no actions yet, so an arbitrary payload must fail closed
    /// rather than being silently accepted.
    function test_productionDispatchFailsClosed() public {
        MilestoneHook plain;
        address plainAddr = address(uint160(HOOK_ADDR) + (uint160(1) << 20));
        deployCodeTo(
            "MilestoneHook.sol:MilestoneHook",
            abi.encode(IPoolManager(address(manager)), nft, support, coldPaths, PROTOCOL_ADMIN, PROTOCOL_RECIPIENT),
            plainAddr
        );
        plain = MilestoneHook(payable(plainAddr));

        // 199 sits below the harness range and above every production action, so it is genuinely
        // unrecognised rather than a malformed payload for a known action.
        vm.prank(address(manager));
        vm.expectRevert(MilestoneBase.UnknownUnlockAction.selector);
        plain.unlockCallback(abi.encode(uint8(199), uint256(1)));
    }

    // --- receive() ---

    function test_hookReceivesNativeEth() public {
        vm.deal(address(this), 5 ether);

        (bool ok,) = HOOK_ADDR.call{value: 5 ether}("");
        assertTrue(ok, "accepted");
        assertEq(HOOK_ADDR.balance, 5 ether, "credited");
    }
}
