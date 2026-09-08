// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {Bounds, LaunchConfig} from "../../src/types/LaunchTypes.sol";
import {LaunchpadTest} from "../Fixtures.sol";

/// @notice Unit tests for tasks 5.3 and 5.4 — the optional dev buy and its hook-held linear vesting.
///
/// @dev Every test launches its own pool, because a dev buy exists only at genesis: it is the one
/// operation with no post-launch entry point, so the fixture's dev-buy-free launch cannot be adapted
/// into one. Each launch therefore needs a distinct name and symbol. That is not cosmetic — the CREATE2
/// salt is derived from the configuration hash and the recovered signer (Decision 19), and the hash
/// excludes the deadline, so two launches differing only in their deadline resolve to one token address
/// and the second reverts on the collision. {_config}'s counter is what keeps them apart.
contract DevBuyTest is LaunchpadTest {
    /// @dev Distinguishes each launch's configuration, and so its CREATE2 address.
    uint256 private nonce;

    function _config(uint64 devBuyShareWad, uint32 vestingSeconds) internal returns (LaunchConfig memory config) {
        nonce += 1;
        config = Bounds.defaultConfig(creator, string.concat("Milestone ", vm.toString(nonce)), "MILE", SUPPLY);
        config.devBuyShareWad = devBuyShareWad;
        config.devBuyVestingSeconds = vestingSeconds;
    }

    /// @notice The creator's own launch, carrying `value` as the dev buy's ETH budget.
    ///
    /// @dev Deliberately not the fixture's `_launchDirectWithValue`, which deals `value` to the creator
    /// first so a suite need not think about funding. Here the ETH accounting *is* the assertion, and a
    /// top-up of exactly the amount about to be spent would hide it. The creator pays out of the
    /// 100_000 ether the fixture dealt in `setUp`.
    function _launch(uint64 devBuyShareWad, uint32 vestingSeconds, uint256 value)
        internal
        returns (PoolId id, MilestoneToken t)
    {
        vm.prank(creator);
        (PoolId poolId_, address tokenAddr,) = hook.launch{value: value}(_config(devBuyShareWad, vestingSeconds), "");
        return (poolId_, MilestoneToken(tokenAddr));
    }

    /// @notice Token the bonding curve settled into the manager across every deployment in `logs`.
    ///
    /// @dev The curve is deployed just in time (Decision 17): genesis mints position 0 alone, and the dev
    /// buy's own `_deployCurveAhead` mints the rest of what its price path will cross. So the manager's
    /// token balance after a dev-buy launch is *higher* than after one without, and comparing the two
    /// balances directly measures the deployment depth rather than the dev buy. Summing what the curve
    /// settled is what makes the pool's balance predictable.
    function _curveTokenSettled(Vm.Log[] memory logs) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.CurvePositionsDeployed.selector) continue;
            (,, uint256 tokenSettled) = abi.decode(logs[i].data, (uint256, uint32, uint256));
            total += tokenSettled;
        }
    }

    function _pooledToken(PoolId id) internal view returns (uint256) {
        return MilestoneToken(hook.poolState(id).token).balanceOf(address(manager));
    }

    // --- Scenario: No dev buy is the default ---

    function test_noDevBuyByDefault() public {
        (PoolId id, MilestoneToken t) = _launch(0, 0, 0);

        assertEq(hook.poolState(id).devBuyTotal, 0, "no dev buy recorded");
        assertEq(t.balanceOf(creator), 0, "creator holds no token");
        assertEq(hook.releasableDevBuy(id), 0, "nothing to release");
    }

    function test_ethWithoutADevBuyIsRejected() public {
        LaunchConfig memory config = _config(0, 0);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.DevBuyEthWithoutDevBuy.selector, uint256(1 ether)));
        hook.launch{value: 1 ether}(config, "");
    }

    // --- Scenario: Dev buy consumes bonding curve inventory ---

    function test_devBuyConsumesCurveInventory() public {
        vm.recordLogs();
        (PoolId id, MilestoneToken t) = _launch(0.1e18, 0, 50_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 settled = _curveTokenSettled(logs);
        uint256 purchased = hook.poolState(id).devBuyTotal;

        assertEq(purchased, (SUPPLY * 10) / 100, "purchased the configured share");
        assertGt(settled, purchased, "the curve deployed more than the dev buy consumed");
        // The pool holds every token the curve settled, less exactly what the dev buy took straight back
        // out of it. Nothing was minted for the dev buy; it came out of the curve's own inventory.
        assertEq(_pooledToken(id), settled - purchased, "the pool holds the curve less the dev buy");
    }

    function test_devBuyMovesThePriceLikeAnyBuy() public {
        (PoolId withoutDev,) = _launch(0, 0, 0);
        (PoolId withDev,) = _launch(0.1e18, 0, 50_000 ether);

        // Level rises with token price, so a buy that lifted the price ends higher.
        assertGt(_levelOf(withDev), _levelOf(withoutDev), "the dev buy pushed the price up like any buy");
    }

    function test_devBuyPaysRealEth() public {
        uint256 before = creator.balance;
        _launch(0.05e18, 0, 50_000 ether);

        assertLt(creator.balance, before, "creator paid for the tokens");
    }

    function test_unspentEthIsRefunded() public {
        uint256 before = creator.balance;
        (PoolId id,) = _launch(0.01e18, 0, 90_000 ether);

        uint256 spent = before - creator.balance;
        assertLt(spent, 90_000 ether, "the whole budget was not consumed");
        assertGt(spent, 0, "something was spent");
        assertEq(hook.poolState(id).devBuyTotal, SUPPLY / 100, "bought exactly the configured share");
    }

    function test_insufficientEthRevertsTheWholeLaunch() public {
        LaunchConfig memory config = _config(0.1e18, 0);

        vm.prank(creator);
        vm.expectRevert();
        hook.launch{value: 1 wei}(config, "");
    }

    // --- Scenario: Dev buy requires the creator's own transaction ---

    /// @dev A relayed launch is valid — the creator signed it — but the dev buy is not the relayer's to
    /// execute, so it is dropped rather than reverting the launch. The share it would have bought is
    /// still undeployed curve inventory, which is what makes the drop harmless: nothing was minted for
    /// it and nothing needs reclaiming.
    function test_relayedLaunchExecutesNoDevBuy() public {
        LaunchConfig memory config = _config(0.05e18, 0);

        vm.recordLogs();
        (PoolId id,, MilestoneToken t) = _launchRelayed(config, RELAYER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, MilestoneBase.DevBuySkipped.selector), 1, "the skip is announced");
        assertEq(_countLogs(logs, MilestoneBase.DevBuyExecuted.selector), 0, "no dev buy executed");

        assertEq(hook.poolState(id).devBuyTotal, 0, "no dev buy recorded");
        assertEq(t.balanceOf(creator), 0, "creator holds nothing");
        assertEq(hook.releasableDevBuy(id), 0, "nothing to release");

        // Only genesis position 0 was deployed, so the dev-buy share was never drawn out of the curve.
        assertEq(hook.poolState(id).curveDeployed, 1, "the dev-buy share remains curve inventory");
    }

    // --- Scenario: Dev buy is observable on chain ---

    /// @dev The event has to carry the consideration, not just the quantity: the dev buy is an
    /// exact-output swap against a curve whose price nobody can predict off-chain, so what the creator
    /// paid is only knowable from the log. Asserted against the creator's own balance delta, which is the
    /// independent measure of the same number.
    function test_devBuyIsObservableOnChain() public {
        uint256 before = creator.balance;

        vm.recordLogs();
        (PoolId id,) = _launch(0.05e18, 90 days, 90_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 paid = before - creator.balance;
        uint256 at = _firstLogAt(logs, MilestoneBase.DevBuyExecuted.selector);
        assertTrue(at != type(uint256).max, "DevBuyExecuted emitted");

        (uint256 tokensBought, uint256 ethSpent, uint32 vestingSeconds) =
            abi.decode(logs[at].data, (uint256, uint256, uint32));

        assertEq(uint256(logs[at].topics[1]), uint256(PoolId.unwrap(id)), "keyed to the pool");
        assertEq(tokensBought, (SUPPLY * 5) / 100, "the purchased amount is emitted");
        assertEq(ethSpent, paid, "the consideration paid is emitted, net of the refund");
        assertEq(vestingSeconds, 90 days, "the vesting term is emitted");
    }

    // --- Scenario: Dev buy is capped at 10% of supply ---
    // (validator-level; proved end to end here)

    function test_devBuyAboveCapIsRejectedAtLaunch() public {
        LaunchConfig memory config = _config(uint64(Bounds.MAX_DEV_BUY_SHARE_WAD + 1), 0);

        vm.prank(creator);
        vm.expectRevert();
        hook.launch{value: 90_000 ether}(config, "");
    }

    // --- Scenario: Zero vesting releases immediately ---

    function test_zeroVestingReleasesImmediately() public {
        (PoolId id, MilestoneToken t) = _launch(0.05e18, 0, 90_000 ether);

        uint256 expected = (SUPPLY * 5) / 100;
        assertEq(t.balanceOf(creator), expected, "creator received the tokens at launch");
        assertEq(hook.releasableDevBuy(id), 0, "nothing left to release");
        assertEq(hook.poolState(id).devBuyReleased, expected, "recorded as released");
    }

    // --- Scenario: Vested tokens are held by the hook ---

    function test_vestedTokensAreHeldByTheHook() public {
        (PoolId id, MilestoneToken t) = _launch(0.05e18, 180 days, 90_000 ether);

        assertEq(t.balanceOf(creator), 0, "creator holds nothing yet");
        assertEq(hook.poolState(id).devBuyTotal, (SUPPLY * 5) / 100, "recorded");
        assertEq(hook.releasableDevBuy(id), 0, "nothing vested at t=0");
    }

    // --- Scenario: Linear release over the vesting period ---

    function test_linearReleaseOverThePeriod() public {
        uint32 duration = 180 days;
        (PoolId id, MilestoneToken t) = _launch(0.05e18, duration, 90_000 ether);
        uint256 total = (SUPPLY * 5) / 100;

        vm.warp(block.timestamp + duration / 2);
        assertApproxEqAbs(hook.releasableDevBuy(id), total / 2, 1e12, "half vested at the midpoint");

        vm.prank(creator);
        uint256 released = hook.releaseDevBuy(id);

        assertApproxEqAbs(released, total / 2, 1e12, "released about half");
        assertEq(t.balanceOf(creator), released, "creator holds exactly what was released");
        assertEq(hook.releasableDevBuy(id), 0, "nothing left right now");
    }

    function test_releaseIsIncrementalAcrossTheSchedule() public {
        uint32 duration = 100 days;
        (PoolId id, MilestoneToken t) = _launch(0.05e18, duration, 90_000 ether);
        uint256 total = (SUPPLY * 5) / 100;

        // Warp targets are computed from a base captured once, not from repeated `block.timestamp`
        // reads. Under via_ir solc common-subexpression-eliminates `block.timestamp` — valid, since it is
        // constant within a real transaction — so `vm.warp(block.timestamp + x)` in a loop would advance
        // the clock only once.
        uint256 start = block.timestamp;
        uint256 releasedSoFar;
        for (uint256 i = 1; i <= 4; i++) {
            vm.warp(start + (uint256(duration) / 4) * i);
            vm.prank(creator);
            releasedSoFar += hook.releaseDevBuy(id);
        }

        assertEq(releasedSoFar, total, "the whole allocation released over the schedule");
        assertEq(t.balanceOf(creator), total, "creator holds it all");
    }

    // --- Scenario: Full release after the vesting period ---

    function test_fullReleaseAfterThePeriod() public {
        uint32 duration = 90 days;
        (PoolId id, MilestoneToken t) = _launch(0.05e18, duration, 90_000 ether);
        uint256 total = (SUPPLY * 5) / 100;

        vm.warp(block.timestamp + duration + 1);

        vm.prank(creator);
        assertEq(hook.releaseDevBuy(id), total, "everything vested");
        assertEq(t.balanceOf(creator), total, "creator holds it all");

        // Further claims transfer nothing.
        vm.prank(creator);
        assertEq(hook.releaseDevBuy(id), 0, "nothing further");
        assertEq(t.balanceOf(creator), total, "balance unchanged");
    }

    function test_vestingNeverOverReleases() public {
        uint32 duration = 30 days;
        (PoolId id,) = _launch(0.05e18, duration, 90_000 ether);
        uint256 total = (SUPPLY * 5) / 100;

        vm.warp(block.timestamp + 10 * 365 days);
        assertEq(hook.releasableDevBuy(id), total, "capped at the purchased amount");
    }

    // --- Scenario: Only the creator can claim vested tokens ---

    function test_onlyCreatorCanRelease() public {
        (PoolId id,) = _launch(0.05e18, 90 days, 90_000 ether);
        vm.warp(block.timestamp + 45 days);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotCreator.selector, id, STRANGER));
        hook.releaseDevBuy(id);

        vm.prank(PROTOCOL_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotCreator.selector, id, PROTOCOL_ADMIN));
        hook.releaseDevBuy(id);
    }

    /// @dev Selling the revenue NFT does not hand over the vesting schedule: the two are separate
    /// entitlements, and only the NFT is transferable.
    function test_transferringTheRevenueNftDoesNotMoveTheVestingSchedule() public {
        (PoolId id,) = _launch(0.05e18, 90 days, 90_000 ether);

        uint256 tokenId = nft.tokenIdOf(id);
        vm.prank(creator);
        nft.transferFrom(creator, STRANGER, tokenId);

        vm.warp(block.timestamp + 45 days);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MilestoneBase.NotCreator.selector, id, STRANGER));
        hook.releaseDevBuy(id);

        vm.prank(creator);
        assertGt(hook.releaseDevBuy(id), 0, "creator still releases their own vesting");
    }

    function testFuzz_vestedAmountIsMonotonic(uint32 elapsed) public {
        uint32 duration = 365 days;
        (PoolId id,) = _launch(0.05e18, duration, 90_000 ether);

        elapsed = uint32(bound(elapsed, 0, duration));
        uint256 start = block.timestamp;

        vm.warp(start + elapsed);
        uint256 first = hook.releasableDevBuy(id);

        vm.warp(start + duration);
        uint256 later = hook.releasableDevBuy(id);

        assertGe(later, first, "vested amount never decreases");
        assertEq(later, (SUPPLY * 5) / 100, "fully vested at the end");
    }
}
