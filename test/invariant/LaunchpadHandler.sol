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

/// @notice Stateful action driver for the multi-pool invariant campaign.
contract LaunchpadHandler is CommonBase, StdUtils {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    int24 internal constant MAX_LEVEL = Bounds.FULL_RANGE_TICK_BOUND;

    enum Action {
        BUY,
        SELL,
        WARP,
        COLLECT_FEES,
        GRADUATE,
        CLAIM_CREATOR,
        CLAIM_PROTOCOL,
        FLUSH,
        CLAIM_CREATOR_PATH,
        TRANSFER_NFT,
        UNAUTHORISED_CLAIM
    }

    uint256 internal constant ACTION_COUNT = 11;

    struct Pool {
        PoolId id;
        PoolKey key;
        MilestoneToken token;
        address creator;
        uint256 initialSupply;
        uint256 payoutPlan;
    }

    IPoolManager internal immutable manager;
    MilestoneHook internal immutable hook;
    RevenueNFT internal immutable nft;
    TestRouter internal immutable router;
    address internal immutable protocolRecipient;

    ProtocolTemplate internal template;
    Pool[] internal pools;
    address[] internal actors;

    uint256[ACTION_COUNT] public actionAttempts;
    uint256[ACTION_COUNT] public actionSuccesses;

    uint256 public bandDeployments;
    uint256 public bandSkips;
    uint256 public bandHarvests;
    uint256 public curveDeployments;
    uint256 public graduations;
    uint256 public feeCollections;
    uint256 public flushes;
    uint256 public creatorPathClaims;
    uint256 public nftTransfers;
    uint256 public secondsElapsed;
    uint256 public creatorEthPaid;
    uint256 public creatorPathEthPaid;
    uint256 public protocolEthPaid;

    mapping(uint256 => uint256) public harvestedQuote;
    mapping(uint256 => uint256) public potFunded;
    mapping(uint256 => uint256) public serviceFees;
    mapping(uint256 => uint256) public tokensBurned;
    mapping(uint256 => uint256) public bandSkipsOf;

    uint256 public violationDeployOrder;
    uint256 public violationRedeployedCompletedBand;
    uint256 public violationBitmapCleared;
    uint256 public violationCompletionsRegressed;
    uint256 public violationFullRangeShrank;
    uint256 public violationClaimTouchedOtherLedger;
    uint256 public violationCrossPoolStateChanged;
    uint256 public violationCrossPoolCreatorChanged;
    uint256 public violationUnauthorisedClaimSucceeded;
    uint256 public violationPlanChanged;

    uint256 public maxDeploysInOneSwap;
    uint256 public maxHarvestsInOneSwap;

    uint256[] internal prevDeployedBands;
    uint256[] internal prevCompletedBands;
    uint32[] internal prevNextBandIndex;
    uint32[] internal prevCompletedMilestones;
    uint128[] internal prevFullRange;

    bytes32[] internal snapFingerprint;
    uint256[] internal snapCreatorClaimable;
    uint256[] internal snapPayoutPot;
    uint256[] internal snapCarryBitmap;
    uint256[] internal snapCreatorPathClaimable;
    uint256 internal snapProtocolClaimable;
    uint256 internal actingPool;

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
                    initialSupply: t.initialSupply(),
                    payoutPlan: hook_.payoutPlan(id)
                })
            );
            prevDeployedBands.push(0);
            prevCompletedBands.push(0);
            prevNextBandIndex.push(0);
            prevCompletedMilestones.push(0);
            prevFullRange.push(0);
            snapFingerprint.push(bytes32(0));
            snapCreatorClaimable.push(0);
            snapPayoutPot.push(0);
            snapCarryBitmap.push(0);
            snapCreatorPathClaimable.push(0);
        }
        for (uint256 i = 0; i < actors_.length; i++) {
            actors.push(actors_[i]);
        }
        _refreshMonotonic();
    }

    /// @dev The handler is the `msg.sender` of its own `flush` calls, so it is the ordinary flusher the
    /// 1% tip is paid to. Without this, every tip-bearing flush reverts `EthTransferFailed` -- which is
    /// the specified atomic behaviour for a rejecting flusher -- and the campaign would never observe a
    /// successful flush, starving the delivery, carry, and conservation invariants of the very actions
    /// they exist to check. Accepting the tip keeps the handler inside the tracked `ethAccounts` set of
    /// {LaunchpadInvariantsTest}, so ETH conservation still balances.
    receive() external payable {}

    function buy(uint256 poolSeed, uint256 ethSeed, uint256 levelSeed) external {
        uint256 i = _poolIndex(poolSeed);
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

    function warp(uint256 secondsSeed) external {
        uint256 delta = bound(secondsSeed, 1 hours, 45 days);
        _begin(type(uint256).max);
        vm.warp(block.timestamp + delta);
        secondsElapsed += delta;
        _end(Action.WARP, true);
    }

    function collectFees(uint256 poolSeed) external {
        uint256 i = _poolIndex(poolSeed);
        _begin(i);
        try hook.collectFees(pools[i].key) {
            _end(Action.COLLECT_FEES, true);
        } catch {
            _end(Action.COLLECT_FEES, false);
        }
    }

    function graduate(uint256 poolSeed) external {
        uint256 i = _poolIndex(poolSeed);
        _begin(i);
        try hook.graduate(pools[i].key) {
            _end(Action.GRADUATE, true);
        } catch {
            _end(Action.GRADUATE, false);
        }
    }

    function claimCreator(uint256 poolSeed) external {
        uint256 i = _poolIndex(poolSeed);
        address holder = nft.ownerOf(nft.tokenIdOf(pools[i].id));
        _begin(i);
        vm.prank(holder);
        try hook.claimCreator(pools[i].id) {
            _checkClaimIsolation(true);
            _end(Action.CLAIM_CREATOR, true);
        } catch {
            _end(Action.CLAIM_CREATOR, false);
        }
    }

    function claimProtocol(uint256 poolSeed) external {
        uint256 i = _poolIndex(poolSeed);
        _begin(i);
        vm.prank(protocolRecipient);
        try hook.claimProtocol() {
            _checkClaimIsolation(false);
            _end(Action.CLAIM_PROTOCOL, true);
        } catch {
            _end(Action.CLAIM_PROTOCOL, false);
        }
    }

    function flush(uint256 poolSeed) external {
        uint256 i = _poolIndex(poolSeed);
        _begin(i);
        try hook.flush(pools[i].id) {
            _end(Action.FLUSH, true);
        } catch {
            _end(Action.FLUSH, false);
        }
    }

    function claimCreatorPath(uint256 poolSeed) external {
        uint256 i = _poolIndex(poolSeed);
        address holder = nft.ownerOf(nft.tokenIdOf(pools[i].id));
        _begin(i);
        vm.prank(holder);
        try hook.claimCreatorPath(pools[i].id) {
            _checkClaimIsolation(true);
            _end(Action.CLAIM_CREATOR_PATH, true);
        } catch {
            _end(Action.CLAIM_CREATOR_PATH, false);
        }
    }

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
            vm.prank(actor);
            try hook.claimCreatorPath(pools[i].id) {
                violationUnauthorisedClaimSucceeded += 1;
            } catch {}
        }
        if (actor != protocolRecipient) {
            tried = true;
            vm.prank(actor);
            try hook.claimProtocol() {
                violationUnauthorisedClaimSucceeded += 1;
            } catch {}
        }
        _end(Action.UNAUTHORISED_CLAIM, tried);
    }

    function _begin(uint256 i) private {
        actingPool = i;
        snapProtocolClaimable = hook.protocolClaimable();
        for (uint256 j = 0; j < pools.length; j++) {
            PoolId id = pools[j].id;
            snapFingerprint[j] = _fingerprint(j);
            snapCreatorClaimable[j] = hook.creatorClaimable(id);
            snapPayoutPot[j] = hook.payoutPot(id);
            snapCarryBitmap[j] = hook.carryBitmap(id);
            snapCreatorPathClaimable[j] = hook.creatorPathClaimable(id);
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

    function _accountLogs(uint256 i, Vm.Log[] memory logs, Action a) private {
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
                    if (prevCompletedBands[i] & (uint256(1) << index) != 0) violationRedeployedCompletedBand += 1;
                }
                seenDeploy = true;
                lastDeployed = index;
            } else if (topic == MilestoneBase.MilestoneHarvested.selector) {
                (uint256 quote,,) = abi.decode(logs[n].data, (uint256, uint256, uint32));
                harvests += 1;
                bandHarvests += 1;
                if (scoped) harvestedQuote[i] += quote;
            } else if (topic == MilestoneBase.PayoutPotFunded.selector) {
                (uint256 gross, uint256 fee, uint256 net,) =
                    abi.decode(logs[n].data, (uint256, uint256, uint256, uint64));
                if (scoped) {
                    potFunded[i] += net;
                    serviceFees[i] += fee;
                    if (gross != fee + net) violationCrossPoolStateChanged += 1;
                }
            } else if (topic == MilestoneBase.FeesRouted.selector) {
                (,,, uint256 burned,) = abi.decode(logs[n].data, (uint256, uint256, uint256, uint256, uint64));
                if (scoped) tokensBurned[i] += burned;
            } else if (topic == MilestoneBase.BandSkipped.selector) {
                bandSkips += 1;
                if (scoped) bandSkipsOf[i] += 1;
            } else if (topic == MilestoneBase.CurvePositionsDeployed.selector) {
                curveDeployments += 1;
            } else if (topic == MilestoneBase.Graduated.selector) {
                graduations += 1;
            } else if (topic == MilestoneBase.FeesCollected.selector) {
                feeCollections += 1;
            } else if (topic == MilestoneBase.PayoutPotRedeemed.selector) {
                flushes += 1;
            } else if (topic == MilestoneBase.CreatorClaimed.selector) {
                creatorEthPaid += abi.decode(logs[n].data, (uint256));
            } else if (topic == MilestoneBase.CreatorPathClaimed.selector) {
                creatorPathClaims += 1;
                creatorPathEthPaid += abi.decode(logs[n].data, (uint256));
            } else if (topic == MilestoneBase.ProtocolClaimed.selector) {
                protocolEthPaid += abi.decode(logs[n].data, (uint256));
            }
        }
        if (a == Action.BUY || a == Action.SELL) {
            if (deploys > maxDeploysInOneSwap) maxDeploysInOneSwap = deploys;
            if (harvests > maxHarvestsInOneSwap) maxHarvestsInOneSwap = harvests;
        }
    }

    function _checkCrossPool(uint256 i) private {
        for (uint256 j = 0; j < pools.length; j++) {
            if (j == i) continue;
            PoolId id = pools[j].id;
            if (_fingerprint(j) != snapFingerprint[j]) violationCrossPoolStateChanged += 1;
            if (
                hook.payoutPot(id) != snapPayoutPot[j] || hook.carryBitmap(id) != snapCarryBitmap[j]
                    || hook.creatorPathClaimable(id) != snapCreatorPathClaimable[j]
            ) violationCrossPoolStateChanged += 1;
            if (hook.creatorClaimable(id) != snapCreatorClaimable[j]) violationCrossPoolCreatorChanged += 1;
        }
    }

    function _checkClaimIsolation(bool creatorSide) private {
        if (creatorSide) {
            if (hook.protocolClaimable() != snapProtocolClaimable) violationClaimTouchedOtherLedger += 1;
        } else {
            for (uint256 i = 0; i < pools.length; i++) {
                if (hook.creatorClaimable(pools[i].id) != snapCreatorClaimable[i]) {
                    violationClaimTouchedOtherLedger += 1;
                }
            }
        }
    }

    function _refreshMonotonic() private {
        for (uint256 j = 0; j < pools.length; j++) {
            PoolState memory s = hook.poolState(pools[j].id);
            if (prevDeployedBands[j] & ~s.deployedBands != 0) violationBitmapCleared += 1;
            if (prevCompletedBands[j] & ~s.completedBands != 0) violationBitmapCleared += 1;
            if (s.nextBandIndex < prevNextBandIndex[j]) violationDeployOrder += 1;
            if (s.completedMilestones < prevCompletedMilestones[j]) violationCompletionsRegressed += 1;
            uint128 full = fullRangeLiquidityOf(j);
            if (full < prevFullRange[j]) violationFullRangeShrank += 1;
            if (hook.payoutPlan(pools[j].id) != pools[j].payoutPlan) violationPlanChanged += 1;
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

    function initialPlanAt(uint256 i) external view returns (uint256) {
        return pools[i].payoutPlan;
    }

    function fullRangeLiquidityOf(uint256 i) public view returns (uint128) {
        return manager.getPositionLiquidity(
            pools[i].id,
            Position.calculatePositionKey(
                address(hook), -Bounds.FULL_RANGE_TICK_BOUND, Bounds.FULL_RANGE_TICK_BOUND, hook.FULL_RANGE_SALT()
            )
        );
    }

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
