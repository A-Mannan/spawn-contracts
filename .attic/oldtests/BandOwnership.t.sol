// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {LiveBand, PoolState} from "../../src/types/LaunchTypes.sol";
import {SwapFeesFixture} from "./SwapFees.t.sol";
import {TestRouter} from "./BondingCurve.t.sol";

/// @notice Unit tests for task 11.3 — bands are hook-owned and externally immutable, and no claim path
/// reaches ladder inventory or the full-range position.
///
/// @dev These are negative claims, so each is made two ways where it can be: by exercising every entry point
/// a would-be extractor actually has, and by asserting the protocol state those entry points must not move.
/// The structural half of the same guarantee is covered by `make lock-check` and `make layout-check`, which
/// assert properties of the code's shape rather than of the paths a test happened to think of.
contract BandOwnershipTest is SwapFeesFixture {
    /// @dev A second router, so an attacker's attempts are distinguishable from the fixture's own trading.
    TestRouter internal attacker;

    function setUp() public override {
        super.setUp();

        attacker = new TestRouter(IPoolManager(address(manager)));
        vm.deal(address(attacker), 1_000_000 ether);
    }

    // --- Scenario: External band mutation is rejected ---

    function test_externalBandMutationIsRejected() public {
        LiveBand memory band = _deployBand(0);
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(band.levelLower, band.levelUpper);

        // Adding to the band's range, removing from it, and straddling it: all three are liquidity operations
        // on a range the hook owns, and the `beforeAddLiquidity`/`beforeRemoveLiquidity` guards admit only
        // `address(this)`, whatever the ticks and whatever the salt.
        vm.expectRevert();
        attacker.addLiquidity(key, tickLower, tickUpper, 1e18);

        vm.expectRevert();
        attacker.removeLiquidity(key, tickLower, tickUpper, -1e18);

        vm.expectRevert();
        attacker.addLiquidity(key, tickLower - 1_000, tickUpper + 1_000, 1e18);

        // Nothing moved.
        LiveBand memory after_ = hook.liveBand(poolId);
        assertEq(after_.liquidity, band.liquidity, "the band's liquidity is unchanged");
        assertEq(after_.levelLower, band.levelLower, "and it was not repriced");
        assertEq(after_.levelUpper, band.levelUpper, "at either bound");
        assertEq(_bandLiquidity(0), band.liquidity, "as v4 itself still reports");
    }

    function test_theCreatorIsNotPrivilegedOverABandEither() public {
        LiveBand memory band = _deployBand(0);
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(band.levelLower, band.levelUpper);

        TestRouter creatorRouter = new TestRouter(IPoolManager(address(manager)));
        vm.deal(address(creatorRouter), 1_000 ether);

        vm.prank(CREATOR);
        vm.expectRevert();
        creatorRouter.removeLiquidity(key, tickLower, tickUpper, -int256(uint256(band.liquidity)));

        assertEq(_bandLiquidity(0), band.liquidity, "the band is untouched");
    }

    /// @dev And the band is genuinely hook-owned rather than merely hook-created: v4 keys positions by owner,
    /// so the liquidity is recorded against the hook's address and nobody else's.
    function test_bandPositionsAreOwnedByTheHook() public {
        LiveBand memory band = _deployBand(0);

        assertEq(_bandLiquidity(0), band.liquidity, "the hook's own position holds it");
        assertGt(band.liquidity, 0, "and there is something to hold");
    }

    // --- Scenario: Creator cannot withdraw ladder inventory ---

    function test_creatorCannotWithdrawLadderInventory() public {
        _deployBand(0);

        // Give the creator something to claim, so the claim paths do real work rather than returning early.
        _sell(MEASURED_SELL);
        _collectAndCapture();

        PoolState memory before = hook.poolState(poolId);
        uint256 creatorTokensBefore = token.balanceOf(CREATOR);
        uint256 claimableTokens = hook.creatorClaimableTokens(poolId);
        assertGt(claimableTokens, 0, "there is a token balance to claim");
        assertGt(before.ladderInventoryRemaining, 0, "and ladder inventory sitting beside it");

        // Every entry point the creator has. None of them names an amount, so none can over-draw.
        vm.startPrank(CREATOR);
        hook.claimCreator(poolId);
        hook.claimCreatorTokens(poolId);
        hook.releaseDevBuy(poolId);
        vm.stopPrank();

        PoolState memory afterClaims = hook.poolState(poolId);
        assertEq(
            token.balanceOf(CREATOR) - creatorTokensBefore,
            claimableTokens,
            "the creator received exactly their accrued balance and nothing else"
        );
        assertEq(
            afterClaims.ladderInventoryRemaining, before.ladderInventoryRemaining, "undeployed ladder supply is intact"
        );
        assertEq(afterClaims.carriedInventory, before.carriedInventory, "as is the carry");
        assertEq(afterClaims.milestoneFundAccrued, before.milestoneFundAccrued, "and the milestone fund");
    }

    function test_noPrivilegedCallerCanReachLadderInventoryEither() public {
        _deployBand(0);
        PoolState memory before = hook.poolState(poolId);

        // The protocol's entire privileged surface is the recipient setter (Decision 10). Exercising it
        // cannot move a token.
        vm.prank(PROTOCOL_ADMIN);
        hook.setProtocolRecipient(STRANGER);

        PoolState memory afterAdmin = hook.poolState(poolId);
        assertEq(afterAdmin.ladderInventoryRemaining, before.ladderInventoryRemaining, "ladder supply intact");
        assertEq(afterAdmin.liveBand.liquidity, before.liveBand.liquidity, "the live band intact");
        assertEq(afterAdmin.fullRangeLiquidity, before.fullRangeLiquidity, "the full range intact");
    }

    // --- Scenario (revenue-claims): Claims cannot reach ladder inventory ---
    // --- Scenario (revenue-claims): Claims cannot reach the full-range position ---

    function test_claimsCannotReachLadderInventoryOrTheFullRangePosition() public {
        LiveBand memory band = _deployBand(0);

        // Accrue on both sides and in both currencies, so every ledger has something in it.
        _sell(MEASURED_SELL);
        _buy(MEASURED_BUY);
        _collectAndCapture();

        PoolState memory before = hook.poolState(poolId);
        uint128 fullRangeBefore = _fullRangeLiquidity();
        uint128 bandBefore = _bandLiquidity(0);

        uint256 creatorQuote = hook.creatorClaimable(poolId);
        uint256 creatorToken = hook.creatorClaimableTokens(poolId);
        uint256 protocolQuote = hook.protocolClaimable(poolId);
        uint256 protocolToken = hook.protocolClaimableTokens(poolId);
        assertGt(creatorQuote, 0, "the creator has ETH to claim");
        assertGt(creatorToken, 0, "and token");

        vm.startPrank(CREATOR);
        assertEq(hook.claimCreator(poolId), creatorQuote, "paid exactly the accrued ETH");
        assertEq(hook.claimCreatorTokens(poolId), creatorToken, "and exactly the accrued token");
        vm.stopPrank();

        vm.startPrank(PROTOCOL_RECIPIENT);
        assertEq(hook.claimProtocol(poolId), protocolQuote, "paid exactly the accrued ETH");
        assertEq(hook.claimProtocolTokens(poolId), protocolToken, "and exactly the accrued token");
        vm.stopPrank();

        // A second claim finds nothing: the ledgers are zeroed, not merely decremented.
        vm.prank(CREATOR);
        assertEq(hook.claimCreator(poolId), 0, "nothing left to claim");
        vm.prank(PROTOCOL_RECIPIENT);
        assertEq(hook.claimProtocolTokens(poolId), 0, "nothing left to claim");

        PoolState memory afterClaims = hook.poolState(poolId);
        assertEq(_bandLiquidity(0), bandBefore, "the deployed band is unaffected");
        assertEq(afterClaims.liveBand.liquidity, band.liquidity, "and still recorded as live");
        assertEq(afterClaims.ladderInventoryRemaining, before.ladderInventoryRemaining, "ladder supply untouched");
        assertEq(afterClaims.carriedInventory, before.carriedInventory, "carry untouched");
        assertEq(afterClaims.milestoneFundAccrued, before.milestoneFundAccrued, "milestone fund untouched");

        assertEq(_fullRangeLiquidity(), fullRangeBefore, "the full-range position's liquidity is unchanged");
        assertEq(afterClaims.fullRangeLiquidity, before.fullRangeLiquidity, "in the hook's record too");
        assertEq(afterClaims.pendingLpQuote, before.pendingLpQuote, "and its pending LP share is not claimable");
        assertEq(afterClaims.pendingLpToken, before.pendingLpToken, "in either currency");
    }

    // --- Scenario: Band-boundary trading cannot extract beyond band prices ---

    /// @dev A band is a one-sided limit order over a known price range, so what it can be filled at is
    /// bounded by that range and nothing a trader does changes it. Asserted against the range's own
    /// endpoints: the quote the band realises is at least its inventory valued at the band's floor price and
    /// at most its inventory valued at the ceiling, band fees aside.
    function test_bandBoundaryTradingCannotExtractBeyondBandPrices() public {
        LiveBand memory band = _deployBand(0);
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(band.levelLower, band.levelUpper);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // Sweep the band with an attacker's buy, so the fills are theirs and the harvest is measured on them.
        vm.recordLogs();
        (, int24 upper) = _bandLevels(0);
        attacker.swapToLimit(key, true, -500_000 ether, TickMath.getSqrtPriceAtTick(Orientation.toTick(upper + 200)));
        uint256 quote = _harvestedQuoteFromLogs(vm.getRecordedLogs());

        assertGt(quote, 0, "the band was filled and harvested");

        // Level is `-tick`, so the band's *floor* token price is its upper tick and its ceiling is its lower
        // tick. Quote per token is `1 / sqrtPrice^2`, so the worst case divides by the larger sqrt twice.
        uint256 atFloorPrice = FullMath.mulDiv(
            FullMath.mulDiv(band.tokenInventory, FixedPoint96.Q96, sqrtUpper), FixedPoint96.Q96, sqrtUpper
        );
        uint256 atCeilingPrice = FullMath.mulDiv(
            FullMath.mulDiv(band.tokenInventory, FixedPoint96.Q96, sqrtLower), FixedPoint96.Q96, sqrtLower
        );

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
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        uint256 ethBefore = address(attacker).balance;
        uint256 tokensBefore = token.balanceOf(address(attacker));

        attacker.swapToLimit(key, true, -500_000 ether, TickMath.getSqrtPriceAtTick(Orientation.toTick(upper + 200)));
        uint256 bought = token.balanceOf(address(attacker)) - tokensBefore;
        assertGt(bought, 0, "the attacker did fill against the band");

        // Straight back out, selling everything the sweep bought. A sell moves the price the other way, so
        // its limit is the top of tick space rather than the bottom.
        attacker.swapToLimit(key, false, -int256(bought), TickMath.MAX_SQRT_PRICE - 1);

        assertEq(token.balanceOf(address(attacker)), tokensBefore, "the attacker is flat in token again");
        assertLt(address(attacker).balance, ethBefore, "and out of pocket in ETH");
    }

    function _harvestedQuoteFromLogs(Vm.Log[] memory logs) private pure returns (uint256 quote) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.MilestoneHarvested.selector) {
                (quote,,) = abi.decode(logs[i].data, (uint256, uint256, uint32));
            }
        }
    }
}
