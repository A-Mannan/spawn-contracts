// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneBase} from "./MilestoneBase.sol";
import {MilestoneColdPaths} from "./MilestoneColdPaths.sol";
import {MilestoneToken} from "./MilestoneToken.sol";
import {RevenueNFT} from "./RevenueNFT.sol";
import {LaunchSupport} from "./LaunchSupport.sol";
import {CurveLib} from "./libraries/CurveLib.sol";
import {FeeLib} from "./libraries/FeeLib.sol";
import {LadderLib} from "./libraries/LadderLib.sol";
import {Orientation} from "./libraries/Orientation.sol";
import {TransientLock} from "./libraries/TransientLock.sol";
import {HarvestSplit, LaunchConfig, Phase, PoolState, ProtocolTemplate, WAD} from "./types/LaunchTypes.sol";

/// @title MilestoneHook
/// @notice The protocol core: one deployed hook serving every launch, holding per-pool state keyed by
/// `PoolId`, and acting as the launch entry point itself.
///
/// @dev design.md Decision 1. Hook permission flags are identical for every launch, so the address is
/// mined once at protocol deployment rather than per launch. Merging the factory into the hook
/// removes an external entry point and a cross-contract trust edge; the cost is that cross-pool
/// isolation becomes a correctness obligation, enforced by `poolId`-scoping every storage access and
/// asserted directly in the invariant suite.
///
/// Custody is direct (Decision 2) except for value collected while a swap is in flight, which is held
/// as an ERC-6909 claim (Decision 13). Settlement paths are guarded by transient-storage locks
/// (Decision 7).
///
/// The launch, graduation, and fee-collection paths live in {MilestoneColdPaths} and are reached by
/// DELEGATECALL, so they run in this contract's own storage and under this contract's address while
/// costing this contract's 24 KB budget only a forwarder each. Everything the swap path touches stays
/// here — the simulation, the ladder, the harvest — because an extra `DELEGATECALL` per swap is a cost
/// every trader would pay.
///
/// The swap path does three things, in this order (Decisions 15 and 18):
///
/// 1. **Auto-graduate** if the pool is still on its curve and the price has passed the far level.
/// 2. **Simulate the incoming buy** and mint every curve position or band its path will cross, so the
///    swap fills them as real liquidity rather than sweeping empty space.
/// 3. **Harvest**, in `afterSwap`, every deployed band the swap carried the price out the top of.
contract MilestoneHook is MilestoneBase, BaseHook, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Price limit for the harvest buyback: the lowest value `swap` accepts, so an exact-input buy
    /// is bounded by its budget rather than by a price. See {_buyBackAndBurn}.
    uint160 private constant _BUYBACK_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    /// @notice Address permitted to change {protocolRecipient}. Set at construction, never changed.
    address public immutable protocolAdmin;

    /// @notice The delegatecall target holding the launch, graduation, and fee-collection paths.
    ///
    /// @dev Immutable, so the split cannot become an upgrade hatch: Decision 10's "the only mutable
    /// protocol-level state is {protocolRecipient}" still holds literally. Swapping the cold paths means
    /// deploying a new hook at a newly mined address, exactly as changing any other logic would.
    address public immutable coldPaths;

    constructor(
        IPoolManager poolManager_,
        RevenueNFT revenueNft_,
        LaunchSupport launchSupport_,
        ProtocolTemplate memory template_,
        address coldPaths_,
        address protocolAdmin_,
        address protocolRecipient_
    ) BaseHook(poolManager_) MilestoneBase(revenueNft_, launchSupport_, template_) {
        if (protocolAdmin_ == address(0)) revert ZeroAddress();
        if (protocolRecipient_ == address(0)) revert ZeroAddress();

        // A `DELEGATECALL` to an address with no code succeeds and returns nothing, so an unset or
        // mistyped target would surface as a launch that silently does nothing rather than as a failed
        // deployment. Checked here, once, where it is cheap.
        if (coldPaths_.code.length == 0) revert NotAContract(coldPaths_);

        coldPaths = coldPaths_;
        protocolAdmin = protocolAdmin_;
        protocolRecipient = protocolRecipient_;
    }

    /// @inheritdoc BaseHook
    /// @dev Exactly the flag set the `token-launch` spec requires, and nothing more. Notably absent:
    /// - `afterAddLiquidity` / `afterRemoveLiquidity`: the before-guards already reject every
    ///   non-hook liquidity operation, so an after-callback would only add surface.
    /// - donate callbacks: the protocol never observes donations, only makes them.
    /// - the four return-delta flags: settlement goes through `take`/`settle`/claims, so the hook never
    ///   rewrites a swap's deltas.
    ///
    /// The dynamic fee is *not* encoded here — it lives in `PoolKey.fee` as
    /// `LPFeeLibrary.DYNAMIC_FEE_FLAG`, not in the hook address. It is retained solely for the
    /// milestone step-down (Decision 20).
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --- Protocol administration: the entire privileged surface (Decision 10) ---

    /// @notice Updates the protocol fee recipient.
    /// @dev Deliberately cannot reach pool liquidity, ladder inventory, launch configuration, or any
    /// creator balance. Already-accrued protocol balances stay claimable by the new recipient, which
    /// is the same current-holder rule the creator NFT uses.
    function setProtocolRecipient(address recipient) external {
        if (msg.sender != protocolAdmin) revert NotProtocolAdmin();
        if (recipient == address(0)) revert ZeroAddress();

        protocolRecipient = recipient;
        emit ProtocolRecipientSet(recipient);
    }

    // --- Claim entry points ---
    //
    // Both are quote-denominated, and that is the whole ledger (Decision 21): token-denominated fees are
    // routed to the milestone fund and to full-range compounding, so no claimant ever holds one.

    /// @notice Claims the creator's accrued ETH for a pool, payable to the current revenue NFT holder.
    ///
    /// @dev Pull-based and current-holder-gated. Ownership is read at claim time rather than recorded
    /// at accrual time, which is what makes the revenue stream tradeable: transferring the NFT
    /// transfers the right to everything unclaimed, with no settlement step on transfer.
    ///
    /// The balance is zeroed *before* the transfer, so even a recipient that re-enters finds nothing
    /// left to claim. The transient lock is belt-and-braces on top of that ordering.
    function claimCreator(PoolId poolId) external returns (uint256 amount) {
        TransientLock.enter(TransientLock.CLAIM, poolId);

        address holder = revenueNFT.ownerOf(revenueNFT.tokenIdOf(poolId));
        if (msg.sender != holder) revert NotRevenueNftHolder(poolId, msg.sender);

        amount = _creatorClaimable[poolId];
        if (amount != 0) {
            _creatorClaimable[poolId] = 0;
            _ensureEth(amount);
            _sendEth(holder, amount);
        }

        emit CreatorClaimed(poolId, holder, amount);

        TransientLock.exit(TransientLock.CLAIM, poolId);
    }

    /// @notice Claims the protocol's accrued ETH for a pool, payable to {protocolRecipient}.
    function claimProtocol(PoolId poolId) external returns (uint256 amount) {
        TransientLock.enter(TransientLock.CLAIM, poolId);

        address recipient = protocolRecipient;
        if (msg.sender != recipient) revert NotProtocolRecipient(msg.sender);

        amount = _protocolClaimable[poolId];
        if (amount != 0) {
            _protocolClaimable[poolId] = 0;
            _ensureEth(amount);
            _sendEth(recipient, amount);
        }

        emit ProtocolClaimed(poolId, recipient, amount);

        TransientLock.exit(TransientLock.CLAIM, poolId);
    }

    /// @notice Entry point the manager calls back into while unlocked.
    /// @dev Only the manager may call it. The dispatch itself lives in {MilestoneColdPaths}: genesis,
    /// graduation, quote redemption and fee collection all route through it. Reached by delegatecall, so
    /// `msg.sender` is still the manager on the far side — the check here is the whole of the authority
    /// gate, and the cold path re-checks nothing.
    function unlockCallback(bytes calldata data) external virtual returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManagerUnlock();

        return _dispatchUnlock(data);
    }

    /// @dev A virtual seam so the test harness can add unlock actions. Production forwards to the cold
    /// path; the harness overrides this to intercept its own high-numbered actions first.
    ///
    /// Re-encoded rather than passed through as raw calldata, because the cold path deliberately does not
    /// name its entry `unlockCallback`: it performs no `msg.sender` check, and a function with that name
    /// and no such check would read as a hole to anyone auditing {MilestoneColdPaths} on its own.
    function _dispatchUnlock(bytes calldata data) internal virtual returns (bytes memory) {
        return abi.decode(_delegateColdPathCall(abi.encodeCall(MilestoneColdPaths.dispatchUnlock, (data))), (bytes));
    }

    // --- Cold path delegation ---
    //
    // Two forwarders, because they trade off differently. {_delegateColdPath} passes `msg.data` through
    // untouched and returns the far side's returndata verbatim, so it costs nothing to encode or decode —
    // usable only where the hook's signature is identical to the cold path's, which for `launch`,
    // `graduate` and `collectFees` is guaranteed because both declare the parameter types in
    // {MilestoneBase}'s shared imports. {_delegateColdPathCall} is the general form.

    /// @dev Forwards this call to the cold path unchanged and returns or reverts with whatever comes
    /// back. Terminates the call frame: nothing after it in the caller runs.
    function _delegateColdPath() private {
        address target = coldPaths;

        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := delegatecall(gas(), target, ptr, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(ptr, 0, size)
            switch ok
            case 0 { revert(ptr, size) }
            default { return(ptr, size) }
        }
    }

    /// @dev Delegatecalls the cold path with an explicit payload, bubbling its revert reason unchanged so
    /// a custom error thrown there is indistinguishable to the caller from one thrown here.
    function _delegateColdPathCall(bytes memory payload) private returns (bytes memory) {
        (bool ok, bytes memory ret) = coldPaths.delegatecall(payload);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    // --- Launch (design Decision 19) ---

    /// @notice Launches a token from a creator-signed configuration. Anyone may relay it.
    ///
    /// @dev Implemented in {MilestoneColdPaths.launch} and reached by delegatecall. Permissionless — no
    /// allowlist, no role, no fee to enter, and no privileged approver even for the deferred custodial
    /// case. The creator is the recovered signer, not `msg.sender`; passing an empty signature selects
    /// the creator-direct path, where identity is the sender.
    ///
    /// The only gate is {LaunchSupport.validate}, and because configuration is immutable afterwards that
    /// validator is the whole of the protocol's policy enforcement (design Decision 10).
    ///
    /// The forwarder passes `msg.data` and `msg.value` through unchanged, so the cold path runs in this
    /// contract's storage, under this contract's address, spending the caller's ETH — the launch is
    /// indistinguishable from one executed here directly, which is the point of the split.
    function launch(LaunchConfig calldata config, bytes calldata signature)
        external
        payable
        returns (PoolId, address, PoolKey memory)
    {
        config; // silence unused-parameter warnings: the payload is forwarded as raw calldata
        signature;
        _delegateColdPath();
    }

    // --- Graduation ---

    /// @notice Retires the bonding curve and activates the milestone ladder. Permissionless.
    ///
    /// @dev Implemented in {MilestoneColdPaths.graduate} and reached by delegatecall. The gate is the
    /// pool's live tick, read at call time — not a flag, a timestamp, or anything recorded earlier. A
    /// pool that touched the far level and fell back has not graduated, and a reverted pump leaves
    /// nothing behind, because there is no state to leave.
    ///
    /// This races the `beforeSwap` auto-trigger (Decision 18) rather than replacing it: a prepared
    /// caller may pay the graduation gas deliberately instead of leaving it to the next trader.
    function graduate(PoolKey calldata key) external {
        key; // silence unused-parameter warning: the payload is forwarded as raw calldata
        _delegateColdPath();
    }

    // --- Fee collection ---

    /// @notice Realises the full-range position's accrued swap fees and routes them. Permissionless.
    ///
    /// @dev Implemented in {MilestoneColdPaths.collectFees} and reached by delegatecall, whose signature
    /// is declared identically here so `msg.data` forwards untouched and `msg.sender` — the caller
    /// {FeesCollected} records — survives the hop.
    ///
    /// Returns the fees collected, before diversion and routing, so a caller can tell a collection that
    /// did work from one that found nothing without parsing logs.
    function collectFees(PoolKey calldata key) external returns (uint256, uint256) {
        key; // silence unused-parameter warning: the payload is forwarded as raw calldata
        _delegateColdPath();
    }

    // --- Dev buy vesting ---

    /// @notice Releases whatever dev-buy tokens have vested to the creator.
    ///
    /// @dev Linear over the configured duration, measured from launch. The tokens stay in hook custody
    /// until released, so a vesting creator holds no transferable balance early. Creator-only: the
    /// schedule exists to bind the creator, so letting anyone else trigger it would be harmless but
    /// letting anyone else *receive* it would not, and gating the caller keeps the two inseparable.
    ///
    /// The creator here is the launch's recorded creator — the recovered signer of a relayed launch —
    /// never the relayer.
    function releaseDevBuy(PoolId poolId) external returns (uint256 amount) {
        PoolState storage state = _pools[poolId];
        if (msg.sender != state.creator) revert NotCreator(poolId, msg.sender);

        amount = releasableDevBuy(poolId);
        if (amount == 0) return 0;

        state.devBuyReleased += amount;
        MilestoneToken(state.token).transfer(state.creator, amount);

        emit DevBuyReleased(poolId, state.creator, amount);
    }

    /// @notice Dev-buy tokens vested and not yet released.
    function releasableDevBuy(PoolId poolId) public view returns (uint256) {
        PoolState storage state = _pools[poolId];
        if (state.devBuyTotal == 0) return 0;

        uint32 duration = state.devBuyVestingSeconds;
        uint256 vested;

        if (duration == 0 || block.timestamp >= uint256(state.launchedAt) + duration) {
            vested = state.devBuyTotal;
        } else {
            vested = (state.devBuyTotal * (block.timestamp - state.launchedAt)) / duration;
        }

        return vested - state.devBuyReleased;
    }

    // --- Hook callbacks ---

    /// @inheritdoc BaseHook
    /// @dev Only the hook's own {launch} may initialise a pool that names this hook. Otherwise anyone
    /// could stand up a second pool on the same hook with a price and configuration of their choosing,
    /// and the ladder would be pointed at a pool the protocol never validated.
    ///
    /// `sender` is whoever called `initialize` on the manager, so comparing it against this contract is
    /// exactly the right test — an external caller cannot forge it.
    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        if (sender != address(this)) revert InitializerNotLaunchPath(sender);
        return BaseHook.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    /// @dev Records nothing: {launch} has already written the pool's state, deliberately before
    /// `initialize` so this callback can be a no-op rather than a second source of truth. Genesis
    /// minting happens under an explicit unlock instead (design Decision 5).
    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal pure override returns (bytes4) {
        return BaseHook.afterInitialize.selector;
    }

    /// @inheritdoc BaseHook
    /// @dev Three jobs, in order: close the graduation limbo if the price has left the curve behind
    /// (Decision 18), then mint every position this swap's own price path will reach (Decision 15).
    /// There is no third — Decision 20 removed the anti-snipe override, so the returned fee is always
    /// "no override" and the pool charges its stored base fee.
    ///
    /// Deployment happens here rather than in `afterSwap` for one reason: it must be *this* swap that
    /// fills what is minted. v4 reads the pool's liquidity after `beforeSwap` returns, so a position
    /// minted here is in the path of the swap that triggered it — which is what lets a single sweeping
    /// buy cross several milestones correctly instead of sweeping empty space where they should be.
    ///
    /// The only thing here that can revert is the auto-graduation, and that is deliberate. Above the far
    /// level nobody can trade until graduation runs, so a swap arriving there has no meaningful
    /// alternative outcome; swallowing a failure would leave the limbo open and hide it. Both deployment
    /// paths decline rather than fail at every step, so the specs' "the hook never blocks a swap for
    /// size, direction, timing, or caller" holds for everything else.
    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolState storage state = _pools[poolId];
        Phase phase = state.phase;

        // Nothing to do for a pool that is not ours, and nothing to do while one of the protocol's own
        // settlement paths is mid-flight (Decision 7).
        if (phase != Phase.NONE && !TransientLock.settlementInFlight(poolId)) {
            if (phase == Phase.BONDING_CURVE && _currentLevel(poolId) >= state.farLevel) {
                _delegateColdPathCall(abi.encodeCall(MilestoneColdPaths.graduateWhileUnlocked, (key)));
                phase = Phase.GRADUATED;
            }

            // A sell moves the price away from everything above spot, so there is nothing to prepare.
            if (params.zeroForOne) {
                if (phase == Phase.BONDING_CURVE) {
                    _deployCurveAhead(key, poolId, params.amountSpecified, params.sqrtPriceLimitX96);
                } else {
                    _deployBandsAhead(key, poolId, state, params);
                }
            }
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc BaseHook
    /// @dev Milestone harvest is the only work here: every deployed band whose top the swap carried the
    /// price past is complete, and is settled in the same transaction that filled it.
    ///
    /// Returns a zero delta because settlement goes through claims and `take`/`settle` rather than by
    /// rewriting swap deltas. The hook declares no `afterSwapReturnDelta` permission, so v4 discards
    /// this value anyway — a harvest landing on someone's swap cannot change what that swap paid.
    ///
    /// Cannot revert. The `milestone-ladder` spec requires the hook never to block a graduated-phase
    /// swap, so every step below either declines or is argued unreachable at its call site.
    function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        _harvestAfterSwap(key);

        return (BaseHook.afterSwap.selector, int128(0));
    }

    /// @inheritdoc BaseHook
    /// @dev All pool liquidity is hook-owned, in every phase. This single guard is what delivers several
    /// separate spec requirements at once: no external LPs, no just-in-time liquidity around a swap, no
    /// external party resizing or repricing a curve position or a band, and no path by which anyone but
    /// the hook can touch the code-locked full-range position.
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (sender != address(this)) revert ExternalLiquidityNotAllowed(sender);
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @inheritdoc BaseHook
    /// @dev The mirror of {_beforeAddLiquidity}. Note this rejects *external* removal only; the hook
    /// still removes its own curve positions at graduation and its own bands at harvest. What makes the
    /// full-range position permanently locked is the absence of any code path that removes it, not this
    /// guard — which `make lock-check` asserts structurally.
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (sender != address(this)) revert ExternalLiquidityNotAllowed(sender);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // --- Simulation-driven band deployment (design Decision 15) ---

    /// @notice The pool's live price expressed in protocol level space.
    function _currentLevel(PoolId poolId) internal view returns (int24) {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        return Orientation.toLevel(tick);
    }

    /// @notice Mints every undeployed band the incoming buy's simulated path will cross.
    ///
    /// @dev The walk alternates between two liquidity regimes, and that is the whole of its structure:
    /// in the gap between bands the only liquidity is the full-range position, and inside a band it is
    /// the full-range position plus that band. Bands never overlap, so at most one is ever in range.
    /// Both figures are exact — the full-range liquidity is stored, a live band's is read from the pool
    /// — which is what makes the simulation an evaluation of v4's own swap math rather than an estimate.
    ///
    /// The walk starts at the lowest *live* band rather than at the next undeployed one, because a band
    /// deployed by an earlier swap and not yet completed still sits in the path and still resists the
    /// price. Skipping its liquidity would understate the cost of the gap beyond it and over-deploy.
    ///
    /// Every exit is a `break` or a `continue`, never a revert: this runs inside `beforeSwap`, and
    /// stopping early can only *under*-deploy, which degrades to the specified skip-and-carry.
    function _deployBandsAhead(
        PoolKey calldata key,
        PoolId poolId,
        PoolState storage state,
        IPoolManager.SwapParams calldata params
    ) private {
        uint128 base = state.fullRangeLiquidity;
        if (base == 0) return;

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        int24 level = Orientation.toLevel(tick);

        LadderLib.Walk memory walk = LadderLib.Walk({
            sqrtPriceX96: sqrtPriceX96,
            amountRemaining: params.amountSpecified,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            feePips: state.baseFeeHundredthsBip
        });

        uint256 live = state.deployedBands & ~state.completedBands;
        uint32 next = state.nextBandIndex;
        uint256 index = live == 0 ? next : BitMath.leastSignificantBit(live);
        uint256 deploys;

        for (uint256 step = 0; step < LadderLib.MAX_WALK_STEPS; step++) {
            if (!LadderLib.withinLadderCap(coreBandCount, index, state.feeFundedBandsCreated, maxFeeFundedBands)) {
                break;
            }

            (int24 lower, int24 upper, bool exists) =
                LadderLib.bandLevels(state.graduationLevel, bandLevelSpacing, bandWidthLevels, index);
            if (!exists) break;

            bool isNew = index >= next;
            bool isLive = !isNew && (live & (uint256(1) << index)) != 0;

            // Completed or skipped: no liquidity at this level, so the walk passes straight over it.
            if (!isNew && !isLive) {
                index += 1;
                continue;
            }

            // A band whose lower bound is already behind spot can never be minted, and that is decided
            // against spot rather than against the walk: single-sided token liquidity requires
            // `currentTick >= tickUpper`, which in level space is spot at or below `levelLower`, and the
            // mint lands at the *real* pre-swap price however far the simulation has since walked. Two
            // cases reach here — a band the price has fully passed (the deploy cap's fallback) and a band
            // the price is sitting inside — and both carry their share up to the next band.
            //
            // Skipping is what makes the straddle deadlock unreachable. A band that could neither deploy
            // nor skip would ask v4 for a two-sided mint, leave the `currency0` debit unsettled, and
            // revert `beforeSwap` — bricking every buy until someone sold the price back below the band.
            // `break` would avoid the revert but strand the ladder at this index forever, so the escape
            // has to be a skip.
            if (isNew && lower < level) {
                _skipBand(poolId, state, uint32(index));
                next = uint32(index) + 1;
                index += 1;
                continue;
            }

            // A live band the price has already risen out of holds only quote, so an upward walk meets
            // nothing in it. It stays live until a harvest settles it.
            if (isLive && upper <= level) {
                index += 1;
                continue;
            }

            // Cross the gap up to this band's lower bound against the full-range position alone.
            if (lower > level) {
                if (!LadderLib.advance(walk, LadderLib.sqrtPriceAtLevel(lower), base)) break;
                level = lower;
            }

            uint128 bandLiquidity;
            if (isLive) {
                bandLiquidity = _bandLiquidity(poolId, lower, upper, index);
            } else {
                if (deploys >= maxDeploysPerSwap) break;

                bandLiquidity = _deployBand(key, poolId, state, uint32(index), lower, upper);
                // Nothing available to fund this band with. Leaving the index unadvanced is deliberate:
                // "extension requires accrued inventory" means the ladder goes quiet until accrual
                // resumes, not that the level is consumed.
                if (bandLiquidity == 0) break;

                next = uint32(index) + 1;
                deploys += 1;
            }

            // Traverse the band itself, so the next gap is priced from its top.
            if (!LadderLib.advance(walk, LadderLib.sqrtPriceAtLevel(upper), base + bandLiquidity)) break;
            level = upper;
            index += 1;
        }

        if (next != state.nextBandIndex) state.nextBandIndex = next;
    }

    /// @notice Steps over a band the price rose past without it ever being deployed.
    /// @dev Not an error and not a loss: its core share moves into carried inventory, which the next
    /// band draws on, so the tokens stay in hook custody the whole time and the ladder continues from
    /// the level above.
    function _skipBand(PoolId poolId, PoolState storage state, uint32 index) private {
        if (index < coreBandCount) {
            uint256 share = LadderLib.perBandInventory(state.totalSupply, ladderSupplyShareWad, coreBandCount);
            uint256 remaining = state.ladderInventoryRemaining;
            if (share > remaining) share = remaining;

            state.ladderInventoryRemaining = remaining - share;
            state.carriedInventory += share;
        }

        emit BandSkipped(poolId, index, state.carriedInventory);
    }

    /// @notice Mints band `index` as single-sided token liquidity and settles the token side.
    ///
    /// @dev The band's tick range lies strictly below the current tick — level is `-tick`, and the walk
    /// has brought the price to `levelLower`, so `currentTick >= tickUpper` — which is precisely the case
    /// where v4's accounting makes a position pure `currency1`. That is the band: token inventory offered
    /// for sale, waiting for the price to reach it.
    ///
    /// Returns zero when nothing funded it, which the caller treats as "stop here" rather than "skip
    /// this level".
    function _deployBand(
        PoolKey calldata key,
        PoolId poolId,
        PoolState storage state,
        uint32 index,
        int24 levelLower,
        int24 levelUpper
    ) private returns (uint128 liquidity) {
        uint256 requested = _fundBand(state, index);
        if (requested == 0) return 0;

        // Cannot revert: the template holds `bandWidthLevels` above zero, so the range is ascending.
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelUpper);

        liquidity = LadderLib.boundedLiquidity(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), requested
        );
        if (liquidity == 0) {
            // Too little to mint anything at this width. Return it to the carry rather than stranding it,
            // so a later, better-priced band can use it.
            state.carriedInventory += requested;
            return 0;
        }

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bandSalt(index)
            }),
            ""
        );

        int256 owed1 = delta.amount1();
        uint256 spent = owed1 < 0 ? uint256(-owed1) : 0;
        _settleCurrency(key.currency1, spent);

        // `getLiquidityForAmount1` floors, so the position consumes slightly less than it was offered.
        // The difference is dust, but it is the pool's dust: carry it to the next band rather than lose it.
        state.carriedInventory += requested - spent;

        state.deployedBands |= (uint256(1) << index);
        _bandDeployedAt[poolId][index] = uint64(block.timestamp);
        if (index >= coreBandCount) state.feeFundedBandsCreated += 1;

        emit BandDeployed(poolId, index, levelLower, levelUpper, liquidity, spent);
    }

    /// @notice Draws a band's token inventory from the three sources that fund it.
    ///
    /// @dev Its own core share (core bands only), plus inventory carried from skipped bands, plus
    /// whatever the milestone fund has accrued from token-denominated swap fees. Capped at the
    /// template's multiple of the per-band share so a run of skips cannot concentrate the whole ladder
    /// into one position; the excess stays carried and tops up the band after this one.
    ///
    /// Fee-funded bands (index at or above the core count) have no core allocation: they exist only
    /// because fees paid for them, so a zero return is the specified "the ladder is simply inactive
    /// until accrual resumes".
    function _fundBand(PoolState storage state, uint32 index) private returns (uint256 amount) {
        uint256 perBand = LadderLib.perBandInventory(state.totalSupply, ladderSupplyShareWad, coreBandCount);

        uint256 core;
        if (index < coreBandCount) {
            core = perBand;
            uint256 remaining = state.ladderInventoryRemaining;
            if (core > remaining) core = remaining;
        }

        uint256 accrued = state.milestoneFundAccrued;
        uint256 carryOver;
        (amount, carryOver) =
            LadderLib.sizeInventory(core + state.carriedInventory + accrued, perBand, bandInventoryCapMultiple);
        if (amount == 0) return 0;

        state.ladderInventoryRemaining -= core;
        state.carriedInventory = carryOver;
        if (accrued != 0) state.milestoneFundAccrued = 0;
    }

    /// @notice A deployed band's live liquidity, read from the pool.
    /// @dev Read rather than stored: the pool is authoritative, and the harvest burns exactly what
    /// exists, so a rounding difference could never leave a sliver of a band alive.
    function _bandLiquidity(PoolId poolId, int24 levelLower, int24 levelUpper, uint256 index)
        private
        view
        returns (uint128)
    {
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelUpper);
        return poolManager.getPositionLiquidity(
            poolId, Position.calculatePositionKey(address(this), tickLower, tickUpper, bandSalt(index))
        );
    }

    // --- Milestone harvest: completion, settlement, and routing ---

    /// @notice Completes and settles every band this swap carried the price out the top of.
    ///
    /// @dev Completion is decided on the *post-swap price read from the pool*, not inferred from the
    /// swap delta, so a band completes on the price actually reached however the swap got there —
    /// including a single sweep that minted the band and crossed it in one call.
    ///
    /// Level is `-tick`, so "price at or above the band's top" is `level >= levelUpper`, and that is
    /// exactly the point at which the position has sold its whole token inventory and holds only quote.
    /// Anything below it is a partial fill: the band stays live with its remaining inventory in the pool
    /// and completes on a later swap.
    ///
    /// The loop is bounded at the template's `maxHarvestsPerSwap` (design Decision 4, revised). A sweep
    /// crossing more completed bands than the cap harvests the lowest ones and leaves the rest live, to
    /// settle on the next swap that ends above them. Because band levels ascend with index, the first
    /// band whose top the price has *not* reached ends the loop — nothing above it can have completed.
    ///
    /// The level is read once, before any routing. Each harvest's buyback is a market buy that pushes
    /// the price further up, and deciding completion on the pre-routing level is what keeps a buyback
    /// from harvesting a band the market itself never reached.
    function _harvestAfterSwap(PoolKey calldata key) private {
        PoolId poolId = key.toId();
        PoolState storage state = _pools[poolId];

        if (state.phase != Phase.GRADUATED) return;
        // Suppress the hook's own work while a settlement is already in flight (Decision 7). v4 skips
        // both swap callbacks when the hook is itself the swapper, so the nested buyback cannot reach
        // here in the first place; this keeps the guarantee ours rather than borrowed from that.
        if (TransientLock.settlementInFlight(poolId)) return;

        uint256 live = state.deployedBands & ~state.completedBands;
        if (live == 0) return;

        int24 level = _currentLevel(poolId);
        int24 graduationLevel = state.graduationLevel;
        uint256 harvests;
        bool entered;

        while (live != 0 && harvests < maxHarvestsPerSwap) {
            uint256 index = BitMath.leastSignificantBit(live);

            (int24 lower, int24 upper, bool exists) =
                LadderLib.bandLevels(graduationLevel, bandLevelSpacing, bandWidthLevels, index);
            if (!exists) break;
            if (level < upper) break;

            if (!entered) {
                // Cannot revert: `enter` only rejects re-entry, and the check above already returned if
                // the lock were held.
                TransientLock.enter(TransientLock.SETTLEMENT, poolId);
                entered = true;
            }

            _harvestBand(key, poolId, state, uint32(index), lower, upper);

            live &= ~(uint256(1) << index);
            harvests += 1;
        }

        if (entered) TransientLock.exit(TransientLock.SETTLEMENT, poolId);
    }

    /// @notice Burns one completed band, marks it complete, and routes its proceeds.
    ///
    /// @dev The band is marked complete *before* anything is routed, and routing is what performs the
    /// nested buyback swap. So even if that swap somehow re-entered this path, the band it would try to
    /// harvest is already recorded as finished: the transient lock is the guard, and this ordering is
    /// what still holds if the guard is ever bypassed. It is also what makes "a completed band cannot be
    /// harvested again" true for later swaps, and what makes a price that falls back afterwards unable
    /// to un-complete anything — the bit is never cleared.
    function _harvestBand(
        PoolKey calldata key,
        PoolId poolId,
        PoolState storage state,
        uint32 index,
        int24 levelLower,
        int24 levelUpper
    ) private {
        (uint256 quote, uint256 tokenResidue) = _burnBand(key, poolId, index, levelLower, levelUpper);

        state.completedBands |= (uint256(1) << index);
        uint32 completed = state.completedMilestones + 1;
        state.completedMilestones = completed;

        // A band completed above its top holds no token beyond rounding dust, but it is ladder inventory
        // whatever its size, so it funds the next band rather than sitting idle in custody.
        if (tokenResidue != 0) state.carriedInventory += tokenResidue;

        emit MilestoneHarvested(poolId, index, quote, tokenResidue, completed);

        _applyFeeStep(key, poolId, state, completed);
        _routeHarvest(key, poolId, state.token, index, quote);
    }

    /// @notice Steps the stored base fee down if this completion reached a template threshold.
    ///
    /// @dev design Decision 8, revised. The schedule is evaluated from the completion count rather than
    /// accumulated step by step, so the fee is a pure function of how many milestones a pool has
    /// completed — which is what makes "step-downs do not reverse" structural: the count only ever
    /// rises, and a price that falls back changes nothing. The guard below adds the same property
    /// arithmetically.
    ///
    /// Cannot revert, which a harvest requires. `updateDynamicLPFee` rejects only a non-dynamic pool, a
    /// caller that is not the hook, or a fee above 100%: the pool carries `LPFeeLibrary.DYNAMIC_FEE_FLAG`
    /// from launch, the hook is the caller, and the template's values are validated at construction.
    function _applyFeeStep(PoolKey calldata key, PoolId poolId, PoolState storage state, uint32 completed) private {
        uint24 current = state.baseFeeHundredthsBip;
        uint24 stepped = FeeLib.steppedBaseFee(
            current, feeStepOneAtCompletions, feeStepOneFee, feeStepTwoAtCompletions, feeStepTwoFee, completed
        );
        if (stepped >= current) return;

        state.baseFeeHundredthsBip = stepped;
        poolManager.updateDynamicLPFee(key, stepped);

        emit BaseFeeStepped(poolId, completed, current, stepped);
    }

    /// @notice Burns a completed band's position and takes what it returns into hook custody.
    ///
    /// @dev The returned delta carries principal and accrued fees together, which is how a band's own
    /// swap fees fold into its harvest without ever being accounted for separately.
    function _burnBand(PoolKey calldata key, PoolId poolId, uint32 index, int24 levelLower, int24 levelUpper)
        private
        returns (uint256 quote, uint256 tokenResidue)
    {
        uint128 liquidity = _bandLiquidity(poolId, levelLower, levelUpper, index);
        if (liquidity == 0) return (0, 0);

        // Cannot revert: the band was minted from this same conversion, so the range is in bounds.
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelUpper);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: bandSalt(index)
            }),
            ""
        );

        // A burn returns principal and pays fees, so it can only credit the hook. The guards cost nothing
        // and mean an unsettleable debit could never be produced here even if that reasoning were wrong.
        int128 credit0 = delta.amount0();
        int128 credit1 = delta.amount1();
        quote = credit0 > 0 ? uint256(uint128(credit0)) : 0;
        tokenResidue = credit1 > 0 ? uint256(uint128(credit1)) : 0;

        // The quote becomes a claim, not real ETH (Decision 13). This runs inside the crossing swap's
        // callback, before that swap has settled its input, so the manager is short of native currency by
        // the size of the very swap that completed the band — `take` here would revert on the buys large
        // enough to fill a band in one go, which is most of them. The token side is taken for real: those
        // tokens were transferred into the manager when the band was minted and are sitting there now.
        _mintClaim(key.currency0, quote);
        _takeCurrency(key.currency1, address(this), tokenResidue);
    }

    // --- Band proceeds routing ---
    //
    // The harvest holds its quote as an ERC-6909 claim rather than as real ETH (Decision 13), because it
    // settles mid-swap, where the manager is short by the size of the swap in flight. Both the buyback's
    // input and the LP donation are therefore paid by burning that claim.

    /// @notice Splits a band's quote proceeds four ways and delivers each share to its destination.
    ///
    /// @dev The creator and protocol shares are *credited*, never pushed — a creator that cannot receive
    /// ETH must not be able to block the swap that completed their milestone. The buyback share buys and
    /// burns. The LP share compounds into the pool.
    ///
    /// The LP share takes the remainder rather than being computed from its own wad, so the four shares
    /// sum to the proceeds exactly: integer division dust and any part of the buyback its swap could not
    /// spend both compound instead of being stranded.
    function _routeHarvest(PoolKey memory key, PoolId poolId, address token, uint32 index, uint256 quote) internal {
        if (quote == 0) return;

        HarvestSplit memory split = _pools[poolId].harvestSplit;
        uint256 creatorAmount = (quote * split.creatorWad) / WAD;
        uint256 protocolAmount = (quote * split.protocolWad) / WAD;
        uint256 buybackShare = (quote * split.buybackWad) / WAD;

        _accrueCreator(poolId, creatorAmount, AccrualSource.MILESTONE_HARVEST);
        _accrueProtocol(poolId, protocolAmount, AccrualSource.MILESTONE_HARVEST);

        (uint256 buybackQuote, uint256 tokensBurned) = _buyBackAndBurn(key, token, buybackShare);
        uint256 lpAmount = _compoundLpShare(key, poolId, quote - creatorAmount - protocolAmount - buybackQuote);

        emit HarvestRouted(poolId, index, creatorAmount, buybackQuote, tokensBurned, protocolAmount, lpAmount);
    }

    /// @notice Buys the launch token with the buyback share and burns everything it buys.
    ///
    /// @dev design Decision 6. The swap goes straight to the manager rather than through a fresh
    /// `unlock`: the caller already runs inside one and v4 permits only one at a time, so a nested
    /// `unlock` would revert. v4 also skips both swap callbacks when the hook is the swapper, so this
    /// cannot recurse into the ladder or into another settlement.
    ///
    /// Exact-input, so the share is spent rather than a token amount targeted; the burn then reduces total
    /// supply by whatever that bought. A zero share performs no swap at all, which is both the cheap path
    /// and the behaviour the `milestone-ladder` spec requires.
    function _buyBackAndBurn(PoolKey memory key, address token, uint256 quoteIn)
        private
        returns (uint256 spent, uint256 tokensBurned)
    {
        if (quoteIn == 0) return (0, 0);

        // `swap` rejects a limit at or beyond the current price. Only reachable if the price has already
        // run to the floor of tick space, where a buy would have nothing left to cross into anyway.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 <= _BUYBACK_PRICE_LIMIT) return (0, 0);

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: _BUYBACK_PRICE_LIMIT
            }),
            ""
        );

        // Quote in, token out: the first side is a debit, the second a credit. Guarded rather than cast
        // blind so a partial fill or a zero-liquidity swap cannot produce a bad settlement pairing.
        int128 owed0 = delta.amount0();
        int128 credit1 = delta.amount1();
        spent = owed0 < 0 ? uint256(uint128(-owed0)) : 0;
        tokensBurned = credit1 > 0 ? uint256(uint128(credit1)) : 0;

        _burnClaim(key.currency0, spent);
        _takeCurrency(key.currency1, address(this), tokensBurned);

        if (tokensBurned != 0) MilestoneToken(token).burn(tokensBurned);
    }

    /// @notice Compounds the LP share into the hook-owned full-range position.
    ///
    /// @dev design Decision 12. Band proceeds are quote-only — a completed band has sold all of its
    /// token — while the full-range position straddles spot, so adding *principal* to it would take both
    /// currencies, and sourcing the token side would mean a swap. The `milestone-ladder` scenario "A zero
    /// buyback share performs no swap" rules that out: routing anything other than the buyback must not
    /// swap.
    ///
    /// `donate` is what resolves it. The share is credited to the pool's in-range liquidity, which under
    /// multi-band deployment is the full-range position plus at most one band straddling spot; a band
    /// that has just been harvested sits at or below spot and holds no token, so the donation lands where
    /// it is meant to. The value is folded into position liquidity by the fee-collection path, which is
    /// the one place the protocol holds both currencies at once (Decision 9).
    function _compoundLpShare(PoolKey memory key, PoolId poolId, uint256 amount) private returns (uint256) {
        if (amount == 0) return 0;
        // `donate` reverts with no in-range liquidity, and a harvest must never revert. Unreachable for a
        // graduated pool: the template's LP seed puts a non-trivial full-range position in place and no
        // code path removes it. If it were ever hit the share stays in hook custody.
        if (poolManager.getLiquidity(poolId) == 0) return 0;

        poolManager.donate(key, amount, 0, "");
        _burnClaim(key.currency0, amount);

        return amount;
    }

    // --- Views ---

    /// @notice The protocol template this deployment was constructed with.
    ///
    /// @dev Reassembled from immutables, which are `internal` precisely so this is the only accessor:
    /// twenty-six generated getters would cost roughly 1.3 KB in each half of the delegatecall pair.
    /// There is no setter for any field, on either half — changing the template means redeploying the
    /// protocol, and the satellite must be redeployed with the identical struct.
    function template() external view returns (ProtocolTemplate memory t) {
        t.openingFdvWei = openingFdvWei;
        t.curvePositions = curvePositions;
        t.curveSpanLevels = curveSpanLevels;
        t.bandLevelSpacing = bandLevelSpacing;
        t.bandWidthLevels = bandWidthLevels;
        t.coreBandCount = coreBandCount;
        t.maxFeeFundedBands = maxFeeFundedBands;
        t.curveSupplyShareWad = curveSupplyShareWad;
        t.ladderSupplyShareWad = ladderSupplyShareWad;
        t.fullRangeSupplyShareWad = fullRangeSupplyShareWad;
        t.lpSeedWad = lpSeedWad;
        t.proceedsCreatorWad = proceedsCreatorWad;
        t.proceedsProtocolWad = proceedsProtocolWad;
        t.baseFeeHundredthsBip = baseFeeHundredthsBip;
        t.feeStepOneAtCompletions = feeStepOneAtCompletions;
        t.feeStepOneFee = feeStepOneFee;
        t.feeStepTwoAtCompletions = feeStepTwoAtCompletions;
        t.feeStepTwoFee = feeStepTwoFee;
        t.milestoneFundShareWad = milestoneFundShareWad;
        t.bandInventoryCapMultiple = bandInventoryCapMultiple;
        t.maxDeploysPerSwap = maxDeploysPerSwap;
        t.maxHarvestsPerSwap = maxHarvestsPerSwap;
        t.defaultCreatorWad = defaultCreatorWad;
        t.defaultBuybackWad = defaultBuybackWad;
        t.defaultProtocolWad = defaultProtocolWad;
        t.defaultLpWad = defaultLpWad;
    }

    function poolPhase(PoolId poolId) external view returns (Phase) {
        return _pools[poolId].phase;
    }

    function poolState(PoolId poolId) external view returns (PoolState memory) {
        return _pools[poolId];
    }

    function creatorClaimable(PoolId poolId) external view returns (uint256) {
        return _creatorClaimable[poolId];
    }

    function protocolClaimable(PoolId poolId) external view returns (uint256) {
        return _protocolClaimable[poolId];
    }

    /// @notice Whether band `index` has been minted for this pool.
    function bandDeployed(PoolId poolId, uint256 index) external view returns (bool) {
        return _pools[poolId].deployedBands & (uint256(1) << index) != 0;
    }

    /// @notice Whether band `index`'s milestone has been completed and harvested.
    function bandCompleted(PoolId poolId, uint256 index) external view returns (bool) {
        return _pools[poolId].completedBands & (uint256(1) << index) != 0;
    }

    /// @notice When band `index` was minted, or zero if it never was.
    function bandDeployedAt(PoolId poolId, uint256 index) external view returns (uint64) {
        return _bandDeployedAt[poolId][index];
    }

    /// @notice Band `index`'s level bounds for this pool, derived from the template and the graduation
    /// level.
    /// @dev A convenience for observers and tests; the protocol itself always recomputes.
    function bandLevels(PoolId poolId, uint256 index)
        external
        view
        returns (int24 levelLower, int24 levelUpper, bool exists)
    {
        return LadderLib.bandLevels(_pools[poolId].graduationLevel, bandLevelSpacing, bandWidthLevels, index);
    }

    /// @notice Whether bonding curve position `index` has been minted for this pool.
    function curvePositionDeployed(PoolId poolId, uint256 index) external view returns (bool) {
        return _pools[poolId].curveDeployed & (uint32(1) << uint8(index)) != 0;
    }

    /// @notice Bonding curve position `index`'s start level for this pool.
    function curvePositionStart(PoolId poolId, uint256 index) external view returns (int24) {
        PoolState storage state = _pools[poolId];
        return CurveLib.positionStart(state.openingLevel, state.farLevel, curvePositions, index);
    }

    /// @notice Accepts native ETH. Required because custody is direct: curve proceeds, harvest
    /// proceeds, and fee shares all arrive as native ETH taken from the pool manager (Decision 2).
    receive() external payable {}
}
