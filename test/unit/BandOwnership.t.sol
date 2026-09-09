// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TestRouter} from "../Fixtures.sol";
import {HarnessLaunchpadTest} from "../HarnessFixtures.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {PoolState} from "../../src/types/LaunchTypes.sol";

/// @notice Unit tests for task 11.3 — bands are hook-owned and externally immutable, and no claim path
/// reaches ladder inventory or the full-range position.
///
/// @dev These are negative claims, so each is made two ways where it can be: by exercising every entry point
/// a would-be extractor actually has, and by asserting the protocol state those entry points must not move.
/// The structural half of the same guarantee is covered by `make lock-check` and `make layout-check`, which
/// assert properties of the code's shape rather than of the paths a test happened to think of.
contract BandOwnershipTest is HarnessLaunchpadTest {
    using StateLibrary for IPoolManager;

    uint256 internal constant MEASURED_SELL = 1_000_000 ether;

    /// @dev A *budget*, not an amount: the buy that wakes a band is price-limited inside it.
    uint256 internal constant BAND_BUDGET = 5_000 ether;

    /// @dev What the parked suite read off the deleted `LiveBand` record. Bands are derived geometry now
    /// (Decision 4, revised), so the figures are gathered from the hook's getters and the deployment log
    /// at the moment of deployment and carried through the test by hand.
    struct Band {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint256 inventory;
    }

    /// @dev A second router, so an attacker's attempts are distinguishable from the fixture's own trading.
    TestRouter internal attacker;

    function setUp() public virtual override {
        super.setUp();
        _graduate();
        hook.collectFees(key);

        attacker = new TestRouter(IPoolManager(address(manager)));
        vm.deal(address(attacker), 1_000_000 ether);
    }

    /// @notice Wakes band `index` and leaves it live.
    ///
    /// @dev Limited *inside* the band rather than past its top, so the position the assertions are about
    /// still exists: crossing the top in the same transaction would harvest and burn it.
    function _deployBand(uint256 index) private returns (Band memory b) {
        vm.recordLogs();
        _buyToLevel(BAND_BUDGET, _bandLower(index) + 100);
        b.inventory = _deployedInventoryOf(vm.getRecordedLogs(), uint32(index));
        b.lower = _bandLower(index);
        b.upper = _bandUpper(index);
        b.liquidity = _bandLiquidity(index);
    }

    /// @dev The same range read against a different owner. v4 keys positions by owner, so this is how
    /// "the hook owns it" is distinguished from "the range holds liquidity".
    function _liquidityOwnedBy(address owner, Band memory b, bytes32 salt) private view returns (uint128) {
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(b.lower, b.upper);
        return IPoolManager(address(manager)).getPositionLiquidity(
            poolId, Position.calculatePositionKey(owner, tickLower, tickUpper, salt)
        );
    }

    function _harvestedQuoteFromLogs(Vm.Log[] memory logs) private pure returns (uint256 quote) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.MilestoneHarvested.selector) {
                (quote,,) = abi.decode(logs[i].data, (uint256, uint256, uint32));
            }
        }
    }

    // --- Scenario: External band mutation is rejected ---

    function test_externalBandMutationIsRejected() public {
        Band memory b = _deployBand(0);
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(b.lower, b.upper);
        int24 spacing = key.tickSpacing;

        // Adding to the band's range, removing from it, and straddling it: all three are liquidity operations
        // on a range the hook owns, and the `beforeAddLiquidity`/`beforeRemoveLiquidity` guards admit only
        // the hook itself, whatever the ticks and whatever the salt.
        vm.expectRevert();
        attacker.addLiquidity(key, tickLower, tickUpper, 1e18);

        vm.expectRevert();
        attacker.removeLiquidity(key, tickLower, tickUpper, -1e18);

        vm.expectRevert();
        attacker.addLiquidity(key, tickLower - 10 * spacing, tickUpper + 10 * spacing, 1e18);

        // Nothing moved.
        assertEq(_bandLiquidity(0), b.liquidity, "the band's liquidity is unchanged");
        assertEq(_bandLower(0), b.lower, "and it was not repriced");
        assertEq(_bandUpper(0), b.upper, "at either bound");
        assertTrue(hook.bandDeployed(poolId, 0), "still deployed");
        assertFalse(hook.bandCompleted(poolId, 0), "and still live");
    }

    function test_theCreatorIsNotPrivilegedOverABandEither() public {
        Band memory b = _deployBand(0);
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(b.lower, b.upper);

        TestRouter creatorRouter = new TestRouter(IPoolManager(address(manager)));
        vm.deal(address(creatorRouter), 1_000 ether);

        vm.prank(creator);
        vm.expectRevert();
        creatorRouter.removeLiquidity(key, tickLower, tickUpper, -int256(uint256(b.liquidity)));

        assertEq(_bandLiquidity(0), b.liquidity, "the band is untouched");
    }

    /// @dev And the band is genuinely hook-owned rather than merely hook-created: v4 keys positions by owner,
    /// so the liquidity is recorded against the hook's address and nobody else's.
    function test_bandPositionsAreOwnedByTheHook() public {
        Band memory b = _deployBand(0);

        assertGt(b.liquidity, 0, "there is something to hold");
        assertEq(_liquidityOwnedBy(HOOK_ADDR, b, hook.bandSalt(0)), b.liquidity, "the hook's own position holds it");
        assertEq(_liquidityOwnedBy(address(attacker), b, hook.bandSalt(0)), 0, "and no one else's does");
        assertEq(_liquidityOwnedBy(creator, b, hook.bandSalt(0)), 0, "not even the creator's");
        assertEq(_liquidityOwnedBy(HOOK_ADDR, b, bytes32(0)), 0, "and not under a salt the protocol never uses");
    }

    // --- Scenario: Creator cannot withdraw ladder inventory ---

    /// @dev Accrues in both currencies while leaving band 0 live: the sell pays its fee in token, the buy
    /// back up pays in quote, and neither crosses the band's top. Collection is what moves a fee onto a
    /// ledger, so it runs here rather than in the assertions.
    function _accrueOnBothSidesOfALiveBand() private {
        _sell(MEASURED_SELL);
        _buyToLevel(BAND_BUDGET, _bandLower(0) + 200);
        hook.collectFees(key);
    }

    function test_creatorCannotWithdrawLadderInventory() public {
        Band memory b = _deployBand(0);
        _accrueOnBothSidesOfALiveBand();
        uint128 bandBefore = _bandLiquidity(0);

        PoolState memory before = hook.poolState(poolId);
        uint256 claimable = hook.creatorClaimable(poolId);
        uint256 ethBefore = creator.balance;
        uint256 tokensBefore = token.balanceOf(creator);
        assertGt(claimable, 0, "there is a balance to claim");
        assertGt(before.ladderInventoryRemaining, 0, "and ladder inventory sitting beside it");

        // Every entry point the creator has. None of them names an amount, so none can over-draw.
        vm.prank(creator);
        hook.claimCreator(poolId);

        PoolState memory afterClaims = hook.poolState(poolId);
        assertEq(creator.balance - ethBefore, claimable, "the creator received exactly their accrued balance");
        // Under design Decision 21 nothing token-denominated is ever credited to a claimant, so the creator's
        // token balance is the sharper assertion: no path pays them in the currency the ladder holds.
        assertEq(token.balanceOf(creator), tokensBefore, "and not one token, which is what the ladder holds");
        assertEq(
            afterClaims.ladderInventoryRemaining, before.ladderInventoryRemaining, "undeployed ladder supply is intact"
        );
        assertEq(afterClaims.carriedInventory, before.carriedInventory, "as is the carry");
        assertEq(afterClaims.milestoneFundAccrued, before.milestoneFundAccrued, "and the milestone fund");
        assertEq(_bandLiquidity(0), bandBefore, "and the deployed band is untouched");
        assertGt(b.inventory, 0, "the band really was funded from the ladder share");
        assertTrue(hook.bandDeployed(poolId, 0), "and it is still deployed");
    }

    function test_noPrivilegedCallerCanReachLadderInventoryEither() public {
        Band memory b = _deployBand(0);
        PoolState memory before = hook.poolState(poolId);

        // Governance can change configuration, but cannot move a token.
        bytes32 salt = keccak256("band-ownership-recipient");
        vm.prank(PROTOCOL_ADMIN);
        controller.scheduleProtocolRecipient(STRANGER, salt);
        controller.executeProtocolRecipient(STRANGER, salt);

        PoolState memory afterAdmin = hook.poolState(poolId);
        assertEq(afterAdmin.ladderInventoryRemaining, before.ladderInventoryRemaining, "ladder supply intact");
        assertEq(_bandLiquidity(0), b.liquidity, "the live band intact");
        assertEq(afterAdmin.fullRangeLiquidity, before.fullRangeLiquidity, "the full range intact");
        assertEq(afterAdmin.carriedInventory, before.carriedInventory, "the carry intact");
        assertEq(afterAdmin.milestoneFundAccrued, before.milestoneFundAccrued, "the fund intact");
    }

    // --- Scenario (revenue-claims): Claims cannot reach ladder inventory ---
    // --- Scenario (revenue-claims): Claims cannot reach locked liquidity ---
    //
    // Design Decision 21 removed the token claim ledgers: a claimant is only ever paid in quote, so the
    // parked suite's four claim calls are two here. That makes the negative claim stronger rather than
    // weaker — the currency the ladder and the token side of the full-range position are denominated in has
    // no claim entry point at all.

    function test_claimsCannotReachLadderInventoryOrTheFullRangePosition() public {
        Band memory b = _deployBand(0);
        _accrueOnBothSidesOfALiveBand();

        PoolState memory before = hook.poolState(poolId);
        uint128 fullRangeBefore = _fullRangeLiquidity();
        uint128 bandBefore = _bandLiquidity(0);
        uint256 hookTokensBefore = token.balanceOf(HOOK_ADDR);

        uint256 creatorQuote = hook.creatorClaimable(poolId);
        uint256 protocolQuote = hook.protocolClaimable();
        assertGt(creatorQuote, 0, "the creator has ETH to claim");
        assertGt(protocolQuote, 0, "and so does the protocol");

        vm.prank(creator);
        assertEq(hook.claimCreator(poolId), creatorQuote, "paid exactly the accrued ETH");
        vm.prank(PROTOCOL_RECIPIENT);
        assertEq(hook.claimProtocol(), protocolQuote, "paid exactly the accrued ETH");

        // A second claim finds nothing: the ledgers are zeroed, not merely decremented.
        vm.prank(creator);
        assertEq(hook.claimCreator(poolId), 0, "nothing left to claim");
        vm.prank(PROTOCOL_RECIPIENT);
        assertEq(hook.claimProtocol(), 0, "nothing left to claim");

        PoolState memory afterClaims = hook.poolState(poolId);
        assertEq(_bandLiquidity(0), bandBefore, "the deployed band is unaffected");
        assertGt(b.liquidity, 0, "there was a band position to be unaffected");
        assertTrue(hook.bandDeployed(poolId, 0), "still recorded as deployed");
        assertFalse(hook.bandCompleted(poolId, 0), "and still live");
        assertEq(afterClaims.ladderInventoryRemaining, before.ladderInventoryRemaining, "ladder supply untouched");
        assertEq(afterClaims.carriedInventory, before.carriedInventory, "carry untouched");
        assertEq(afterClaims.milestoneFundAccrued, before.milestoneFundAccrued, "milestone fund untouched");

        assertEq(_fullRangeLiquidity(), fullRangeBefore, "the full-range position's liquidity is unchanged");
        assertEq(afterClaims.fullRangeLiquidity, before.fullRangeLiquidity, "in the hook's record too");
        assertEq(token.balanceOf(HOOK_ADDR), hookTokensBefore, "no token left hook custody at all");
    }

    // --- Scenario: Band-boundary trading cannot extract beyond band prices ---

    /// @dev A band is a one-sided limit order over a known price range, so what it can be filled at is
    /// bounded by that range and nothing a trader does changes it. Asserted against the range's own
    /// endpoints: the quote the band realises is at least its inventory valued at the band's floor price and
    /// at most its inventory valued at the ceiling, band fees aside.
    function test_bandBoundaryTradingCannotExtractBeyondBandPrices() public {
        Band memory b = _deployBand(0);
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(b.lower, b.upper);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // Sweep the band with an attacker's buy, so the fills are theirs and the harvest is measured on them.
        vm.recordLogs();
        attacker.swapToLimit(key, true, -500_000 ether, _sqrtAtLevel(b.upper + 200));
        uint256 quote = _harvestedQuoteFromLogs(vm.getRecordedLogs());

        assertGt(quote, 0, "the band was filled and harvested");

        // Level is `-tick`, so the band's *floor* token price is its upper tick and its ceiling is its lower
        // tick. Quote per token is `1 / sqrtPrice^2`, so the worst case divides by the larger sqrt twice.
        uint256 atFloorPrice =
            FullMath.mulDiv(FullMath.mulDiv(b.inventory, FixedPoint96.Q96, sqrtUpper), FixedPoint96.Q96, sqrtUpper);
        uint256 atCeilingPrice =
            FullMath.mulDiv(FullMath.mulDiv(b.inventory, FixedPoint96.Q96, sqrtLower), FixedPoint96.Q96, sqrtLower);

        assertGe(quote, atFloorPrice, "no part of the inventory was sold below the band's floor price");
        // The only thing that can push the realised quote above the ceiling valuation is the band's own swap
        // fees, which are earned rather than extracted, so a small allowance covers them.
        assertLe(quote, atCeilingPrice + atCeilingPrice / 20, "and none above its ceiling, band fees aside");
        assertLt(atFloorPrice, atCeilingPrice, "the two bounds really do bracket a range");
    }

    /// @dev The sandwich a band-boundary attacker would want: buy through the band, then sell straight back.
    /// It loses money, because the round trip pays the pool spread twice and the band's own price range is
    /// the best fill available in either direction.
    function test_sandwichingABandDeploymentIsUnprofitable() public {
        Band memory b = _deployBand(0);

        uint256 ethBefore = address(attacker).balance;
        uint256 tokensBefore = token.balanceOf(address(attacker));

        attacker.swapToLimit(key, true, -500_000 ether, _sqrtAtLevel(b.upper + 200));
        uint256 bought = token.balanceOf(address(attacker)) - tokensBefore;
        assertGt(bought, 0, "the attacker did fill against the band");

        // Straight back out, selling everything the sweep bought. A sell moves the price the other way, so
        // its limit is the top of tick space rather than the bottom.
        attacker.swapToLimit(key, false, -int256(bought), TickMath.MAX_SQRT_PRICE - 1);

        assertEq(token.balanceOf(address(attacker)), tokensBefore, "the attacker is flat in token again");
        assertLt(address(attacker).balance, ethBefore, "and out of pocket in ETH");
    }

    // --- Salt disjointness: bands must never collide with curves or the full range ---

    /// @dev Not a spec scenario, but the mechanism three of the scenarios above rest on. {MilestoneBase}
    /// recomputes every position salt rather than storing one, and a band, a curve position and the
    /// full-range position all have the same owner and can span overlapping ranges — so the salt is the only
    /// thing keeping "burn this curve" from reaching a band, or a harvest from reaching the locked
    /// full-range position. Under Decision 17's single nested curve a curve salt is just its index, so the
    /// families are separated by the top bit alone.
    function test_bandSaltsCannotCollideWithCurveOrFullRangeSalts() public view {
        assertEq(uint256(hook.FULL_RANGE_SALT()) >> 255, 0, "the full-range salt leaves the tag bit clear");

        uint256 positions = template.curvePositions;
        for (uint256 i = 0; i < positions; i++) {
            assertEq(uint256(hook.curvePositionSalt(i)) >> 255, 0, "curve salts leave it clear too");
            assertTrue(hook.curvePositionSalt(i) != hook.FULL_RANGE_SALT(), "and none of them is the full-range salt");
        }

        uint256 bands = uint256(template.coreBandCount) + uint256(template.maxFeeFundedBands);
        for (uint256 i = 0; i < bands; i++) {
            assertEq(uint256(hook.bandSalt(i)) >> 255, 1, "band salts set the tag bit");
            assertTrue(hook.bandSalt(i) != hook.FULL_RANGE_SALT(), "so no band salt can be the full-range salt");
            if (i < positions) {
                assertTrue(hook.bandSalt(i) != hook.curvePositionSalt(i), "nor a curve salt of the same index");
            }
            if (i > 0) {
                assertTrue(hook.bandSalt(i) != hook.bandSalt(i - 1), "and they stay distinct per index");
            }
        }
    }
}
