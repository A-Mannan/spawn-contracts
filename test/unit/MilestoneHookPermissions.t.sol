// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneColdPaths} from "../../src/MilestoneColdPaths.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {LaunchConfig, Phase} from "../../src/types/LaunchTypes.sol";
import {LaunchpadTest} from "../Fixtures.sol";

/// @notice Unit tests for task 3.1: the hook shell's permission declaration and per-pool state.
///
/// The permission assertion is not cosmetic. `BaseHook`'s constructor runs
/// `Hooks.validateHookPermissions` against the deployed address, so a hook whose declared flags
/// disagree with its address cannot be constructed at all. Successfully deploying to a
/// correctly-flagged address is therefore itself proof that the declaration and the mined address
/// agree — and {test_wrongAddressIsNotConstructible} proves the check has teeth.
contract MilestoneHookPermissionsTest is LaunchpadTest {
    uint160 internal constant EXPECTED_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG;

    /// @dev The constructor arguments the fixture deployed {HOOK_ADDR} with. Re-encoded rather than
    /// remembered, so the negative constructor tests below vary exactly one field from the real ones.
    function _ctorArgs() internal view returns (bytes memory) {
        return abi.encode(
            IPoolManager(address(manager)),
            nft,
            support,
            template,
            address(coldPaths),
            PROTOCOL_ADMIN,
            PROTOCOL_RECIPIENT
        );
    }

    function _assertNotCallable(string memory signature) internal {
        (bool ok,) = address(hook).call(abi.encodeWithSignature(signature));
        assertFalse(ok, signature);
    }

    // --- Scenario (token-launch): Deployed hook address carries the required flags ---

    function test_declaredPermissionsMatchTheSpec() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        assertTrue(p.beforeInitialize, "beforeInitialize");
        assertTrue(p.afterInitialize, "afterInitialize");
        assertTrue(p.beforeAddLiquidity, "beforeAddLiquidity");
        assertTrue(p.beforeRemoveLiquidity, "beforeRemoveLiquidity");
        assertTrue(p.beforeSwap, "beforeSwap");
        assertTrue(p.afterSwap, "afterSwap");
    }

    function test_noOtherPermissionsAreDeclared() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        assertFalse(p.afterAddLiquidity, "afterAddLiquidity");
        assertFalse(p.afterRemoveLiquidity, "afterRemoveLiquidity");
        assertFalse(p.beforeDonate, "beforeDonate");
        assertFalse(p.afterDonate, "afterDonate");
        assertFalse(p.beforeSwapReturnDelta, "beforeSwapReturnDelta");
        assertFalse(p.afterSwapReturnDelta, "afterSwapReturnDelta");
        assertFalse(p.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta");
        assertFalse(p.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta");
    }

    /// @dev v4's own validator agrees the address encodes exactly the declared flags.
    function test_addressEncodesExactlyTheDeclaredFlags() public view {
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());

        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, EXPECTED_FLAGS, "address flags");
        assertEq(uint256(EXPECTED_FLAGS), 15040, "expected mask");
    }

    /// @dev Drop one required flag from the address and construction must fail. Done with a raw
    /// etch-and-call rather than `deployCodeTo`, whose internal `require` would swallow the revert.
    function test_wrongAddressIsNotConstructible() public {
        address badAddr = address(uint160(HOOK_ADDR) ^ uint160(Hooks.AFTER_SWAP_FLAG));

        bytes memory creationCode = abi.encodePacked(vm.getCode("MilestoneHook.sol:MilestoneHook"), _ctorArgs());
        vm.etch(badAddr, creationCode);

        (bool ok,) = badAddr.call("");
        assertFalse(ok, "a wrongly-flagged address must not be constructible");
    }

    /// @dev The dynamic fee cannot be a hook-address flag: it is bit 23, while the hook mask covers
    /// only the low 14 bits. It lives in `PoolKey.fee` instead.
    function test_dynamicFeeIsNotAHookAddressFlag() public pure {
        assertEq(uint160(LPFeeLibrary.DYNAMIC_FEE_FLAG) & Hooks.ALL_HOOK_MASK, 0, "outside the hook mask");
        assertEq(uint256(Hooks.ALL_HOOK_MASK), (1 << 14) - 1, "hook mask is 14 bits");
    }

    // --- Construction wiring ---

    function test_constructorWiring() public view {
        assertEq(address(hook.poolManager()), address(manager), "pool manager");
        assertEq(address(hook.revenueNFT()), address(nft), "revenue NFT");
        assertEq(hook.coldPaths(), address(coldPaths), "cold paths");
        assertEq(hook.protocolAdmin(), PROTOCOL_ADMIN, "protocol admin");
        assertEq(hook.protocolRecipient(), PROTOCOL_RECIPIENT, "protocol recipient");
    }

    /// @dev Another correctly-flagged address: flipping a high bit leaves the low 14 bits intact.
    function _anotherFlaggedAddress() internal pure returns (address) {
        return address(uint160(HOOK_ADDR) + (uint160(1) << 20));
    }

    /// @dev Deploys with the given constructor args at a correctly-flagged address and returns the
    /// revert data. `BaseHook`'s constructor validates the address *before* the derived constructor
    /// body runs, so the zero-address guards are only reachable from a valid address.
    function _tryConstruct(bytes memory args) internal returns (bool ok, bytes memory ret) {
        address target = _anotherFlaggedAddress();
        vm.etch(target, abi.encodePacked(vm.getCode("MilestoneHook.sol:MilestoneHook"), args));
        (ok, ret) = target.call("");
    }

    function _assertRevertedWith(bytes memory ret, bytes4 expected) internal pure {
        assertGe(ret.length, 4, "revert data present");
        bytes4 got = bytes4(ret[0]) | (bytes4(ret[1]) >> 8) | (bytes4(ret[2]) >> 16) | (bytes4(ret[3]) >> 24);
        assertEq(got, expected, "revert selector");
    }

    function test_constructorRejectsZeroRevenueNft() public {
        (bool ok, bytes memory ret) = _tryConstruct(
            abi.encode(
                IPoolManager(address(manager)),
                RevenueNFT(address(0)),
                support,
                template,
                address(coldPaths),
                PROTOCOL_ADMIN,
                PROTOCOL_RECIPIENT
            )
        );

        assertFalse(ok, "must not construct");
        _assertRevertedWith(ret, MilestoneBase.ZeroAddress.selector);
    }

    function test_constructorRejectsZeroLaunchSupport() public {
        (bool ok, bytes memory ret) = _tryConstruct(
            abi.encode(
                IPoolManager(address(manager)),
                nft,
                LaunchSupport(address(0)),
                template,
                address(coldPaths),
                PROTOCOL_ADMIN,
                PROTOCOL_RECIPIENT
            )
        );

        assertFalse(ok, "must not construct");
        _assertRevertedWith(ret, MilestoneBase.ZeroAddress.selector);
    }

    function test_constructorRejectsZeroAdmin() public {
        (bool ok, bytes memory ret) = _tryConstruct(
            abi.encode(
                IPoolManager(address(manager)),
                nft,
                support,
                template,
                address(coldPaths),
                address(0),
                PROTOCOL_RECIPIENT
            )
        );

        assertFalse(ok, "must not construct");
        _assertRevertedWith(ret, MilestoneBase.ZeroAddress.selector);
    }

    function test_constructorRejectsZeroRecipient() public {
        (bool ok, bytes memory ret) = _tryConstruct(
            abi.encode(
                IPoolManager(address(manager)), nft, support, template, address(coldPaths), PROTOCOL_ADMIN, address(0)
            )
        );

        assertFalse(ok, "must not construct");
        _assertRevertedWith(ret, MilestoneBase.ZeroAddress.selector);
    }

    /// @dev A cold-paths target with no code fails the {MilestoneBase.NotAContract} guard, so the split
    /// cannot be deployed with a mistyped or unset satellite address that would silently no-op launches.
    function test_constructorRejectsCodelessColdPaths() public {
        (bool ok, bytes memory ret) = _tryConstruct(
            abi.encode(
                IPoolManager(address(manager)),
                nft,
                support,
                template,
                address(0xC0DE),
                PROTOCOL_ADMIN,
                PROTOCOL_RECIPIENT
            )
        );

        assertFalse(ok, "must not construct");
        _assertRevertedWith(ret, MilestoneBase.NotAContract.selector);
    }

    /// @dev Sanity check that the alternate address really is valid, so the tests above fail for the
    /// reason they claim rather than on the flag check.
    function test_alternateFlaggedAddressIsValid() public {
        (bool ok,) = _tryConstruct(_ctorArgs());
        assertTrue(ok, "valid args at a flagged address construct fine");
    }

    // --- Per-pool state is keyed and isolated ---

    function test_unknownPoolIsPhaseNone() public view {
        PoolId unknown = PoolId.wrap(bytes32(uint256(0xDEAD)));

        assertEq(uint8(hook.poolPhase(unknown)), uint8(Phase.NONE), "unknown pool has no phase");
        assertEq(hook.creatorClaimable(unknown), 0, "no creator balance");
        assertEq(hook.protocolClaimable(unknown), 0, "no protocol balance");
        assertFalse(hook.curvePositionDeployed(unknown, 0), "no curve positions");
        assertFalse(hook.bandDeployed(unknown, 0), "no bands deployed");
    }

    /// @dev The fixture's own launch is excluded, so the fuzzer cannot pick the one pool that does have
    /// state and turn a real isolation failure into an expected one.
    function testFuzz_distinctPoolsReadIndependently(bytes32 rawA, bytes32 rawB) public view {
        vm.assume(rawA != rawB);
        vm.assume(rawA != PoolId.unwrap(poolId) && rawB != PoolId.unwrap(poolId));

        assertEq(uint8(hook.poolPhase(PoolId.wrap(rawA))), uint8(Phase.NONE), "pool A");
        assertEq(uint8(hook.poolPhase(PoolId.wrap(rawB))), uint8(Phase.NONE), "pool B");
        assertEq(hook.creatorClaimable(PoolId.wrap(rawA)), 0, "pool A creator");
        assertEq(hook.creatorClaimable(PoolId.wrap(rawB)), 0, "pool B creator");
    }

    // --- Protocol administration is the whole privileged surface ---

    function test_adminCanSetProtocolRecipient() public {
        address next = address(0xFEED);

        vm.prank(PROTOCOL_ADMIN);
        hook.setProtocolRecipient(next);

        assertEq(hook.protocolRecipient(), next, "recipient updated");
    }

    function test_nonAdminCannotSetProtocolRecipient() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MilestoneBase.NotProtocolAdmin.selector);
        hook.setProtocolRecipient(address(0xBAD));

        assertEq(hook.protocolRecipient(), PROTOCOL_RECIPIENT, "unchanged");
    }

    function test_protocolRecipientCannotBeZeroed() public {
        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(MilestoneBase.ZeroAddress.selector);
        hook.setProtocolRecipient(address(0));
    }

    /// @dev No privileged function exists beyond the recipient setter: no pause, no config override,
    /// no withdrawal, no upgrade (design Decision 10).
    function test_noOtherPrivilegedFunctionsExist() public {
        _assertNotCallable("pause()");
        _assertNotCallable("unpause()");
        _assertNotCallable("withdraw(address,uint256)");
        _assertNotCallable("sweep(address)");
        _assertNotCallable("setBaseFee(bytes32,uint24)");
        _assertNotCallable("upgradeTo(address)");
        _assertNotCallable("transferOwnership(address)");
    }

    // --- The cold paths are reachable only as the hook ---
    //
    // {MilestoneColdPaths} runs by DELEGATECALL, so every one of its entry points is `onlyDelegated`. The
    // positive direction — that the guard does not block the delegated path — is covered by every launch
    // and graduation test in the suite, all of which reach these same functions through the hook. What is
    // asserted here is the negative direction, once per entry point.
    //
    // Each call passes a default-initialised argument, so a revert with {NotDelegated} rather than a
    // validation error also shows the guard fires *before* the function does any work.

    function test_coldPathsRejectDirectLaunch() public {
        LaunchConfig memory config;

        vm.expectRevert(MilestoneColdPaths.NotDelegated.selector);
        coldPaths.launch(config, "");
    }

    function test_coldPathsRejectDirectGraduate() public {
        PoolKey memory emptyKey;

        vm.expectRevert(MilestoneColdPaths.NotDelegated.selector);
        coldPaths.graduate(emptyKey);
    }

    function test_coldPathsRejectDirectGraduateWhileUnlocked() public {
        PoolKey memory emptyKey;

        vm.expectRevert(MilestoneColdPaths.NotDelegated.selector);
        coldPaths.graduateWhileUnlocked(emptyKey);
    }

    function test_coldPathsRejectDirectCollectFees() public {
        PoolKey memory emptyKey;

        vm.expectRevert(MilestoneColdPaths.NotDelegated.selector);
        coldPaths.collectFees(emptyKey);
    }

    function test_coldPathsRejectDirectUnlockDispatch() public {
        vm.expectRevert(MilestoneColdPaths.NotDelegated.selector);
        coldPaths.dispatchUnlock(abi.encode(uint8(0), uint256(0)));
    }

    // --- Unimplemented callbacks fail closed ---

    /// @dev Callbacks not yet implemented inherit BaseHook's revert, so no path is silently permissive
    /// while the build is in progress.
    function test_unimplementedCallbacksRevert() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 0, 0, "");
    }

    /// @dev Callbacks are only reachable from the pool manager.
    function test_callbacksRejectNonManagerCallers() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hook.beforeInitialize(address(0xBAD), key, 0);
    }

    // --- Native ETH custody ---

    function test_hookAcceptsNativeEth() public {
        uint256 before = address(hook).balance;
        vm.deal(address(this), 1 ether);

        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertTrue(ok, "hook accepts ETH");
        assertEq(address(hook).balance - before, 1 ether, "balance credited");
    }
}
