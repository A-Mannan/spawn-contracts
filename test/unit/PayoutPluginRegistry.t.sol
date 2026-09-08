// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PAYOUT_WAD, PluginEntry, PluginRole} from "../../src/types/PayoutTypes.sol";
import {PayoutPluginRegistry} from "../../src/PayoutPluginRegistry.sol";

contract DirectPlugin {
    receive() external payable {}
}

contract MutablePlugin {
    receive() external payable {}
}

contract DelegateProxyLike {
    fallback() external payable {
        assembly ("memory-safe") {
            pop(delegatecall(gas(), caller(), 0, 0, 0, 0))
        }
    }
}

contract CallcodeProxyLike {
    fallback() external payable {
        assembly ("memory-safe") {
            pop(callcode(gas(), caller(), 0, 0, 0, 0, 0))
        }
    }
}

contract PushDataDelegateOpcode {
    fallback() external payable {
        assembly ("memory-safe") {
            mstore(0, 0x60f4000000000000000000000000000000000000000000000000000000000000)
            return(0, 2)
        }
    }
}

contract PayoutPluginRegistryTest is Test {
    PayoutPluginRegistry internal registry;

    address internal constant ADMINISTRATOR = address(0xA11CE);
    address internal constant STRANGER = address(0xB0B);
    uint32 internal constant GAS_LIMIT = 100_000;

    function setUp() public {
        registry = new PayoutPluginRegistry(ADMINISTRATOR);
    }

    // --- Scenario: Registration appends at a stable index ---

    function test_registrationAppendsAtAStableIndex() public {
        DirectPlugin first = new DirectPlugin();
        DirectPlugin second = new DirectPlugin();

        uint8 firstIndex = _register(address(first), 0.2e18, PluginRole.PAYOUT);
        bytes32 firstBefore = keccak256(abi.encode(registry.entry(firstIndex)));
        uint8 secondIndex = _register(address(second), 0.3e18, PluginRole.PAYOUT);

        assertEq(firstIndex, 0, "first index");
        assertEq(secondIndex, 1, "second index");
        assertEq(registry.entryCount(), 2, "uint16 count advances");
        assertEq(keccak256(abi.encode(registry.entry(firstIndex))), firstBefore, "earlier entry unchanged");
        assertEq(registry.indexPlusOne(address(first)), 1, "first reverse index");
        assertEq(registry.indexPlusOne(address(second)), 2, "second reverse index");
    }

    // --- Scenario: Registered terms cannot change ---

    function test_registeredTermsCannotChange() public {
        DirectPlugin plugin = new DirectPlugin();
        uint8 index = _register(address(plugin), 0.4e18, PluginRole.PAYOUT);
        PluginEntry memory before_ = registry.entry(index);

        vm.prank(ADMINISTRATOR);
        registry.setPluginSuspended(index, true);
        PluginEntry memory after_ = registry.entry(index);

        assertEq(after_.plugin, before_.plugin, "plugin immutable");
        assertEq(after_.takeWad, before_.takeWad, "take immutable");
        assertEq(after_.gasLimit, before_.gasLimit, "gas immutable");
        assertEq(after_.codeHash, before_.codeHash, "hash immutable");
        assertEq(uint8(after_.role), uint8(before_.role), "role immutable");
        assertTrue(after_.suspended, "only suspension changed");
    }

    // --- Scenario: Registry is bounded to one word ---

    function test_registryIsBoundedToOneWord() public {
        uint64 nonce = vm.getNonce(address(this));
        for (uint256 i; i < 256; ++i) {
            address predicted = vm.computeCreateAddress(address(this), nonce + i);
            DirectPlugin plugin = new DirectPlugin();
            assertEq(address(plugin), predicted, "prediction matches deployment");
            vm.prank(ADMINISTRATOR);
            assertEq(
                registry.registerPlugin(address(plugin), 0, GAS_LIMIT, PluginRole.PAYOUT), uint8(i), "stable byte index"
            );
        }

        DirectPlugin overflowPlugin = new DirectPlugin();
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(PayoutPluginRegistry.RegistryFull.selector);
        registry.registerPlugin(address(overflowPlugin), 0, GAS_LIMIT, PluginRole.PAYOUT);
        assertEq(registry.entryCount(), 256, "count represents all byte indices");
        assertEq(registry.indexPlusOne(registry.entry(255).plugin), 256, "uint16 reverse index represents bit 255");
    }

    // --- Scenario: Unauthorized registry mutation is rejected ---

    function test_unauthorizedRegistryMutationIsRejected() public {
        DirectPlugin plugin = new DirectPlugin();
        vm.prank(STRANGER);
        vm.expectRevert(PayoutPluginRegistry.NotAdministrator.selector);
        registry.registerPlugin(address(plugin), 0.1e18, GAS_LIMIT, PluginRole.PAYOUT);

        uint8 index = _register(address(plugin), 0.1e18, PluginRole.PAYOUT);
        vm.prank(STRANGER);
        vm.expectRevert(PayoutPluginRegistry.NotAdministrator.selector);
        registry.setPluginSuspended(index, true);
    }

    function test_registryAdministratorTransferRequiresAcceptance() public {
        vm.prank(ADMINISTRATOR);
        registry.proposeAdministrator(STRANGER);
        assertEq(registry.administrator(), ADMINISTRATOR);
        assertEq(registry.pendingAdministrator(), STRANGER);

        vm.prank(STRANGER);
        registry.acceptAdministrator();
        assertEq(registry.administrator(), STRANGER);
        assertEq(registry.pendingAdministrator(), address(0));
    }

    // --- Scenario: Suspension preserves identity ---

    function test_suspensionPreservesIdentity() public {
        DirectPlugin plugin = new DirectPlugin();
        uint8 index = _register(address(plugin), 0.25e18, PluginRole.PAYOUT);
        bytes32 original = keccak256(abi.encode(registry.entry(index)));

        vm.prank(ADMINISTRATOR);
        registry.setPluginSuspended(index, true);
        assertFalse(registry.isSelectable(index), "suspension blocks selection");

        vm.prank(ADMINISTRATOR);
        registry.setPluginSuspended(index, false);
        assertTrue(registry.isSelectable(index), "reactivation restores selection");
        assertEq(keccak256(abi.encode(registry.entry(index))), original, "identity and terms restored exactly");
    }

    // --- Registration validation: derived, no scenario of its own ---

    function test_registrationRejectsDuplicateCodelessUnsafeAndInvalidValues() public {
        DirectPlugin plugin = new DirectPlugin();
        _register(address(plugin), 0.1e18, PluginRole.PAYOUT);

        vm.prank(ADMINISTRATOR);
        vm.expectRevert(abi.encodeWithSelector(PayoutPluginRegistry.DuplicatePlugin.selector, address(plugin), 0));
        registry.registerPlugin(address(plugin), 0.1e18, GAS_LIMIT, PluginRole.PAYOUT);

        vm.prank(ADMINISTRATOR);
        vm.expectRevert(PayoutPluginRegistry.PluginHasNoCode.selector);
        registry.registerPlugin(address(0x1234), 0.1e18, GAS_LIMIT, PluginRole.PAYOUT);

        DirectPlugin noRole = new DirectPlugin();
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(PayoutPluginRegistry.InvalidRole.selector);
        registry.registerPlugin(address(noRole), 0, GAS_LIMIT, PluginRole.INVALID);

        DirectPlugin excessTake = new DirectPlugin();
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(PayoutPluginRegistry.InvalidTake.selector);
        registry.registerPlugin(address(excessTake), uint64(PAYOUT_WAD + 1), GAS_LIMIT, PluginRole.PAYOUT);

        DirectPlugin utilityTake = new DirectPlugin();
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(PayoutPluginRegistry.InvalidTake.selector);
        registry.registerPlugin(address(utilityTake), 1, GAS_LIMIT, PluginRole.UTILITY);

        DirectPlugin lowGas = new DirectPlugin();
        uint32 minGasLimit = registry.MIN_PLUGIN_GAS_LIMIT();
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(PayoutPluginRegistry.UnsafeGasLimit.selector);
        registry.registerPlugin(address(lowGas), 0, minGasLimit - 1, PluginRole.PAYOUT);

        DirectPlugin highGas = new DirectPlugin();
        uint32 maxGasLimit = registry.MAX_PLUGIN_GAS_LIMIT();
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(PayoutPluginRegistry.UnsafeGasLimit.selector);
        registry.registerPlugin(address(highGas), 0, maxGasLimit + 1, PluginRole.PAYOUT);

        DelegateProxyLike proxyLike = new DelegateProxyLike();
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(PayoutPluginRegistry.ProxyLikePlugin.selector);
        registry.registerPlugin(address(proxyLike), 0, GAS_LIMIT, PluginRole.PAYOUT);

        CallcodeProxyLike callcodeLike = new CallcodeProxyLike();
        vm.prank(ADMINISTRATOR);
        vm.expectRevert(PayoutPluginRegistry.ProxyLikePlugin.selector);
        registry.registerPlugin(address(callcodeLike), 0, GAS_LIMIT, PluginRole.PAYOUT);

        PushDataDelegateOpcode pushData = new PushDataDelegateOpcode();
        _register(address(pushData), 0, PluginRole.PAYOUT);
    }

    function test_nonPayoutRolesExistButAreNotSelectable() public {
        DirectPlugin creatorSystem = new DirectPlugin();
        DirectPlugin utility = new DirectPlugin();
        uint8 creatorIndex = _register(address(creatorSystem), 0, PluginRole.CREATOR_SYSTEM);
        uint8 utilityIndex = _register(address(utility), 0, PluginRole.UTILITY);

        assertFalse(registry.isSelectable(creatorIndex), "creator system is not a payout bit");
        assertFalse(registry.isSelectable(utilityIndex), "utility is not a payout bit");
        assertFalse(registry.isSelectable(2), "unregistered index is not selectable");
    }

    function test_runtimeCodeHashValidityControlsSelection() public {
        MutablePlugin plugin = new MutablePlugin();
        uint8 index = _register(address(plugin), 0.1e18, PluginRole.PAYOUT);
        assertTrue(registry.isSelectable(index), "matching runtime is selectable");
        assertEq(registry.resolveSelectable(index).plugin, address(plugin));

        vm.etch(address(plugin), hex"00");
        assertFalse(registry.isSelectable(index), "changed runtime is rejected");
        vm.expectRevert(PayoutPluginRegistry.EntryNotSelectable.selector);
        registry.resolveSelectable(index);
    }

    function test_unknownEntryReadAndSuspensionRevert() public {
        vm.expectRevert(PayoutPluginRegistry.EntryDoesNotExist.selector);
        registry.entry(0);

        vm.prank(ADMINISTRATOR);
        vm.expectRevert(PayoutPluginRegistry.EntryDoesNotExist.selector);
        registry.setPluginSuspended(0, true);
    }

    function _register(address plugin, uint64 takeWad, PluginRole role) private returns (uint8 index) {
        vm.prank(ADMINISTRATOR);
        index = registry.registerPlugin(plugin, takeWad, GAS_LIMIT, role);
    }
}
