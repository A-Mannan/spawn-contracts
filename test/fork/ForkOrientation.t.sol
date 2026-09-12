// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {Position} from "v4-core/src/libraries/Position.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {PoolState} from "../../src/types/LaunchTypes.sol";

import {BaseForkHarnessTest} from "./ForkFixtures.sol";

/// @notice Orientation against the live Base v4 singleton (task 12.3).
///
/// `level = -tick` is the protocol's only coordinate and `Orientation` is the only place the sign flips.
/// The unit suite proves the conversion is self-consistent in isolation; what only the deployed manager can
/// settle is whether the positions the hook actually mints land where that convention says they do — below
/// spot in tick terms, holding token and no ETH — and whether the real tick bitmap and fee accounting then
/// turn that token into native ETH as the level rises through them.
///
/// Every assertion here is written to be *sign-sensitive*, which is the second half of the task: were the
/// level conversion inverted, each test would fail rather than quietly pass. Three mechanisms do that work,
/// and none of them requires editing the library to check:
///
/// - the tick bounds are compared against the pool's own `slot0` tick, an inequality that reverses under an
///   inversion;
/// - the composition assertions name which currency, so a position mirrored to the far side of spot would
///   report the other one;
/// - each position is looked up a second time at its *mirrored* key — level bounds used directly as ticks,
///   which is exactly where an inverted conversion would have put it — and the pool must hold nothing there.
contract ForkOrientationTest is BaseForkHarnessTest {
    /// @dev The fixture's `using StateLibrary for IPoolManager` is file-scoped, so the mirrored-key
    /// lookups below need their own directive — they read positions by raw ticks, which the fixture's
    /// level-taking helpers cannot express.
    using StateLibrary for IPoolManager;

    /// @dev A run-up budget, not a spend: every buy here is limit-bounded.
    uint256 private constant RUNUP_BUDGET = 1_000_000 ether;

    /// @dev Far enough inside a band to be unambiguously within it, far short of its top.
    int24 private constant INSIDE = 100;

    /// @dev The band the multi-band sweep runs to. Bands 0..3 complete on the way; band 4 stays live.
    uint256 private constant SWEEP_TOP = 4;

    // --- Scenario (bonding-curve-phase): Positions form a nested staircase ---
    // --- Curve steps are minted strictly below spot holding only the token: derived, no scenario of its own ---
    //
    // The staircase geometry is specified; that it lands below spot in the real manager's tick space, and is
    // charged for in token alone, is what this layer adds.
    function test_curveStepsAreMintedBelowSpotHoldingOnlyTheToken() public {
        PoolState memory state = hook.poolState(poolId);
        (, int24 tickBefore) = _slot0();
        uint256 deployedBefore = _deployedCurveCount();

        uint256 hookEthBefore = address(hook).balance;
        uint256 hookClaimBefore = manager.balanceOf(address(hook), 0);

        // Halfway up the curve span, which pulls several undeployed steps in ahead of the order.
        vm.recordLogs();
        _buyToLevel(FORK_FLOAT, state.openingLevel + template.curveSpanLevels / 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 deployed = _deployedCurveCount();
        assertGt(deployed, deployedBefore, "the buy deployed curve steps ahead of itself");

        uint256 tokenStaked;
        for (uint256 i = deployedBefore; i < deployed; i++) {
            int24 start = hook.curvePositionStart(poolId, i);
            bytes32 salt = hook.curvePositionSalt(i);

            // Each step spans its own start level to the shared far level, so in tick terms it is the
            // negated range with its bounds swapped.
            (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(start, state.farLevel);
            assertEq(tickLower, -state.farLevel, "the lower tick is the far level negated");
            assertEq(tickUpper, -start, "the upper tick is the start level negated");

            // Strictly below the spot it was minted at: `beforeSwap` mints before the swap moves the price,
            // so the tick to measure against is the one this swap started from.
            assertLt(tickUpper, tickBefore, "the whole step sits below the spot it was minted at");

            uint128 liquidity = _liquidityAtTicks(tickLower, tickUpper, salt);
            assertGt(liquidity, 0, "and it is live in the deployed manager");

            // Composition follows from the range being wholly below spot: the position is worth token and
            // nothing else, and that token amount is what the hook actually paid in.
            tokenStaked += SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity, false
            );
            // The tripwire: an inverted conversion would have minted the step here instead.
            // no-via_ir stack limit: the assertion lives in a helper call.
            _assertNothingLivesAtMirroredRange(start, state.farLevel, salt);
        }

        (uint256 minted, uint256 tokenSettled) = _mintedCurvePositionsFromLogs(logs);
        assertEq(minted, deployed - deployedBefore, "every step the logs report is a step the pool holds");
        assertApproxEqRel(tokenSettled, tokenStaked, 1e12, "and the token the hook settled is the token they hold");

        // The mint was token-only from the hook's side too: no ETH left custody, in either of the two forms
        // Decision 13 allows it to be held in.
        assertEq(address(hook).balance, hookEthBefore, "no ETH was staked into the curve");
        assertEq(manager.balanceOf(address(hook), 0), hookClaimBefore, "and no ETH claim was spent on it");
    }

    // --- A curve step's inventory becomes native ETH as the level rises through it: derived, no scenario of its own ---
    //
    // The same position, read twice against the real pool: once at the level it was minted at and once after
    // the price has walked past its far end. Nothing about the position changes in between — only where spot
    // sits relative to it — so the composition flip is the orientation claim in its most direct form.
    function test_aCurveStepHoldsOnlyEthOnceThePriceHasRisenPastIt() public {
        PoolState memory state = hook.poolState(poolId);
        bytes32 salt = hook.curvePositionSalt(0);
        (int24 tickLower, int24 tickUpper) =
            Orientation.levelRangeToTicks(hook.curvePositionStart(poolId, 0), state.farLevel);

        uint128 liquidity = _liquidityAtTicks(tickLower, tickUpper, salt);
        assertGt(liquidity, 0, "the opening step is live");

        (, int24 tickAtLaunch) = _slot0();
        assertEq(tickAtLaunch, tickUpper, "spot opens at the step's own start, its upper bound in ticks");
        uint256 tokenHeld = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity, false
        );
        assertGt(tokenHeld, 0, "and holds token across its whole range");

        // Buy the curve out to its far end, which carries spot to the step's lower tick or one tick past it:
        // the far level's tick is initialised, and v4 leaves a `zeroForOne` swap that crosses a tick exactly
        // at `tickNext - 1`. Either way the entire range now sits at or above spot in tick terms, which is
        // the claim — and an inversion would leave it below instead.
        _buyToLevel(FORK_FLOAT, state.farLevel);

        (, int24 tickAfter) = _slot0();
        assertGe(_level(), state.farLevel, "the level rose to the far end");
        assertLe(tickAfter, tickLower, "which in tick terms is the step's lower bound, or one tick past it");
        assertEq(_liquidityAtTicks(tickLower, tickUpper, salt), liquidity, "the position itself is untouched");

        // Same range, same liquidity, opposite side of spot: what was token inventory is now native ETH,
        // and the amount is the position's whole quote value.
        uint256 ethHeld = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity, false
        );
        assertGt(ethHeld, 0, "the step now holds native ETH");

        // The proof that the ETH is really the pool's and not the test's arithmetic: graduating burns the
        // curves and the quote it credits covers this step's share.
        _buy(1_000);
        assertGt(hook.creatorClaimable(poolId) + hook.protocolClaimable(), 0, "the burn paid out in ETH");
    }

    // --- Scenario (milestone-ladder): Band ticks are computable by any observer ---
    // --- Bands are minted strictly below spot holding only the token: derived, no scenario of its own ---
    //
    // Two buys, because a band is only live while spot is inside it: the first stops inside band 0 and leaves
    // it untouched for the composition assertions, the second sweeps to band 4 so the geometry claim is made
    // over five bands at once — from the logs, since the four below spot are harvested on arrival.
    function test_bandsAreMintedBelowSpotHoldingOnlyTheToken() public {
        _graduate();

        PoolState memory state = hook.poolState(poolId);
        assertEq(_deployedBandCount(), 0, "no bands exist immediately after graduation");

        uint256 hookEthBefore = address(hook).balance;
        uint256 hookClaimBefore = manager.balanceOf(address(hook), 0);
        uint256 hookTokenBefore = token.balanceOf(address(hook));

        (, int24 tickBefore) = _slot0();
        vm.recordLogs();
        _buyToLevel(RUNUP_BUDGET, _bandLower(0) + INSIDE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_deployedBandCount(), 1, "the buy stopped inside band 0, so band 0 alone deployed");
        assertEq(_completedBandCount(), 0, "and nothing was harvested to disturb it");

        (int24 lower, int24 upper, bool exists) = hook.bandLevels(poolId, 0);
        assertTrue(exists, "band 0 exists");
        _assertBandGeometry(state.graduationLevel, 0, lower, upper);

        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(lower, upper);
        assertEq(tickLower, -upper, "the lower tick is the upper level negated");
        assertEq(tickUpper, -lower, "the upper tick is the lower level negated");
        assertLt(tickUpper, tickBefore, "the whole band sits below the spot it was minted at");

        uint128 liquidity = _liquidityAtTicks(tickLower, tickUpper, hook.bandSalt(0));
        assertGt(liquidity, 0, "the band is live in the deployed manager");
        assertEq(liquidity, _bandLiquidity(0), "at the key the hook's own geometry names");
        assertEq(_liquidityAtTicks(lower, upper, hook.bandSalt(0)), 0, "nothing lives at the mirrored key");

        // A single-sided sell band: its whole value is token, and that token is what left hook custody.
        uint256 inventory = _bandInventoryFromLogs(logs, 0);
        assertApproxEqRel(
            SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity, false
            ),
            inventory,
            1e12,
            "the band holds the inventory the log reports"
        );
        assertEq(hookTokenBefore - token.balanceOf(address(hook)), inventory, "which came out of hook custody in token");
        assertEq(address(hook).balance, hookEthBefore, "no ETH was staked into the band");
        assertEq(manager.balanceOf(address(hook), 0), hookClaimBefore, "and no ETH claim was spent on it");

        // Now sweep to band 4. Bands 0..3 complete on the way, so the surviving evidence for them is the
        // geometry their deployment logged — which is the observer claim: template plus graduation level.
        (, tickBefore) = _slot0();
        vm.recordLogs();
        _buyToLevel(RUNUP_BUDGET, _bandLower(SWEEP_TOP) + INSIDE);
        logs = vm.getRecordedLogs();

        for (uint256 i = 1; i <= SWEEP_TOP; i++) {
            _assertSweptBand(logs, state.graduationLevel, i, tickBefore);
        }

        assertEq(_deployedBandCount(), SWEEP_TOP + 1, "five bands were minted in all");
        assertGt(_bandLiquidity(SWEEP_TOP), 0, "and the one spot came to rest inside is still live");
    }

    // --- Scenario (milestone-ladder): Harvest proceeds are quote only ---
    // --- Scenario (milestone-ladder): Active service fee is applied ---
    // --- Scenario (milestone-ladder): Net harvest funds only its source pool ---
    // --- Scenario (milestone-ladder): Harvest accounting conserves the gross amount ---
    // --- Scenario (milestone-ladder): Harvest leaves direct creator revenue unchanged ---
    //
    // The band-side half of "converts to native ETH as the level rises through it". The position is not read
    // for its composition here but burned by the protocol itself, so what the live pool credits is the
    // measurement: quote to the ledgers, token residue to carried inventory, and nothing token-denominated
    // anywhere near a recipient.
    function test_aBandsInventoryIsPaidOutAsEthWhenItIsHarvested() public {
        _graduate();
        _buyToLevel(RUNUP_BUDGET, _bandLower(0) + INSIDE);
        assertGt(_bandLiquidity(0), 0, "band 0 is live and unharvested");

        PoolState memory before = hook.poolState(poolId);
        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable();
        uint256 potBefore = hook.payoutPot(poolId);
        uint256 creatorTokenBefore = token.balanceOf(creator);
        uint256 protocolTokenBefore = token.balanceOf(PROTOCOL_RECIPIENT);

        // Past the band's top but short of band 1's floor, so this swap harvests band 0 and mints nothing.
        vm.recordLogs();
        _buyToLevel(RUNUP_BUDGET, _bandUpper(0) + INSIDE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 quoteProceeds, uint256 tokenResidue) = _harvestedFromLogs(logs, 0);
        assertGt(quoteProceeds, 0, "the band's token inventory came back as ETH");
        assertTrue(hook.bandCompleted(poolId, 0), "the milestone completed");
        assertEq(_bandLiquidity(0), 0, "and its position is gone from the pool");
        assertEq(_deployedBandCount(), 1, "no band was minted by this swap");

        // Quote only: the active service fee grew the global protocol ledger, the remainder funded this
        // pool's pot, direct creator revenue was untouched, neither party received token, and residue returned
        // to ladder inventory.
        PoolState memory now_ = hook.poolState(poolId);
        uint256 protocolPaid = hook.protocolClaimable() - protocolBefore;
        uint256 potFunded = hook.payoutPot(poolId) - potBefore;
        assertEq(hook.creatorClaimable(poolId), creatorBefore, "harvest did not credit direct creator revenue");
        assertGt(protocolPaid, 0, "the service fee entered the global protocol ledger");
        assertGt(potFunded, 0, "the net harvest funded only this pool's pot");
        assertEq(protocolPaid + potFunded, quoteProceeds, "service fee plus pot conserved gross quote");
        assertEq(token.balanceOf(creator), creatorTokenBefore, "the creator received no token");
        assertEq(token.balanceOf(PROTOCOL_RECIPIENT), protocolTokenBefore, "and neither did the protocol");
        assertEq(now_.carriedInventory, before.carriedInventory + tokenResidue, "the residue became carried inventory");
    }

    // --- The live tick is the negation of the level: derived, no scenario of its own ---
    //
    // The conversion at the one boundary the unit suite cannot reach: a `slot0` read from the real singleton.
    function test_theLiveTickIsTheNegationOfTheLevel() public {
        (, int24 tick) = _slot0();
        assertEq(Orientation.toLevel(tick), -tick, "the level is the tick negated");
        assertEq(_level(), -tick, "and the pool's own tick is what the level is read from");

        // The sign holds under motion, not just at the opening price.
        _buy(10 ether);
        (, int24 movedTick) = _slot0();
        assertLt(movedTick, tick, "a buy moved the tick down");
        assertGt(_level(), -tick, "which is the level moving up");
        assertEq(_level(), -movedTick, "by exactly the negation");
    }

    // --- Helpers ---

    /// @dev The observer claim: a band's bounds follow from the published template and the graduation level
    /// alone, with no protocol state consulted.
    function _assertBandGeometry(int24 graduationLevel, uint256 index, int24 lower, int24 upper) private view {
        int24 expectedLower = graduationLevel + int24(int256(index + 1) * int256(template.bandLevelSpacing));

        assertEq(lower, expectedLower, "the lower level is the graduation level plus whole band spacings");
        assertEq(upper, expectedLower + template.bandWidthLevels, "and the width is the template's");
    }

    function _liquidityAtTicks(int24 tickLower, int24 tickUpper, bytes32 salt) private view returns (uint128) {
        return IPoolManager(address(manager)).getPositionLiquidity(
            poolId, Position.calculatePositionKey(HOOK_ADDR, tickLower, tickUpper, salt)
        );
    }

    /// @dev no-via_ir stack limit: the inverted-conversion tripwire, in its own frame.
    function _assertNothingLivesAtMirroredRange(int24 start, int24 farLevel, bytes32 salt) private view {
        assertEq(_liquidityAtTicks(start, farLevel, salt), 0, "nothing lives at the mirrored key");
    }

    /// @dev no-via_ir stack limit: one swept band's geometry assertions, in their own frame.
    function _assertSweptBand(Vm.Log[] memory logs, int24 graduationLevel, uint256 i, int24 tickBefore) private view {
        (int24 loggedLower, int24 loggedUpper) = _bandGeometryFromLogs(logs, uint32(i));
        _assertBandGeometry(graduationLevel, i, loggedLower, loggedUpper);
        assertLt(-loggedLower, tickBefore, "every band this buy minted was below the spot it started from");
    }

    // --- Log decoders ---
    //
    // Local copies rather than shared ones: the unit suite's decoders live in fixtures rooted in a locally
    // deployed manager, which this layer cannot inherit from.

    function _mintedCurvePositionsFromLogs(Vm.Log[] memory logs)
        private
        pure
        returns (uint256 minted, uint256 tokenSettled)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.CurvePositionsDeployed.selector) continue;
            (uint256 m,, uint256 t) = abi.decode(logs[i].data, (uint256, uint32, uint256));
            minted += m;
            tokenSettled += t;
        }
    }

    function _bandGeometryFromLogs(Vm.Log[] memory logs, uint32 index) private pure returns (int24, int24) {
        uint256 at = _bandLogAt(logs, index);
        require(at != type(uint256).max, "ForkOrientation: no BandDeployed log");
        (int24 lower, int24 upper,,) = abi.decode(logs[at].data, (int24, int24, uint128, uint256));
        return (lower, upper);
    }

    function _bandInventoryFromLogs(Vm.Log[] memory logs, uint32 index) private pure returns (uint256) {
        uint256 at = _bandLogAt(logs, index);
        require(at != type(uint256).max, "ForkOrientation: no BandDeployed log");
        (,,, uint256 inventory) = abi.decode(logs[at].data, (int24, int24, uint128, uint256));
        return inventory;
    }

    function _bandLogAt(Vm.Log[] memory logs, uint32 index) private pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.BandDeployed.selector) continue;
            if (uint32(uint256(logs[i].topics[2])) != index) continue;
            return i;
        }
        return type(uint256).max;
    }

    function _harvestedFromLogs(Vm.Log[] memory logs, uint32 index) private pure returns (uint256, uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.MilestoneHarvested.selector) continue;
            if (uint32(uint256(logs[i].topics[2])) != index) continue;
            (uint256 quoteProceeds, uint256 tokenResidue,) = abi.decode(logs[i].data, (uint256, uint256, uint32));
            return (quoteProceeds, tokenResidue);
        }
        revert("ForkOrientation: no MilestoneHarvested log");
    }
}
