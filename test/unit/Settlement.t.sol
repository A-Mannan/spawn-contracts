// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {HarnessLaunchpadTest} from "../HarnessFixtures.sol";

/// @notice Unit tests for task 3.7: native-ETH and ERC20 settlement against a real `PoolManager`.
///
/// Uses a genuine `PoolManager` rather than a mock, because the property under test — "no unsettled
/// delta" — is enforced by core's `CurrencyNotSettled` check and cannot be observed against a stub.
contract SettlementTest is HarnessLaunchpadTest {
    Currency internal nativeCurrency;
    Currency internal tokenCurrency;

    function setUp() public override {
        super.setUp();
        nativeCurrency = key.currency0;
        tokenCurrency = key.currency1;
    }

    // --- Native ETH ---

    function test_nativeEthRoundTripLeavesNoUnsettledDelta() public {
        // The manager must hold the ETH being taken, and the hook must hold enough to settle it back.
        _fundBoth(10 ether);

        uint256 managerBefore = address(manager).balance;
        uint256 hookBefore = HOOK_ADDR.balance;

        harness.settleTakeRoundTrip(nativeCurrency, 3 ether);

        // Net zero on both sides: the take and the settle cancel exactly.
        assertEq(address(manager).balance, managerBefore, "manager balance restored");
        assertEq(HOOK_ADDR.balance, hookBefore, "hook balance restored");
    }

    /// @dev The negative control: without the settle, core must reject the unlock. This is what makes
    /// the passing case above meaningful rather than vacuous.
    function test_unsettledNativeDeltaIsRejected() public {
        _fundBoth(10 ether);

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        harness.takeWithoutSettling(nativeCurrency, 3 ether);
    }

    function testFuzz_nativeRoundTripAtAnyAmount(uint96 amount) public {
        amount = uint96(bound(amount, 1, 100 ether));

        _fundBoth(200 ether);

        uint256 managerBefore = address(manager).balance;
        harness.settleTakeRoundTrip(nativeCurrency, amount);

        assertEq(address(manager).balance, managerBefore, "manager balance restored");
    }

    function test_zeroAmountIsANoOp() public {
        _fundBoth(1 ether);
        uint256 managerBefore = address(manager).balance;

        harness.settleTakeRoundTrip(nativeCurrency, 0);

        assertEq(address(manager).balance, managerBefore, "nothing moved");
    }

    // --- ERC20, exercising the sync -> transfer -> settle sequence ---

    function test_erc20RoundTripLeavesNoUnsettledDelta() public {
        // Seed the manager so there is something to take.
        vm.prank(HOOK_ADDR);
        token.transfer(address(manager), 1_000 ether);

        uint256 managerBefore = token.balanceOf(address(manager));
        uint256 hookBefore = token.balanceOf(HOOK_ADDR);

        harness.settleTakeRoundTrip(tokenCurrency, 250 ether);

        assertEq(token.balanceOf(address(manager)), managerBefore, "manager token balance restored");
        assertEq(token.balanceOf(HOOK_ADDR), hookBefore, "hook token balance restored");
    }

    function test_unsettledErc20DeltaIsRejected() public {
        vm.prank(HOOK_ADDR);
        token.transfer(address(manager), 1_000 ether);

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        harness.takeWithoutSettling(tokenCurrency, 250 ether);
    }

    // --- Access control on the callback ---

    function test_unlockCallbackRejectsNonManager() public {
        vm.expectRevert(MilestoneBase.NotPoolManagerUnlock.selector);
        harness.unlockCallback("");
    }

    function test_unlockCallbackRejectsNonManagerEvenFromAdmin() public {
        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(MilestoneBase.NotPoolManagerUnlock.selector);
        harness.unlockCallback("");
    }

    /// @dev The production dispatch must fail closed on an unrecognised action rather than silently
    /// accepting it. Deployed as a *second*, plain hook: the suite's own hook is the harness, whose
    /// `_dispatchUnlock` override is exactly the code that must not be in the way of this assertion.
    /// Adding `1 << 20` leaves the low-order permission flags untouched, so the address is still valid.
    function test_productionDispatchFailsClosed() public {
        address plainAddr = address(uint160(HOOK_ADDR) + (uint160(1) << 20));
        deployCodeTo(
            "MilestoneHook.sol:MilestoneHook",
            abi.encode(
                IPoolManager(address(manager)),
                nft,
                support,
                template,
                address(coldPaths),
                PROTOCOL_ADMIN,
                PROTOCOL_RECIPIENT
            ),
            plainAddr
        );
        MilestoneHook plain = MilestoneHook(payable(plainAddr));

        // 199 sits below the harness range and above every production action, so it is genuinely
        // unrecognised rather than a malformed payload for a known action.
        vm.prank(address(manager));
        vm.expectRevert(MilestoneBase.UnknownUnlockAction.selector);
        plain.unlockCallback(abi.encode(uint8(199), uint256(1)));
    }

    // --- receive() ---

    function test_hookReceivesNativeEth() public {
        uint256 before = HOOK_ADDR.balance;
        vm.deal(address(this), 5 ether);

        (bool ok,) = HOOK_ADDR.call{value: 5 ether}("");
        assertTrue(ok, "accepted");
        assertEq(HOOK_ADDR.balance - before, 5 ether, "credited");
    }

    /// @dev Tops both sides up rather than overwriting, so a launch that left ETH anywhere is preserved.
    /// The two reads are hoisted because `via_ir` would otherwise be free to share one balance load
    /// across both `vm.deal` calls.
    function _fundBoth(uint256 amount) private {
        uint256 managerBalance = address(manager).balance;
        uint256 hookBalance = HOOK_ADDR.balance;
        vm.deal(address(manager), managerBalance + amount);
        vm.deal(HOOK_ADDR, hookBalance + amount);
    }
}
