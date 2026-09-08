// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {Orientation} from "../../src/libraries/Orientation.sol";
import {Bounds, PoolState, ProtocolTemplate} from "../../src/types/LaunchTypes.sol";
import {TestRouter} from "../Fixtures.sol";

/// @notice The action surface the invariant campaign drives, across several concurrent pools.
///
/// @dev Everything the fuzzer is allowed to do lives here, and every action wraps its external call in
/// `try`/`catch`. That is not defensive noise: `fail_on_revert = false` makes the runner *silently skip*
/// a reverting handler call, so a revert would cost the sequence a step and say nothing. Catching it
/// instead lets the attempt/success counters prove the campaign is doing real work (see
/// {distinctActionsExercised}), which is what task 13.1's coverage clause asks for.
///
/// For the same reason **no assertion lives in this contract**. A handler-side `assert` reverts, the
/// runner skips the call, and the violation vanishes. Sequential properties — ascending deployment,
/// per-swap caps, monotone bitmaps, cross-pool immutability — are therefore recorded here as violation
/// *counters*, snapshotted around each action, and asserted by the `invariant_*` functions in
/// `LaunchpadInvariants.t.sol`.
contract LaunchpadHandler is CommonBase, StdUtils {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Widest level the pool's tick range can express, so a target level is always mintable.
    int24 internal constant MAX_LEVEL = Bounds.FULL_RANGE_TICK_BOUND;

    /// @dev One entry per externally callable action, indexing {actionAttempts} / {actionSuccesses}.
    enum Action {
        BUY,
        SELL,
        WARP,
        COLLECT_FEES,
        GRADUATE,
        CLAIM_CREATOR,
        CLAIM_PROTOCOL,
        RELEASE_DEV_BUY,
        TRANSFER_NFT,
        UNAUTHORISED_CLAIM
    }

    uint256 internal constant ACTION_COUNT = 10;

    /// @dev `token` and `creator` are cached rather than re-read per call: the fuzzer runs thousands of
    /// actions and every one of them touches both.
    struct Pool {
        PoolId id;
        PoolKey key;
        MilestoneToken token;
        address creator;
        uint256 initialSupply;
    }

    IPoolManager internal immutable manager;
    MilestoneHook internal immutable hook;
    RevenueNFT internal immutable nft;
    TestRouter internal immutable router;
    address internal immutable protocolRecipient;

    ProtocolTemplate internal template;
    Pool[] internal pools;
    address[] internal actors;

    // --- Call coverage (task 13.1) ---

    uint256[ACTION_COUNT] public actionAttempts;
    uint256[ACTION_COUNT] public actionSuccesses;

    uint256 public bandDeployments;
    uint256 public bandSkips;
    uint256 public bandHarvests;
    uint256 public curveDeployments;
    uint256 public graduations;
    uint256 public feeCollections;
    uint256 public feeSteps;
    uint256 public nftTransfers;
    uint256 public secondsElapsed;
    uint256 public creatorEthPaid;
    uint256 public protocolEthPaid;
    uint256 public devBuyTokensReleased;

    // --- Value ghosts, per pool index (task 13.2) ---

    /// @dev Summed `MilestoneHarvested.quoteProceeds`; {routedQuote} sums the four `HarvestRouted` legs.
    /// The two must agree exactly — the event doc promises any rounding shortfall is folded into `lpAmount`
    /// rather than dropped.
    mapping(uint256 => uint256) public harvestedQuote;
    mapping(uint256 => uint256) public routedQuote;

    /// @dev Summed `HarvestRouted.tokensBurned`. `MilestoneToken.burn` has exactly one call site — the
    /// buyback leg of a harvest — so this is the *only* way supply can fall, and it must reconcile against
    /// `initialSupply - totalSupply()`.
    mapping(uint256 => uint256) public tokensBurned;

    /// @dev Per-pool `BandSkipped` count. With the deployed-bit population count it reconstructs
    /// `nextBandIndex`, which is what makes "deployment order strictly ascending" checkable from state.
    mapping(uint256 => uint256) public bandSkipsOf;

    // --- Violations, asserted by the invariant contract (tasks 13.3, 13.4) ---

    uint256 public violationDeployOrder;
    uint256 public violationRedeployedCompletedBand;
    uint256 public violationBitmapCleared;
    uint256 public violationCompletionsRegressed;
    uint256 public violationFullRangeShrank;
    uint256 public violationClaimTouchedOtherLedger;
    uint256 public violationCrossPoolStateChanged;
    uint256 public violationCrossPoolCreatorChanged;
    uint256 public violationCrossPoolProtocolChanged;
    uint256 public violationUnauthorisedClaimSucceeded;

    uint256 public maxDeploysInOneSwap;
    uint256 public maxHarvestsInOneSwap;

    // --- Per-action snapshots ---

    uint256[] internal prevDeployedBands;
    uint256[] internal prevCompletedBands;
    uint32[] internal prevNextBandIndex;
    uint32[] internal prevCompletedMilestones;
    uint128[] internal prevFullRange;

    bytes32[] internal snapFingerprint;
    uint256[] internal snapCreatorClaimable;
    uint256[] internal snapProtocolClaimable;

    /// @dev The pool the action in flight targets. `type(uint256).max` means "none" — a time warp touches
    /// no pool, so every pool must come out of it byte-identical.
    uint256 internal actingPool;

    /// @param keys One entry per pool the campaign drives. Everything else about a pool — its id, token,
    /// creator, and minted supply — is derived, so the caller cannot hand over an inconsistent set.
    /// @param actors_ The addresses the fuzzer may route an NFT to or attempt an unauthorised claim from.
    constructor(
        IPoolManager manager_,
        MilestoneHook hook_,
        RevenueNFT nft_,
        TestRouter router_,
        address protocolRecipient_,
        PoolKey[] memory keys,
        address[] memory actors_
    ) {
        manager = manager_;
        hook = hook_;
        nft = nft_;
        router = router_;
        protocolRecipient = protocolRecipient_;
        template = hook_.template();

        for (uint256 i = 0; i < keys.length; i++) {
            PoolId id = keys[i].toId();
            MilestoneToken t = MilestoneToken(Currency.unwrap(keys[i].currency1));
            pools.push(
                Pool({
                    id: id,
                    key: keys[i],
                    token: t,
                    creator: hook_.poolState(id).creator,
                    initialSupply: t.initialSupply()
                })
            );

            prevDeployedBands.push(0);
            prevCompletedBands.push(0);
            prevNextBandIndex.push(0);
            prevCompletedMilestones.push(0);
            prevFullRange.push(0);
            snapFingerprint.push(bytes32(0));
            snapCreatorClaimable.push(0);
            snapProtocolClaimable.push(0);
        }

        for (uint256 i = 0; i < actors_.length; i++) {
            actors.push(actors_[i]);
        }

        // Seed the monotonicity baseline from live state rather than from zero: a pool graduated during
        // `setUp` already holds a full-range position and a non-zero cursor, and treating that as growth
        // would make the first action look like a violation.
        _refreshMonotonic();
    }

    // --- Actions ---

    /// @notice A buy, bounded to a target level a few rungs above spot rather than run to the extreme.
    /// @dev `swapToLimit` matters here: a plain exact-input swap of any size walks the price to the tick
    /// boundary, which would graduate every pool in the first few calls and leave the bonding-curve half
    /// of the lifecycle unexplored.
    function buy(uint256 poolSeed, uint256 ethSeed, uint256 levelSeed) external {
        uint256 i = _poolIndex(poolSeed);
        // Upper bound matched to the unit layer's known-sufficient budget: reaching band 0's floor is a
        // ~25% price move (`bandLevelSpacing` = 2235 levels), and a smaller cap would leave the whole
        // ladder unreachable by the campaign. The swap is limit-bounded, so a generous budget costs
        // nothing — it stops at the target level, not at the budget.
        uint256 ethIn = bound(ethSeed, 0.001 ether, 2_000 ether);
        if (address(router).balance < ethIn) return;

        int24 current = _levelOf(i);
        int24 target = _clampLevel(current + int24(uint24(bound(levelSeed, 1, 20_000))));
        if (target <= current) return;

        _begin(i);
        try router.swapToLimit(pools[i].key, true, -int256(ethIn), _sqrtAtLevel(target)) {
            _end(Action.BUY, true);
        } catch {
            _end(Action.BUY, false);
        }
    }

    /// @notice A sell, out of whatever the router bought earlier. Never fabricates a balance.
    function sell(uint256 poolSeed, uint256 tokenSeed, uint256 levelSeed) external {
        uint256 i = _poolIndex(poolSeed);
        uint256 held = pools[i].token.balanceOf(address(router));
        if (held == 0) return;

        uint256 tokensIn = bound(tokenSeed, 1, held);
        int24 current = _levelOf(i);
        int24 target = _clampLevel(current - int24(uint24(bound(levelSeed, 1, 20_000))));
        if (target >= current) return;

        _begin(i);
        try router.swapToLimit(pools[i].key, false, -int256(tokensIn), _sqrtAtLevel(target)) {
            _end(Action.SELL, true);
        } catch {
            _end(Action.SELL, false);
        }
    }

    /// @notice Advances the clock, which is what lets dev-buy vesting reach and pass its cliff.
    function warp(uint256 secondsSeed) external {
        uint256 delta = bound(secondsSeed, 1 hours, 45 days);

        _begin(type(uint256).max);
        vm.warp(block.timestamp + delta);
        secondsElapsed += delta;
        _end(Action.WARP, true);
    }

    /// @notice Permissionless fee collection and routing.
    function collectFees(uint256 poolSeed) external {
        uint256 i = _poolIndex(poolSeed);

        _begin(i);
        try hook.collectFees(pools[i].key) {
            _end(Action.COLLECT_FEES, true);
        } catch {
            _end(Action.COLLECT_FEES, false);
        }
    }

    /// @notice Permissionless graduation. Mostly reverts — auto-graduation (Decision 18) usually gets
    /// there first — and that is fine: the point is that calling it can never corrupt anything.
    function graduate(uint256 poolSeed) external {
        uint256 i = _poolIndex(poolSeed);

        _begin(i);
        try hook.graduate(pools[i].key) {
            _end(Action.GRADUATE, true);
        } catch {
            _end(Action.GRADUATE, false);
        }
    }

    /// @notice A creator claim by whoever currently holds the revenue NFT, which {transferRevenueNft}
    /// moves around under the campaign.
    function claimCreator(uint256 poolSeed) external {
        uint256 i = _poolIndex(poolSeed);
        address holder = nft.ownerOf(nft.tokenIdOf(pools[i].id));

        _begin(i);
        vm.prank(holder);
        try hook.claimCreator(pools[i].id) {
            _checkClaimIsolation(i, true);
            _end(Action.CLAIM_CREATOR, true);
        } catch {
            _end(Action.CLAIM_CREATOR, false);
        }
    }

    function claimProtocol(uint256 poolSeed) external {
        uint256 i = _poolIndex(poolSeed);

        _begin(i);
        vm.prank(protocolRecipient);
        try hook.claimProtocol(pools[i].id) {
            _checkClaimIsolation(i, false);
            _end(Action.CLAIM_PROTOCOL, true);
        } catch {
            _end(Action.CLAIM_PROTOCOL, false);
        }
    }

    function releaseDevBuy(uint256 poolSeed) external {
        uint256 i = _poolIndex(poolSeed);

        _begin(i);
        vm.prank(pools[i].creator);
        try hook.releaseDevBuy(pools[i].id) {
            _end(Action.RELEASE_DEV_BUY, true);
        } catch {
            _end(Action.RELEASE_DEV_BUY, false);
        }
    }

    /// @notice Sells the revenue stream. Creator claims follow the NFT; dev-buy vesting does not.
    function transferRevenueNft(uint256 poolSeed, uint256 toSeed) external {
        uint256 i = _poolIndex(poolSeed);
        uint256 tokenId = nft.tokenIdOf(pools[i].id);
        address holder = nft.ownerOf(tokenId);
        address to = actors[bound(toSeed, 0, actors.length - 1)];
        if (to == holder) return;

        _begin(i);
        vm.prank(holder);
        try nft.transferFrom(holder, to, tokenId) {
            nftTransfers += 1;
            _end(Action.TRANSFER_NFT, true);
        } catch {
            _end(Action.TRANSFER_NFT, false);
        }
    }

    /// @notice Claims attempted by an address entitled to neither ledger.
    /// @dev The success of this action is that both attempts *failed*; a success is recorded as a
    /// violation, not as a revert, precisely because the runner would swallow the revert.
    function unauthorisedClaim(uint256 poolSeed, uint256 actorSeed) external {
        uint256 i = _poolIndex(poolSeed);
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        address holder = nft.ownerOf(nft.tokenIdOf(pools[i].id));

        bool tried;
        _begin(i);

        if (actor != holder) {
            tried = true;
            vm.prank(actor);
            try hook.claimCreator(pools[i].id) {
                violationUnauthorisedClaimSucceeded += 1;
            } catch {}
        }
        if (actor != protocolRecipient) {
            tried = true;
            vm.prank(actor);
            try hook.claimProtocol(pools[i].id) {
                violationUnauthorisedClaimSucceeded += 1;
            } catch {}
        }

        _end(Action.UNAUTHORISED_CLAIM, tried);
    }

    // --- Bookkeeping ---

    /// @dev Snapshots every pool and starts recording logs. Paired with {_end} on both branches of the
    /// action's `try`, so a reverted attempt still closes the recorder and discards its logs — a reverted
    /// frame's events must never reach the ghost accounting.
    function _begin(uint256 i) private {
        actingPool = i;
        for (uint256 j = 0; j < pools.length; j++) {
            snapFingerprint[j] = _fingerprint(j);
            snapCreatorClaimable[j] = hook.creatorClaimable(pools[j].id);
            snapProtocolClaimable[j] = hook.protocolClaimable(pools[j].id);
        }
        vm.recordLogs();
    }

    function _end(Action a, bool ok) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        actionAttempts[uint256(a)] += 1;
        if (!ok) return;

        actionSuccesses[uint256(a)] += 1;
        _accountLogs(actingPool, logs, a);
        _checkCrossPool(actingPool);
        _refreshMonotonic();
    }

    /// @dev Every ghost the value and structural invariants read is derived here, from the action's own
    /// log. Post-transaction state cannot express multiplicity or ordering within a single swap, which is
    /// exactly what the per-swap caps and the ascending-deployment rule are about.
    function _accountLogs(uint256 i, Vm.Log[] memory logs, Action a) private {
        if (logs.length == 0) return;
        bool scoped = i < pools.length;

        uint256 deploys;
        uint256 harvests;
        bool seenDeploy;
        uint32 lastDeployed;

        for (uint256 n = 0; n < logs.length; n++) {
            bytes32 topic = logs[n].topics[0];

            if (topic == MilestoneBase.BandDeployed.selector) {
                uint32 index = uint32(uint256(logs[n].topics[2]));
                deploys += 1;
                bandDeployments += 1;

                if (seenDeploy && index <= lastDeployed) violationDeployOrder += 1;
                if (scoped) {
                    if (index < prevNextBandIndex[i]) violationDeployOrder += 1;
                    if (prevCompletedBands[i] & (uint256(1) << index) != 0) {
                        violationRedeployedCompletedBand += 1;
                    }
                }
                seenDeploy = true;
                lastDeployed = index;
            } else if (topic == MilestoneBase.MilestoneHarvested.selector) {
                (uint256 quote,,) = abi.decode(logs[n].data, (uint256, uint256, uint32));
                harvests += 1;
                bandHarvests += 1;
                harvestedQuote[i] += quote;
            } else if (topic == MilestoneBase.HarvestRouted.selector) {
                (uint256 creatorAmount, uint256 buyback, uint256 burned, uint256 protocolAmount, uint256 lp) =
                    abi.decode(logs[n].data, (uint256, uint256, uint256, uint256, uint256));
                routedQuote[i] += creatorAmount + buyback + protocolAmount + lp;
                tokensBurned[i] += burned;
            } else if (topic == MilestoneBase.BandSkipped.selector) {
                bandSkips += 1;
                bandSkipsOf[i] += 1;
            } else if (topic == MilestoneBase.CurvePositionsDeployed.selector) {
                curveDeployments += 1;
            } else if (topic == MilestoneBase.Graduated.selector) {
                graduations += 1;
            } else if (topic == MilestoneBase.FeesCollected.selector) {
                feeCollections += 1;
            } else if (topic == MilestoneBase.BaseFeeStepped.selector) {
                feeSteps += 1;
            } else if (topic == MilestoneBase.CreatorClaimed.selector) {
                creatorEthPaid += abi.decode(logs[n].data, (uint256));
            } else if (topic == MilestoneBase.ProtocolClaimed.selector) {
                protocolEthPaid += abi.decode(logs[n].data, (uint256));
            } else if (topic == MilestoneBase.DevBuyReleased.selector) {
                devBuyTokensReleased += abi.decode(logs[n].data, (uint256));
            }
        }

        // Only a swap is capped. A `collectFees` may create a fee-funded band, and graduation seeds the
        // full range; neither is bounded by the per-swap template limits.
        if (a == Action.BUY || a == Action.SELL) {
            if (deploys > maxDeploysInOneSwap) maxDeploysInOneSwap = deploys;
            if (harvests > maxHarvestsInOneSwap) maxHarvestsInOneSwap = harvests;
        }
    }

    /// @dev Nothing an action does to one pool may be visible in another. The whole of {PoolState} is
    /// compared, not a chosen field, so a stray write lands as a fingerprint mismatch whatever it touched.
    function _checkCrossPool(uint256 i) private {
        for (uint256 j = 0; j < pools.length; j++) {
            if (j == i) continue;
            if (_fingerprint(j) != snapFingerprint[j]) violationCrossPoolStateChanged += 1;
            if (hook.creatorClaimable(pools[j].id) != snapCreatorClaimable[j]) {
                violationCrossPoolCreatorChanged += 1;
            }
            if (hook.protocolClaimable(pools[j].id) != snapProtocolClaimable[j]) {
                violationCrossPoolProtocolChanged += 1;
            }
        }
    }

    /// @dev The two ledgers of one pool are independent: paying one must leave the other untouched.
    function _checkClaimIsolation(uint256 i, bool creatorSide) private {
        if (creatorSide) {
            if (hook.protocolClaimable(pools[i].id) != snapProtocolClaimable[i]) {
                violationClaimTouchedOtherLedger += 1;
            }
        } else if (hook.creatorClaimable(pools[i].id) != snapCreatorClaimable[i]) {
            violationClaimTouchedOtherLedger += 1;
        }
    }

    /// @dev The quantities that may only ever grow. Recorded rather than asserted, then rebased, so one
    /// violation is caught at the action that caused it instead of being hidden by later growth.
    function _refreshMonotonic() private {
        for (uint256 j = 0; j < pools.length; j++) {
            PoolState memory s = hook.poolState(pools[j].id);

            if (prevDeployedBands[j] & ~s.deployedBands != 0) violationBitmapCleared += 1;
            if (prevCompletedBands[j] & ~s.completedBands != 0) violationBitmapCleared += 1;
            if (s.nextBandIndex < prevNextBandIndex[j]) violationDeployOrder += 1;
            if (s.completedMilestones < prevCompletedMilestones[j]) violationCompletionsRegressed += 1;

            uint128 full = fullRangeLiquidityOf(j);
            if (full < prevFullRange[j]) violationFullRangeShrank += 1;

            prevDeployedBands[j] = s.deployedBands;
            prevCompletedBands[j] = s.completedBands;
            prevNextBandIndex[j] = s.nextBandIndex;
            prevCompletedMilestones[j] = s.completedMilestones;
            prevFullRange[j] = full;
        }
    }

    function _fingerprint(uint256 j) private view returns (bytes32) {
        return keccak256(abi.encode(hook.poolState(pools[j].id)));
    }

    // --- Views the invariant contract reads ---

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function poolIdAt(uint256 i) external view returns (PoolId) {
        return pools[i].id;
    }

    function poolKeyAt(uint256 i) external view returns (PoolKey memory) {
        return pools[i].key;
    }

    function tokenAt(uint256 i) external view returns (MilestoneToken) {
        return pools[i].token;
    }

    function creatorAt(uint256 i) external view returns (address) {
        return pools[i].creator;
    }

    function initialSupplyAt(uint256 i) external view returns (uint256) {
        return pools[i].initialSupply;
    }

    /// @notice Liquidity actually sitting in pool `i`'s full-range position.
    /// @dev Read from the manager at the template's fixed bounds rather than from the hook's own record,
    /// so "never decreasing" is a statement about the position and not about the bookkeeping.
    function fullRangeLiquidityOf(uint256 i) public view returns (uint128) {
        return manager.getPositionLiquidity(
            pools[i].id,
            Position.calculatePositionKey(
                address(hook), -Bounds.FULL_RANGE_TICK_BOUND, Bounds.FULL_RANGE_TICK_BOUND, hook.FULL_RANGE_SALT()
            )
        );
    }

    /// @notice How many of the ten actions have completed at least once.
    /// @dev The non-vacuity gate. A campaign where the fuzzer only ever reverted would pass every
    /// invariant trivially, and this is what makes that visible.
    function distinctActionsExercised() external view returns (uint256 n) {
        for (uint256 a = 0; a < ACTION_COUNT; a++) {
            if (actionSuccesses[a] != 0) n += 1;
        }
    }

    function totalAttempts() external view returns (uint256 n) {
        for (uint256 a = 0; a < ACTION_COUNT; a++) {
            n += actionAttempts[a];
        }
    }

    function totalSuccesses() external view returns (uint256 n) {
        for (uint256 a = 0; a < ACTION_COUNT; a++) {
            n += actionSuccesses[a];
        }
    }

    // --- Seed shaping ---

    function _poolIndex(uint256 seed) private view returns (uint256) {
        return bound(seed, 0, pools.length - 1);
    }

    function _levelOf(uint256 i) private view returns (int24) {
        (, int24 tick,,) = manager.getSlot0(pools[i].id);
        return Orientation.toLevel(tick);
    }

    function _clampLevel(int24 level) private pure returns (int24) {
        if (level > MAX_LEVEL) return MAX_LEVEL;
        if (level < -MAX_LEVEL) return -MAX_LEVEL;
        return level;
    }

    function _sqrtAtLevel(int24 level) private pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(Orientation.toTick(level));
    }
}
