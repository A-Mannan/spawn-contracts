// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {MilestoneColdPaths} from "../../src/MilestoneColdPaths.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {CurveLib} from "../../src/libraries/CurveLib.sol";
import {LadderLib} from "../../src/libraries/LadderLib.sol";
import {LaunchConfigLib} from "../../src/libraries/LaunchConfigLib.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {LaunchConfig, LiveBand, Phase, PoolState, WAD} from "../../src/types/LaunchTypes.sol";
import {TestRouter} from "./BondingCurve.t.sol";

/// @notice A swapper that reverts *after* its swap has executed, so the harvest the swap triggered is
/// unwound along with it.
///
/// @dev Nothing in the protocol can produce this on its own — the harvest's own nested interactions are
/// the buyback swap and the LP donation, both of which are settled before the frame ends. This stands in
/// for an integrator whose own callback fails downstream of the hook's work, which is the only shape a
/// "reverting nested interaction" can actually take.
contract RevertingSwapper is IUnlockCallback {
    IPoolManager public immutable manager;

    error Deliberate();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swapThenRevert(PoolKey memory key, int256 amountSpecified, uint160 limit) external {
        manager.unlock(abi.encode(key, amountSpecified, limit));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, int256 amountSpecified, uint160 limit) = abi.decode(data, (PoolKey, int256, uint160));

        manager.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            ""
        );

        // The swap succeeded and the hook harvested inside it. Failing here is what proves the harvest's
        // storage writes and its transient lock both unwind with the transaction.
        revert Deliberate();
    }
}

/// @notice A creator that cannot receive ETH, used to prove harvest proceeds are credited rather than paid.
contract RejectingCreator {
    receive() external payable {
        revert("no ETH");
    }
}

/// @notice Unit tests for task group 9 — milestone harvest: completion, settlement, and routing.
///
/// @dev Covers the `milestone-ladder` harvest scenarios, the `revenue-claims` harvest accrual, and the
/// reentrancy guarantees around the nested buyback. Band deployment itself is covered by
/// `MilestoneLadder.t.sol`; what is asserted here begins once a band is live.
contract MilestoneHarvestTest is Test {
    using StateLibrary for IPoolManager;

    address internal constant HOOK_ADDR = address(uint160((uint160(0xBEEF) << 20) | 15040));
    address internal constant PROTOCOL_ADMIN = address(0xADD1);
    address internal constant PROTOCOL_RECIPIENT = address(0xFEE5);
    address internal constant CREATOR = address(0xC0FFEE);

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    PoolManager internal manager;
    MilestoneHook internal hook;
    RevenueNFT internal nft;
    LaunchSupport internal support;
    TestRouter internal router;

    PoolId internal poolId;
    PoolKey internal key;
    MilestoneToken internal token;

    int24 internal graduationLevel;

    /// @dev What a harvest reported, reassembled from its two events.
    struct Harvest {
        bool seen;
        uint32 index;
        uint256 quoteProceeds;
        uint256 tokenResidue;
        uint32 completedMilestones;
        uint256 creatorAmount;
        uint256 buybackQuote;
        uint256 tokensBurned;
        uint256 protocolAmount;
        uint256 lpAmount;
    }

    function setUp() public {
        _deployAndLaunch(CREATOR, 0.2e18, 0.1e18);
    }

    // --- Setup helpers ---

    /// @dev A launch with a chosen creator and a chosen buyback/LP division of the harvest split. The
    /// creator and protocol shares are held at the defaults so the two configurable tests differ in one
    /// variable only.
    function _deployAndLaunch(address creator, uint64 buybackWad, uint64 lpWad) internal {
        manager = new PoolManager(address(this));
        nft = new RevenueNFT();
        support = new LaunchSupport();

        MilestoneColdPaths coldPaths = new MilestoneColdPaths(IPoolManager(address(manager)), nft, support);

        deployCodeTo(
            "MilestoneHook.sol:MilestoneHook",
            abi.encode(IPoolManager(address(manager)), nft, support, coldPaths, PROTOCOL_ADMIN, PROTOCOL_RECIPIENT),
            HOOK_ADDR
        );
        hook = MilestoneHook(payable(HOOK_ADDR));
        nft.setMinter(HOOK_ADDR);
        router = new TestRouter(IPoolManager(address(manager)));

        MilestoneBase.LaunchParams memory p;
        p.name = "Milestone";
        p.symbol = "MILE";
        p.config = LaunchConfigLib.defaults(SUPPLY);
        p.config.harvestSplit.buybackWad = buybackWad;
        p.config.harvestSplit.lpWad = lpWad;
        p.curves = CurveLib.defaultCurves();

        vm.prank(creator);
        (PoolId id, address tokenAddr, PoolKey memory k) = hook.launch(p);
        poolId = id;
        key = k;
        token = MilestoneToken(tokenAddr);

        vm.deal(address(router), 100_000_000 ether);
        vm.warp(block.timestamp + 61);

        int24 farLevel = hook.launchConfig(poolId).farLevel;
        router.swapToLimit(key, true, -10_000 ether, TickMath.getSqrtPriceAtTick(Orientation.toTick(farLevel)));
        hook.graduate(key);
        require(hook.poolPhase(poolId) == Phase.GRADUATED, "did not graduate");

        graduationLevel = hook.poolState(poolId).graduationLevel;
    }

    // --- Price helpers ---

    function _level() internal view returns (int24) {
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
        return Orientation.toLevel(tick);
    }

    function _buyToLevel(int24 target) internal {
        router.swapToLimit(key, true, -50_000_000 ether, TickMath.getSqrtPriceAtTick(Orientation.toTick(target)));
    }

    function _sellToLevel(int24 target) internal {
        uint256 balance = token.balanceOf(address(router));
        router.swapToLimit(key, false, -int256(balance), TickMath.getSqrtPriceAtTick(Orientation.toTick(target)));
    }

    function _bandLevels(uint256 index) internal view returns (int24 lower, int24 upper) {
        bool exists;
        (lower, upper, exists) = LadderLib.bandLevels(hook.launchConfig(poolId), graduationLevel, index);
        require(exists, "band out of range");
    }

    function _bandLiquidity(uint256 index) internal view returns (uint128) {
        (int24 lower, int24 upper) = _bandLevels(index);
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(lower, upper);
        return IPoolManager(address(manager)).getPositionLiquidity(
            poolId, Position.calculatePositionKey(HOOK_ADDR, tickLower, tickUpper, hook.bandSalt(uint32(index)))
        );
    }

    /// @dev Deploys band `index` and leaves the price one level below it, ready to be crossed.
    function _deployBand(uint256 index) internal returns (LiveBand memory band) {
        LaunchConfig memory config = hook.launchConfig(poolId);
        (int24 lower,) = _bandLevels(index);

        _buyToLevel(lower - config.deployWindowLevels / 2);
        require(!hook.liveBand(poolId).deployed, "deployed too early");
        _buyToLevel(lower - 1);

        band = hook.liveBand(poolId);
        require(band.deployed && band.index == uint32(index), "band did not deploy");
    }

    /// @dev The quote a band's position returns as principal alone, with no accrued fees, once the price
    /// has cleared its top. Exactly v4's own conversion, rounding down as a burn does.
    function _bandPrincipalQuote(LiveBand memory band) internal pure returns (uint256) {
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(band.levelLower, band.levelUpper);
        return SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), band.liquidity, false
        );
    }

    // --- Log helpers ---

    function _harvestFromLogs(Vm.Log[] memory logs) internal pure returns (Harvest memory h) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MilestoneBase.MilestoneHarvested.selector) {
                h.seen = true;
                h.index = uint32(uint256(logs[i].topics[2]));
                (h.quoteProceeds, h.tokenResidue, h.completedMilestones) =
                    abi.decode(logs[i].data, (uint256, uint256, uint32));
            } else if (logs[i].topics[0] == MilestoneBase.HarvestRouted.selector) {
                (h.creatorAmount, h.buybackQuote, h.tokensBurned, h.protocolAmount, h.lpAmount) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            }
        }
    }

    function _count(Vm.Log[] memory logs, bytes32 selector) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == selector) n++;
        }
    }

    /// @dev Buys to `target` and returns the harvest that swap performed, if any.
    function _buyAndCapture(int24 target) internal returns (Harvest memory, Vm.Log[] memory) {
        vm.recordLogs();
        _buyToLevel(target);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        return (_harvestFromLogs(logs), logs);
    }

    // --- Scenario: Crossing the band top completes the milestone ---

    function test_crossingTheBandTopCompletesTheMilestone() public {
        LiveBand memory band = _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        (Harvest memory h,) = _buyAndCapture(upper + 200);

        assertGt(_level(), upper, "the price cleared the band's top");
        assertTrue(h.seen, "the milestone was harvested");
        assertEq(h.index, 0, "it was band 0");
        assertGt(h.quoteProceeds, 0, "the position returned quote");
        assertEq(h.completedMilestones, 1, "one milestone complete");

        PoolState memory state = hook.poolState(poolId);
        assertFalse(state.liveBand.deployed, "the band is retired");
        assertEq(state.completedMilestones, 1, "recorded in state");
        assertEq(state.bandCursor, band.index + 1, "the cursor advanced to the next band");
        assertEq(_bandLiquidity(0), 0, "the position was burned");
    }

    /// @dev The band's token inventory left the pool for the buyer, and the quote it fetched came back to
    /// the hook rather than staying stranded in the manager.
    ///
    /// Custody is a claim rather than raw ETH, because this runs inside the crossing swap's callback and the
    /// swapper has not paid yet — see design Decision 13. The claim is currency0's, so its id is 0.
    function test_harvestTakesTheQuoteIntoHookCustody() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        uint256 claimBefore = manager.balanceOf(HOOK_ADDR, 0);
        (Harvest memory h,) = _buyAndCapture(upper + 200);

        // Everything except the buyback spend and the donated LP share stays in the hook's custody, which
        // is what the creator and protocol ledgers are paid from.
        assertEq(
            manager.balanceOf(HOOK_ADDR, 0) - claimBefore,
            h.quoteProceeds - h.buybackQuote - h.lpAmount,
            "custody rose by exactly the credited shares"
        );
        assertEq(
            manager.balanceOf(HOOK_ADDR, 0) - claimBefore,
            h.creatorAmount + h.protocolAmount,
            "which is creator + protocol"
        );
        // And the manager really holds what the claim promises, so redemption cannot come up short.
        assertGe(address(manager).balance, manager.balanceOf(HOOK_ADDR, 0), "the claim is fully backed");
    }

    // --- Scenario: Partial fill does not complete the milestone ---

    function test_partialFillDoesNotCompleteTheMilestone() public {
        LiveBand memory band = _deployBand(0);
        (int24 lower, int24 upper) = _bandLevels(0);

        // Halfway into the band: some inventory sold, the top never reached.
        (Harvest memory h,) = _buyAndCapture(lower + (upper - lower) / 2);

        assertFalse(h.seen, "no harvest");
        assertGt(_level(), lower, "the price is inside the band");
        assertLt(_level(), upper, "but has not cleared its top");

        PoolState memory state = hook.poolState(poolId);
        assertTrue(state.liveBand.deployed, "the band is still live");
        assertEq(state.liveBand.index, 0, "and still band 0");
        assertEq(state.completedMilestones, 0, "nothing completed");
        assertEq(state.bandCursor, 0, "the cursor has not moved");
        assertEq(_bandLiquidity(0), band.liquidity, "the position is untouched");
    }

    /// @dev The boundary itself, walked rather than asserted at one point. Completion and "the price
    /// reached the band's top" must be the same condition at every stop, which is where an off-by-one
    /// would show up in either direction.
    function test_completionTracksTheBandTopExactly() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        bool completed;
        for (int24 target = upper - 6; target <= upper && !completed; target += 2) {
            _buyToLevel(target);
            completed = hook.poolState(poolId).completedMilestones == 1;

            assertEq(completed, _level() >= upper, "completion and reaching the top are one condition");
        }
        assertTrue(completed, "walking up to the top does complete it");
    }

    // --- Scenario: Band swap fees fold into the harvest ---

    function test_bandSwapFeesFoldIntoTheHarvest() public {
        LiveBand memory band = _deployBand(0);
        (int24 lower, int24 upper) = _bandLevels(0);
        uint256 principal = _bandPrincipalQuote(band);

        // Churn inside the band so it earns real fees before being crossed. Each of these trades against
        // the band's own liquidity, so the fee lands on the band position rather than only on the full
        // range, and the band is never cleared.
        _buyToLevel(lower + (upper - lower) / 2);
        _sellToLevel(lower + 10);
        _buyToLevel(upper - 10);
        _sellToLevel(lower + 20);
        assertEq(hook.poolState(poolId).completedMilestones, 0, "still unharvested");

        (Harvest memory h,) = _buyAndCapture(upper + 200);

        assertTrue(h.seen, "harvested");
        // Principal is the whole range converted to quote. Anything above it can only be accrued fees,
        // and there is no separate collection step for them: the burn returns both at once.
        assertGt(h.quoteProceeds, principal, "the harvest carries the band's fees on top of its principal");
    }

    /// @dev With no churn the harvest is principal plus only the fees of the crossing swap itself, so the
    /// same comparison still holds while being much tighter. Together with the test above this shows the
    /// fee component scales with band activity rather than being a constant.
    function test_harvestIsNeverLessThanPrincipal() public {
        LiveBand memory band = _deployBand(0);
        (, int24 upper) = _bandLevels(0);
        uint256 principal = _bandPrincipalQuote(band);

        (Harvest memory h,) = _buyAndCapture(upper + 200);

        assertGe(h.quoteProceeds, principal, "never short of principal");
    }

    // --- Scenario: A completed band cannot be harvested again ---

    function test_aCompletedBandCannotBeHarvestedAgain() public {
        _deployBand(0);
        (, int24 upper0) = _bandLevels(0);
        (int24 lower1,) = _bandLevels(1);

        _buyToLevel(upper0 + 200);
        assertEq(hook.poolState(poolId).completedMilestones, 1, "band 0 complete");

        // More buying, staying below band 1's deploy window so no second band enters the picture.
        LaunchConfig memory config = hook.launchConfig(poolId);
        vm.recordLogs();
        _buyToLevel(lower1 - config.deployWindowLevels - 100);
        _buyToLevel(lower1 - config.deployWindowLevels - 50);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_count(logs, MilestoneBase.MilestoneHarvested.selector), 0, "no second harvest");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "still exactly one");
        assertEq(_bandLiquidity(0), 0, "the position stays burned");
    }

    // --- Scenario: Price falling back does not un-complete a band ---

    function test_priceFallingBackDoesNotUncompleteABand() public {
        _deployBand(0);
        (int24 lower0, int24 upper0) = _bandLevels(0);

        _buyToLevel(upper0 + 200);
        uint256 creatorAfterHarvest = hook.creatorClaimable(poolId);
        assertEq(hook.poolState(poolId).completedMilestones, 1, "band 0 complete");

        // All the way back below the band, then up again to just under its old top.
        vm.recordLogs();
        _sellToLevel(graduationLevel + 100);
        _buyToLevel(lower0 - 50);
        _buyToLevel(upper0 - 5);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_count(logs, MilestoneBase.MilestoneHarvested.selector), 0, "nothing re-harvested");
        assertEq(_count(logs, MilestoneBase.BandDeployed.selector), 0, "and band 0 was not re-minted");

        PoolState memory state = hook.poolState(poolId);
        assertEq(state.completedMilestones, 1, "the count never falls");
        assertGe(state.bandCursor, 1, "nor does the cursor");
        assertEq(_bandLiquidity(0), 0, "no position came back");
        assertEq(hook.creatorClaimable(poolId), creatorAfterHarvest, "and nothing was paid twice");
    }

    // --- Scenario: Shares are distributed per configuration ---

    function test_sharesAreDistributedPerConfiguration() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 protocolBefore = hook.protocolClaimable(poolId);

        (Harvest memory h,) = _buyAndCapture(upper + 200);

        LaunchConfig memory config = hook.launchConfig(poolId);
        assertEq(h.creatorAmount, (h.quoteProceeds * config.harvestSplit.creatorWad) / WAD, "creator wad");
        assertEq(h.protocolAmount, (h.quoteProceeds * config.harvestSplit.protocolWad) / WAD, "protocol wad");
        assertEq(h.buybackQuote, (h.quoteProceeds * config.harvestSplit.buybackWad) / WAD, "buyback wad");

        // Both ledgers were credited, not paid.
        assertEq(hook.creatorClaimable(poolId) - creatorBefore, h.creatorAmount, "creator ledger");
        assertEq(hook.protocolClaimable(poolId) - protocolBefore, h.protocolAmount, "protocol ledger");
    }

    // --- Scenario: Routed amounts sum to the harvest ---

    function test_routedAmountsSumToTheHarvest() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        (Harvest memory h,) = _buyAndCapture(upper + 200);

        assertTrue(h.seen, "harvested");
        assertEq(
            h.creatorAmount + h.buybackQuote + h.protocolAmount + h.lpAmount,
            h.quoteProceeds,
            "the four shares account for every wei"
        );
        // The LP share carries the division remainder, so it is the one that can exceed its own wad — by
        // at most three wei, one per flooring division.
        LaunchConfig memory config = hook.launchConfig(poolId);
        uint256 nominalLp = (h.quoteProceeds * config.harvestSplit.lpWad) / WAD;
        assertGe(h.lpAmount, nominalLp, "LP is never short");
        assertLe(h.lpAmount - nominalLp, 3, "and over by dust at most");
    }

    /// @dev The LP share reaches the full-range position in the harvest itself. It arrives as fee growth
    /// rather than principal — harvest proceeds are quote-only, so there is no token side to pair — which
    /// is why the position's liquidity is unchanged while what it is owed has risen.
    function test_lpShareIsCreditedToTheFullRangePosition() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        PoolState memory before = hook.poolState(poolId);
        bytes32 positionKey = Position.calculatePositionKey(
            HOOK_ADDR, before.fullRangeTickLower, before.fullRangeTickUpper, hook.FULL_RANGE_SALT()
        );

        (Harvest memory h, Vm.Log[] memory logs) = _buyAndCapture(upper + 200);
        assertGt(h.lpAmount, 0, "there was an LP share to route");

        // The donation is the mechanism, and it is quote-only: there is no token side to pair it with.
        uint256 donated0;
        uint256 donated1;
        uint256 donations;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != IPoolManager.Donate.selector) continue;
            donations++;
            (donated0, donated1) = abi.decode(logs[i].data, (uint256, uint256));
        }
        assertEq(donations, 1, "one donation, from the harvest");
        assertEq(donated0, h.lpAmount, "of exactly the LP share");
        assertEq(donated1, 0, "and nothing on the token side");

        // At donate time the full-range position is the pool's only in-range liquidity — the curves were
        // burned at graduation and the one band that could have been live was just retired — so the credit
        // is entirely its own. It arrives as fee growth rather than principal, which is why its liquidity
        // is unchanged while the pool owes it more quote than before.
        (uint128 liquidityAfter,,) = IPoolManager(address(manager)).getPositionInfo(poolId, positionKey);
        assertEq(liquidityAfter, before.fullRangeLiquidity, "its principal is untouched, as the design says");
        assertGt(liquidityAfter, 0, "and it is a real position, so the credit had somewhere to land");
    }

    // --- Scenario: Creator proceeds are not pushed ---

    function test_creatorProceedsAreNotPushed() public {
        RejectingCreator creator = new RejectingCreator();
        _deployAndLaunch(address(creator), 0.2e18, 0.1e18);

        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        // A creator that reverts on receive must not be able to fail the swap that completed its
        // milestone. If any part of the harvest pushed ETH, this call would revert.
        (Harvest memory h,) = _buyAndCapture(upper + 200);

        assertTrue(h.seen, "the harvest went through");
        assertGt(h.creatorAmount, 0, "there was a creator share");
        assertEq(address(creator).balance, 0, "nothing was pushed");
        assertGe(hook.creatorClaimable(poolId), h.creatorAmount, "it is sitting in the ledger instead");
    }

    /// @dev `revenue-claims`: "Harvest creator share accrues". The credit is attributed to the harvest and
    /// is claimable by the revenue NFT holder like any other accrual.
    function test_harvestCreatorShareAccruesAndIsClaimable() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        vm.recordLogs();
        _buyToLevel(upper + 200);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Harvest memory h = _harvestFromLogs(logs);

        // The accrual names its source, so an indexer can attribute revenue without inferring it.
        bool sawHarvestAccrual;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.CreatorAccrued.selector) continue;
            (uint256 amount, uint8 source) = abi.decode(logs[i].data, (uint256, uint8));
            if (source == uint8(MilestoneBase.AccrualSource.MILESTONE_HARVEST) && amount == h.creatorAmount) {
                sawHarvestAccrual = true;
            }
        }
        assertTrue(sawHarvestAccrual, "credited with the harvest as its source");

        uint256 claimable = hook.creatorClaimable(poolId);
        assertGe(claimable, h.creatorAmount, "the harvest share is claimable");

        vm.prank(CREATOR);
        uint256 paid = hook.claimCreator(poolId);

        assertEq(paid, claimable, "the holder claims the whole balance");
        assertEq(CREATOR.balance, claimable, "and receives it");
        assertEq(hook.creatorClaimable(poolId), 0, "the ledger is cleared");
    }

    /// @dev Harvest proceeds are claimable as real ETH even though the harvest never produced any — they
    /// were minted as a claim on the manager (design Decision 13), and the claim path redeems it.
    ///
    /// This is not a test that merely happens to take that path. The hook's raw ETH and its ledgers both
    /// come from the graduation split — it retains exactly what it accrued there — so after a harvest the
    /// ledgers owe strictly more real ETH than the hook holds. Draining both therefore *must* redeem, and
    /// must redeem exactly the shortfall and no more.
    function test_claimsRedeemTheHarvestClaimWhenRawEthIsShort() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);
        _buyAndCapture(upper + 200);

        uint256 owed = hook.creatorClaimable(poolId) + hook.protocolClaimable(poolId);
        uint256 rawBefore = HOOK_ADDR.balance;
        uint256 claimBefore = manager.balanceOf(HOOK_ADDR, 0);
        assertGt(owed, rawBefore, "the ledgers owe more ETH than the hook holds, so redemption is forced");

        vm.prank(CREATOR);
        uint256 toCreator = hook.claimCreator(poolId);
        vm.prank(PROTOCOL_RECIPIENT);
        uint256 toProtocol = hook.claimProtocol(poolId);

        assertEq(toCreator + toProtocol, owed, "both ledgers paid in full");
        assertEq(CREATOR.balance, toCreator, "the creator holds real ETH, not a claim");
        assertEq(PROTOCOL_RECIPIENT.balance, toProtocol, "and so does the protocol");
        assertEq(claimBefore - manager.balanceOf(HOOK_ADDR, 0), owed - rawBefore, "redeemed exactly the shortfall");
        assertEq(HOOK_ADDR.balance, 0, "nothing was redeemed that was not needed, and nothing stranded");
    }

    // --- Scenario: Buyback reduces total supply ---

    function test_buybackReducesTotalSupply() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        uint256 supplyBefore = token.totalSupply();
        uint256 hookTokensBefore = token.balanceOf(HOOK_ADDR);

        (Harvest memory h, Vm.Log[] memory logs) = _buyAndCapture(upper + 200);

        assertGt(h.buybackQuote, 0, "the buyback spent its share");
        assertGt(h.tokensBurned, 0, "and bought something to burn");
        assertEq(supplyBefore - token.totalSupply(), h.tokensBurned, "supply fell by exactly what was burned");
        assertEq(token.balanceOf(HOOK_ADDR), hookTokensBefore, "nothing bought was retained");

        // Two swaps in this transaction: the trader's, and the hook's buyback nested inside it.
        assertEq(_count(logs, IPoolManager.Swap.selector), 2, "the buyback is a real swap");
    }

    // --- Scenario: A zero buyback share performs no swap ---

    function test_zeroBuybackSharePerformsNoSwap() public {
        // The buyback's 20% moved to the LP share, so the split still sums to one and only the buyback
        // differs from the default configuration.
        _deployAndLaunch(CREATOR, 0, 0.3e18);

        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        uint256 supplyBefore = token.totalSupply();
        (Harvest memory h, Vm.Log[] memory logs) = _buyAndCapture(upper + 200);

        assertTrue(h.seen, "still harvested");
        assertEq(h.buybackQuote, 0, "nothing spent on a buyback");
        assertEq(h.tokensBurned, 0, "nothing burned");
        assertEq(token.totalSupply(), supplyBefore, "supply unchanged");
        assertEq(_count(logs, IPoolManager.Swap.selector), 1, "only the trader's own swap");

        // The remaining shares are routed normally.
        assertEq(h.creatorAmount + h.protocolAmount + h.lpAmount, h.quoteProceeds, "and everything still routed");
        assertGt(h.creatorAmount, 0, "creator share paid");
        assertGt(h.lpAmount, 0, "LP share compounded");
    }

    // --- Scenario: Nested buyback swap does not re-enter settlement ---

    function test_nestedBuybackSwapDoesNotReenterSettlement() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        (Harvest memory h, Vm.Log[] memory logs) = _buyAndCapture(upper + 200);

        assertGt(h.buybackQuote, 0, "the nested swap ran");
        // The buyback pushes the price further up, and it runs after the band has been retired and the
        // cursor advanced. Without the guard its own callbacks could deploy or skip bands mid-settlement,
        // or try to harvest a second time off the price it just moved.
        assertEq(_count(logs, MilestoneBase.MilestoneHarvested.selector), 1, "exactly one harvest");
        assertEq(_count(logs, MilestoneBase.BandDeployed.selector), 0, "the nested swap deployed nothing");
        assertEq(_count(logs, MilestoneBase.BandSkipped.selector), 0, "and skipped nothing");
        assertEq(hook.poolState(poolId).bandCursor, 1, "the cursor moved exactly one band");
        assertFalse(hook.liveBand(poolId).deployed, "no band was left live by the nested swap");
    }

    // --- Scenario: Guard does not leak across transactions ---

    function test_guardDoesNotLeakAcrossTransactions() public {
        _deployBand(0);
        (, int24 upper0) = _bandLevels(0);
        _buyToLevel(upper0 + 200);
        assertEq(hook.poolState(poolId).completedMilestones, 1, "first harvest done");

        // A separate transaction. If the settlement lock had survived the first harvest, every ladder and
        // harvest path would silently no-op from here on.
        _deployBand(1);
        (, int24 upper1) = _bandLevels(1);
        (Harvest memory h,) = _buyAndCapture(upper1 + 200);

        assertTrue(h.seen, "the second milestone harvested too");
        assertEq(h.index, 1, "band 1 this time");
        assertEq(h.completedMilestones, 2, "two complete");
        assertEq(hook.poolState(poolId).bandCursor, 2, "and the cursor kept moving");
    }

    // --- Scenario: Reverting nested interaction does not corrupt state ---

    function test_revertingNestedInteractionDoesNotCorruptState() public {
        LiveBand memory band = _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        PoolState memory before = hook.poolState(poolId);
        uint256 creatorBefore = hook.creatorClaimable(poolId);
        uint256 supplyBefore = token.totalSupply();

        RevertingSwapper swapper = new RevertingSwapper(IPoolManager(address(manager)));
        vm.deal(address(swapper), 100_000_000 ether);

        vm.expectRevert(RevertingSwapper.Deliberate.selector);
        swapper.swapThenRevert(key, -50_000_000 ether, TickMath.getSqrtPriceAtTick(Orientation.toTick(upper + 200)));

        // Everything the harvest wrote is gone with the transaction, including the burn.
        PoolState memory afterRevert = hook.poolState(poolId);
        assertEq(afterRevert.completedMilestones, before.completedMilestones, "no milestone recorded");
        assertEq(afterRevert.bandCursor, before.bandCursor, "cursor unchanged");
        assertTrue(afterRevert.liveBand.deployed, "the band is still live");
        assertEq(afterRevert.liveBand.index, 0, "and still band 0");
        assertEq(_bandLiquidity(0), band.liquidity, "its position is intact");
        assertEq(hook.creatorClaimable(poolId), creatorBefore, "nothing accrued");
        assertEq(token.totalSupply(), supplyBefore, "nothing burned");

        // And the lock did not survive: the same crossing now works normally.
        (Harvest memory h,) = _buyAndCapture(upper + 200);
        assertTrue(h.seen, "the harvest still works after the failed attempt");
        assertEq(h.index, 0, "on the band that was preserved");
    }

    // --- Scenario: Swaps succeed in both directions ---

    function test_swapsSucceedInBothDirections() public {
        _deployBand(0);
        (int24 lower, int24 upper) = _bandLevels(0);

        // Across the band, back below it, and across again — buys and sells either side of a harvest.
        _buyToLevel(upper + 200);
        _sellToLevel(lower - 200);
        _buyToLevel(lower - 100);
        _sellToLevel(graduationLevel + 100);
        _buyToLevel(upper + 300);

        assertEq(uint8(hook.poolPhase(poolId)), uint8(Phase.GRADUATED), "still graduated, nothing blocked");
        assertGe(hook.poolState(poolId).completedMilestones, 1, "and the milestone did complete");
    }

    // --- Scenario: In-band oscillation is permitted but cannot prevent completion ---

    function test_inBandOscillationIsPermittedButCannotPreventCompletion() public {
        LiveBand memory band = _deployBand(0);
        (int24 lower, int24 upper) = _bandLevels(0);

        // Repeated churn strictly inside the band. None of it may be rejected, and none of it may
        // complete the milestone either.
        for (uint256 i = 0; i < 4; i++) {
            _buyToLevel(upper - 5 - int24(int256(i)));
            _sellToLevel(lower + 5 + int24(int256(i)));

            assertEq(hook.poolState(poolId).completedMilestones, 0, "oscillation completes nothing");
            assertTrue(hook.liveBand(poolId).deployed, "and the band stays live throughout");
        }
        assertEq(_bandLiquidity(0), band.liquidity, "the position was never resized by the churn");

        // The band is still there to be crossed, so the churn delayed completion but could not prevent it.
        (Harvest memory h,) = _buyAndCapture(upper + 200);
        assertTrue(h.seen, "one crossing still completes it");
        assertEq(h.index, 0, "the same band that was churned");
    }

    // --- Scenario: No size or timing gate ---

    function test_noSizeGateOnTheHarvestingSwap() public {
        LiveBand memory band = _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        // Almost all of the band is sold by a large buy that stops just short of the top, leaving the
        // final few levels to a tiny one. Nothing about the harvest is conditioned on the size of the
        // swap that happens to trigger it, so the dust-sized buy settles the whole position.
        _buyToLevel(upper - 6);
        assertEq(hook.poolState(poolId).completedMilestones, 0, "not yet complete");

        (Harvest memory h,) = _buyAndCapture(upper);

        assertTrue(h.seen, "a minimal crossing harvests");
        assertGt(h.quoteProceeds, 0, "and settles the whole position");
        assertEq(_bandLiquidity(0), 0, "all of it, not the sliver this swap crossed");
        assertGt(band.liquidity, 0, "sanity: there was a position to settle");
    }

    function test_noTimingGateOnTheHarvestingSwap() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        // Straight after deployment, in the very next block.
        (Harvest memory h,) = _buyAndCapture(upper + 200);
        assertTrue(h.seen, "no minimum age before a band may complete");

        // And again after a long wait, on the next band.
        vm.warp(block.timestamp + 400 days);
        vm.roll(block.number + 1);
        _deployBand(1);
        (, int24 upper1) = _bandLevels(1);
        (Harvest memory h1,) = _buyAndCapture(upper1 + 200);

        assertTrue(h1.seen, "and no maximum either");
        assertEq(h1.index, 1, "band 1 completed");
    }

    function test_noCallerGateOnTheHarvestingSwap() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        // A different swapper entirely, which has never touched this pool and did not deploy the band it
        // is about to complete. Nothing about the harvest is conditioned on who triggers it.
        TestRouter stranger = new TestRouter(IPoolManager(address(manager)));
        vm.deal(address(stranger), 100_000_000 ether);

        vm.recordLogs();
        stranger.swapToLimit(key, true, -50_000_000 ether, TickMath.getSqrtPriceAtTick(Orientation.toTick(upper + 200)));
        Harvest memory h = _harvestFromLogs(vm.getRecordedLogs());

        assertTrue(h.seen, "a stranger's swap harvests just the same");
        assertEq(h.index, 0, "band 0");
        assertEq(hook.poolState(poolId).completedMilestones, 1, "one milestone complete");
        // And the proceeds went where the configuration says, not to whoever happened to trigger it.
        assertGt(hook.creatorClaimable(poolId), 0, "the creator is still the beneficiary");
        assertGt(token.balanceOf(address(stranger)), 0, "the stranger got only what it bought");
    }

    /// @dev The harvest never rewrites the swapper's deltas: the hook declares no `afterSwapReturnDelta`
    /// permission, so a trader's fill is identical whether or not their swap happened to trigger one.
    function test_harvestDoesNotChangeWhatTheTraderReceives() public {
        _deployBand(0);
        (, int24 upper) = _bandLevels(0);

        uint256 routerEthBefore = address(router).balance;
        uint256 routerTokensBefore = token.balanceOf(address(router));

        (Harvest memory h, Vm.Log[] memory logs) = _buyAndCapture(upper + 200);
        assertTrue(h.seen, "a harvest did occur");

        // Find the trader's own swap — the first of the two — and check the router's balances moved by
        // exactly its deltas, with nothing added or withheld by the hook.
        int128 traderAmount0;
        int128 traderAmount1;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != IPoolManager.Swap.selector) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != address(router)) continue;
            (traderAmount0, traderAmount1,,,,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            break;
        }

        assertLt(traderAmount0, 0, "the trader paid quote");
        assertGt(traderAmount1, 0, "and received token");
        assertEq(routerEthBefore - address(router).balance, uint256(uint128(-traderAmount0)), "paid exactly its delta");
        assertEq(
            token.balanceOf(address(router)) - routerTokensBefore,
            uint256(uint128(traderAmount1)),
            "received exactly its delta"
        );
    }
}
