// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {MilestoneBase} from "./MilestoneBase.sol";
import {MilestoneToken} from "./MilestoneToken.sol";
import {RevenueNFT} from "./RevenueNFT.sol";
import {LaunchSupport} from "./LaunchSupport.sol";
import {CurveLib} from "./libraries/CurveLib.sol";
import {LadderLib} from "./libraries/LadderLib.sol";
import {LaunchSignature} from "./libraries/LaunchSignature.sol";
import {Orientation} from "./libraries/Orientation.sol";
import {TransientLock} from "./libraries/TransientLock.sol";
import {Bounds, LaunchConfig, Phase, PoolState, ProtocolTemplate, WAD} from "./types/LaunchTypes.sol";

/// @title MilestoneColdPaths
/// @notice The launch, graduation, and fee-collection logic of {MilestoneHook}, held in a separate
/// contract and reached by DELEGATECALL so it does not consume the hook's 24 KB budget.
///
/// @dev design.md Decision 1 (revised). The singleton hook exceeded EIP-170 during task group 8: 25,461
/// bytes against a 24,576 limit, with the ladder harvest, the fee waterfall and the reclaim path still
/// to come. `via_ir` and a size-tuned `optimizer_runs` were already in place and between them bought
/// 162 further bytes, so the overflow was structural rather than a squeeze.
///
/// This split is chosen over design.md's original contingency — a thin external *launcher* — because
/// DELEGATECALL introduces no trust edge, which is the property Decision 1 exists to protect:
///
/// - Execution happens in the hook's own context. `address(this)` is the hook, so every position minted
///   here is hook-owned exactly as before, `msg.sender` is the original caller so relay attribution is
///   unchanged, and `msg.value` is the caller's ETH rather than a forwarded copy.
/// - No caller gains authority. There is no privileged entry point here and nothing to be granted: the
///   hook's `_beforeAddLiquidity` guard still admits only `address(this)`, which this contract cannot
///   become except by being delegated to *by* the hook.
/// - Calling it directly is impossible, not merely useless. Every entry point is {onlyDelegated}, so a
///   direct call reverts {NotDelegated} before it does anything.
///
/// What it does share with the hook is the storage layout, which is a real coupling and the reason
/// every state variable is declared once in {MilestoneBase} and never here. `make layout-check`
/// compares the compiled layouts of both contracts in CI, so a variable added to either one fails the
/// build rather than silently aliasing a slot.
///
/// The immutables — including every field of the {ProtocolTemplate} — resolve from *this* contract's
/// bytecode even under delegatecall, so it is constructed with the same pool manager, revenue NFT,
/// launch support and template as the hook. The Migration Plan asserts that at deployment.
contract MilestoneColdPaths is MilestoneBase {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev This contract's own address, captured at construction — an immutable, so it is read from
    /// this contract's bytecode even while executing as the hook, and it occupies no storage slot and
    /// so does not enter the layout {MilestoneHook} has to match.
    address private immutable _self;

    /// @notice Thrown when an entry point is called directly rather than by DELEGATECALL from the hook.
    error NotDelegated();

    /// @dev Admits only invocations reached by DELEGATECALL. Under delegatecall `address(this)` is the
    /// calling contract; in a direct call it is this one. Equality therefore means "not delegated".
    modifier onlyDelegated() {
        if (address(this) == _self) revert NotDelegated();
        _;
    }

    constructor(
        IPoolManager poolManager_,
        RevenueNFT revenueNft_,
        LaunchSupport launchSupport_,
        ProtocolTemplate memory template_
    ) ImmutableState(poolManager_) MilestoneBase(revenueNft_, launchSupport_, template_) {
        _self = address(this);
    }

    // --- Launch (design Decision 19) ---

    /// @notice Launches a token from a creator-signed configuration. Permissionless to relay.
    ///
    /// @dev The creator is the configuration's *declared* creator, never the relayer — the revenue NFT,
    /// the vesting schedule and the dev-buy authorisation all key off that address, and the signature is
    /// verified against the declaration rather than being asked to produce it. Passing an empty signature
    /// selects the creator-direct path, where the declaration must equal `msg.sender` and no signature is
    /// required; both entries derive the same CREATE2 salt, so a creator who publishes a signed
    /// configuration and later self-launches lands at the advertised address either way.
    ///
    /// Ordering matters in three places:
    /// - The token is deployed before the `PoolKey` is built, since the key's `currency1` is its address.
    /// - Per-pool state is written *before* `initialize`, because `beforeInitialize` fires during it and
    ///   needs to recognise the pool as one of ours.
    /// - Genesis minting and the dev buy run last, under an explicit `unlock`, because
    ///   `modifyLiquidity` requires an unlocked manager and `initialize` does not unlock
    ///   (design Decision 5).
    ///
    /// Reached by delegatecall from {MilestoneHook.launch}, so `address(this)` is the hook throughout —
    /// including in the `PoolKey`'s `hooks` field, in the token's mint recipient, and in the
    /// `beforeInitialize` guard's `sender` comparison.
    function launch(LaunchConfig calldata config, bytes calldata signature)
        external
        payable
        onlyDelegated
        returns (PoolId poolId, address token, PoolKey memory key)
    {
        launchSupport.validate(config);

        address creator = config.creator;
        if (signature.length == 0) {
            // The direct path proves identity by transaction origin instead of by signature. Checking
            // the declaration rather than overwriting it keeps one address derivation for both entries.
            if (msg.sender != creator) revert LaunchSignature.CreatorMismatch(creator, msg.sender);
        } else {
            LaunchSignature.recoverCreator(config, signature, address(this));
        }
        bytes32 configHash = LaunchSignature.configHash(config);

        // Deployed through the immutable helper so its creation bytecode stays out of both contracts'
        // 24 KB budgets, and at a CREATE2 address so it is knowable before this transaction exists.
        // Verified rather than trusted: the supply must actually have landed here.
        token = launchSupport.deploy(
            config.name,
            config.symbol,
            config.totalSupply,
            address(this),
            LaunchSignature.tokenSalt(configHash, creator)
        );
        if (MilestoneToken(token).balanceOf(address(this)) != config.totalSupply) {
            revert TokenSupplyNotReceived(token);
        }

        // Native ETH is address(0), so it always sorts first: the launch token is always currency1 and
        // pool price is always token-per-ETH. That fixed orientation is what {Orientation} exists for.
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: Bounds.POOL_TICK_SPACING,
            hooks: IHooks(address(this))
        });
        poolId = key.toId();

        if (_pools[poolId].phase != Phase.NONE) revert PoolAlreadyLaunched(poolId);

        // The opening level is derived from the supply so every launch opens at the template's anchored
        // FDV (design Decision 16), rather than at a fixed price that would let a large supply open at
        // an absurd valuation.
        int24 opening = CurveLib.openingLevel(config.totalSupply, openingFdvWei);
        int24 far = CurveLib.farLevel(opening, curveSpanLevels);

        _recordLaunch(poolId, config, token, creator, opening, far);

        // A dynamic-fee pool opens at fee 0, so the base fee has to be pushed explicitly. Both of these
        // are callable without unlocking the manager.
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(Orientation.toTickChecked(opening)));
        poolManager.updateDynamicLPFee(key, baseFeeHundredthsBip);

        revenueNFT.mint(poolId, creator);

        emit Launched(poolId, creator, token, config.totalSupply, opening, far, configHash);
        emit LaunchConfigured(
            poolId,
            config.harvestSplit.creatorWad,
            config.harvestSplit.buybackWad,
            config.harvestSplit.protocolWad,
            config.harvestSplit.lpWad,
            config.devBuyShareWad,
            config.devBuyVestingSeconds
        );

        _openGenesis(poolId, key, token, config, creator);
    }

    /// @dev Writes the immutable per-pool launch shape and the initial mutable state.
    function _recordLaunch(
        PoolId poolId,
        LaunchConfig calldata config,
        address token,
        address creator,
        int24 opening,
        int24 far
    ) private {
        PoolState storage state = _pools[poolId];

        state.phase = Phase.BONDING_CURVE;
        state.creator = creator;
        state.token = token;
        state.launchedAt = uint64(block.timestamp);
        state.baseFeeHundredthsBip = baseFeeHundredthsBip;
        state.totalSupply = config.totalSupply;
        state.openingLevel = opening;
        state.farLevel = far;
        state.devBuyVestingSeconds = config.devBuyVestingSeconds;
        state.harvestSplit = config.harvestSplit;
        // Provisional; graduation overwrites it with the tick actually observed there.
        state.graduationLevel = far;
        state.ladderInventoryRemaining = LadderLib.ladderSupply(config.totalSupply, ladderSupplyShareWad);
    }

    /// @dev Runs the genesis unlock: mint curve position 0, then the dev buy if the creator sent this
    /// transaction themselves.
    ///
    /// The dev buy rides only the creator's own transaction (design Decision 19). On a relayed launch
    /// the share simply remains curve inventory, which is the specified outcome — recorded with
    /// {DevBuySkipped} rather than reverted, since the relayer has done nothing wrong. Any ETH a relayer
    /// attached is refunded.
    function _openGenesis(
        PoolId poolId,
        PoolKey memory key,
        address token,
        LaunchConfig calldata config,
        address creator
    ) private {
        uint256 devBuyTokens = (config.totalSupply * config.devBuyShareWad) / WAD;

        if (msg.sender != creator) {
            if (devBuyTokens != 0) emit DevBuySkipped(poolId, msg.sender, devBuyTokens);
            devBuyTokens = 0;
        } else if (devBuyTokens == 0 && msg.value != 0) {
            revert DevBuyEthWithoutDevBuy(msg.value);
        }

        bytes memory result = poolManager.unlock(abi.encode(uint8(UnlockAction.GENESIS), key, devBuyTokens, msg.value));
        uint256 ethSpent = abi.decode(result, (uint256));

        if (devBuyTokens != 0) {
            PoolState storage state = _pools[poolId];
            state.devBuyTotal = devBuyTokens;

            emit DevBuyExecuted(poolId, devBuyTokens, ethSpent, config.devBuyVestingSeconds);

            if (config.devBuyVestingSeconds == 0) {
                state.devBuyReleased = devBuyTokens;
                MilestoneToken(token).transfer(creator, devBuyTokens);
                emit DevBuyReleased(poolId, creator, devBuyTokens);
            }
        }

        uint256 refund = msg.value - ethSpent;
        if (refund != 0) _sendEth(msg.sender, refund);
    }

    // --- Graduation (design Decision 18) ---

    /// @notice Retires the bonding curve and activates the milestone ladder. Permissionless.
    ///
    /// @dev The gate is the pool's live tick, read at call time — not a flag, a timestamp, or anything
    /// recorded earlier. A pool that touched the far level and fell back has not graduated, and a
    /// reverted pump leaves nothing behind, because there is no state to leave.
    ///
    /// Anyone may call it: graduation moves value to a fixed template split, so there is nothing for a
    /// caller to steer. It races the `beforeSwap` auto-trigger and both are idempotent against the phase
    /// check, so whichever arrives second reverts having changed nothing.
    function graduate(PoolKey calldata key) external onlyDelegated {
        PoolId poolId = key.toId();
        _beginGraduation(poolId);

        TransientLock.enter(TransientLock.SETTLEMENT, poolId);
        poolManager.unlock(abi.encode(uint8(UnlockAction.GRADUATE), key));
        TransientLock.exit(TransientLock.SETTLEMENT, poolId);
    }

    /// @notice The same graduation, for a caller that already holds the manager's unlock.
    ///
    /// @dev design Decision 18's auto-trigger. Called by the hook's `beforeSwap` when the first swap
    /// after the far-level crossing arrives, so the limbo above `farLevel` — price beyond the curve's
    /// end, no liquidity above, nobody having paid to graduate — is closed by the first trader who wants
    /// that market. Above `farLevel` nobody *can* trade until graduation runs, so the payer is
    /// self-selecting and there is no bounty to steer.
    ///
    /// It cannot open its own `unlock` (v4 permits one at a time) and does not need to: `beforeSwap`
    /// runs before the triggering swap has created any delta, so the manager still holds every wei the
    /// curves earned and the LP seed's `take` is satisfiable. That is precisely why the *crossing* swap
    /// cannot graduate in its own `afterSwap` — there, Decision 13's shortfall applies.
    function graduateWhileUnlocked(PoolKey calldata key) external onlyDelegated {
        PoolId poolId = key.toId();
        _beginGraduation(poolId);

        TransientLock.enter(TransientLock.SETTLEMENT, poolId);
        _graduate(key);
        TransientLock.exit(TransientLock.SETTLEMENT, poolId);
    }

    /// @dev The checks and the phase flip, shared by both entries. Set before any pool interaction so a
    /// nested callback cannot observe a half-graduated pool, and so a second attempt in the same
    /// transaction fails the phase check.
    function _beginGraduation(PoolId poolId) private {
        PoolState storage state = _pools[poolId];

        if (state.phase != Phase.BONDING_CURVE) revert NotInBondingCurvePhase(poolId, state.phase);

        (, int24 tick,,) = poolManager.getSlot0(poolId);
        int24 currentLevel = Orientation.toLevel(tick);
        if (currentLevel < state.farLevel) revert FarLevelNotReached(currentLevel, state.farLevel);

        state.phase = Phase.GRADUATED;
        state.graduationLevel = currentLevel;
        state.graduatedAt = uint64(block.timestamp);
    }

    // --- Fee collection and routing ---

    /// @notice Realises the full-range position's accrued swap fees and routes them. Permissionless.
    ///
    /// @dev Anyone may call it, and there is nothing for a caller to steer: the destinations are the
    /// pool, the creator's ledger, the protocol's ledger and the milestone fund in fixed proportions,
    /// and the caller is paid nothing. What that buys is liveness — fee routing does not depend on the
    /// creator or the protocol remembering to trigger it.
    ///
    /// Returns before unlocking when there is nothing to collect, which is the whole of "repeated
    /// collection is harmless": with no accrual the call is two storage reads and a fee-growth
    /// comparison. `feeGrowthInside` equality is exact — fees owed are a multiple of the growth delta —
    /// so this declines only when the position really has earned nothing.
    ///
    /// Also the pre-graduation answer: `fullRangeLiquidity` is zero until the position is seeded, so a
    /// launch still on its bonding curve collects nothing and does not revert. Curve-phase fees are not
    /// lost, they are simply not collected here — they sit in the curve positions and fold into
    /// `quoteProceeds` when graduation burns them.
    function collectFees(PoolKey calldata key) external onlyDelegated returns (uint256 quoteFees, uint256 tokenFees) {
        PoolId poolId = key.toId();
        PoolState storage state = _pools[poolId];

        uint128 liquidity = state.fullRangeLiquidity;
        if (liquidity == 0) return (0, 0);

        int24 tickLower = state.fullRangeTickLower;
        int24 tickUpper = state.fullRangeTickUpper;
        (, uint256 inside0Last, uint256 inside1Last) =
            poolManager.getPositionInfo(poolId, address(this), tickLower, tickUpper, FULL_RANGE_SALT);
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);
        if (inside0 == inside0Last && inside1 == inside1Last) return (0, 0);

        TransientLock.enter(TransientLock.SETTLEMENT, poolId);
        bytes memory result = poolManager.unlock(abi.encode(uint8(UnlockAction.COLLECT_FEES), key));
        TransientLock.exit(TransientLock.SETTLEMENT, poolId);

        (quoteFees, tokenFees) = abi.decode(result, (uint256, uint256));

        // Emitted out here rather than inside the unlock, where `msg.sender` is the pool manager calling
        // back in. Under delegatecall from the hook it is still the original caller at this point.
        emit FeesCollected(poolId, msg.sender, quoteFees, tokenFees);
    }

    // --- Unlock dispatch ---

    /// @notice The unlock actions that live in this contract.
    ///
    /// @dev Called by delegatecall from {MilestoneHook.unlockCallback} after that function has checked
    /// the caller is the pool manager. The manager-only check deliberately stays in the hook: the hook is
    /// the address the manager knows, so it is the only place the check means anything. {onlyDelegated}
    /// here is a different assertion — it says this code is running as the hook, not that the caller is
    /// the manager. Together they mean an unlock action can only execute as the hook, at the manager's
    /// behest.
    ///
    /// Unknown actions revert, so an unrecognised payload fails closed.
    function dispatchUnlock(bytes calldata data) external onlyDelegated returns (bytes memory) {
        uint8 raw = uint8(uint256(bytes32(data[0:32])));

        if (raw == uint8(UnlockAction.GENESIS)) {
            (, PoolKey memory key, uint256 devBuyTokens, uint256 ethBudget) =
                abi.decode(data, (uint8, PoolKey, uint256, uint256));
            return abi.encode(_genesis(key, devBuyTokens, ethBudget));
        }

        if (raw == uint8(UnlockAction.GRADUATE)) {
            (, PoolKey memory key) = abi.decode(data, (uint8, PoolKey));
            _graduate(key);
            return "";
        }

        if (raw == uint8(UnlockAction.REDEEM_QUOTE)) {
            (, uint256 amount) = abi.decode(data, (uint8, uint256));
            _redeemQuote(amount);
            return "";
        }

        if (raw == uint8(UnlockAction.COLLECT_FEES)) {
            (, PoolKey memory key) = abi.decode(data, (uint8, PoolKey));
            (uint256 quoteFees, uint256 tokenFees) = _collectFees(key);
            return abi.encode(quoteFees, tokenFees);
        }

        revert UnknownUnlockAction();
    }

    /// @notice Converts `amount` of the hook's quote claim back into real ETH in hook custody.
    ///
    /// @dev The redemption half of Decision 13, reached only from {MilestoneBase-_ensureEth} on a claim.
    /// Being its own unlock is the whole point: no swap is in flight, so the manager holds every claim it
    /// has issued and `take` can be satisfied. Burning first and taking second means the delta is zero
    /// again by the end, so `CurrencyNotSettled` still backstops a mistake here.
    function _redeemQuote(uint256 amount) private {
        if (amount == 0) return;

        _burnClaim(CurrencyLibrary.ADDRESS_ZERO, amount);
        _takeCurrency(CurrencyLibrary.ADDRESS_ZERO, address(this), amount);
    }

    // --- Genesis ---

    /// @notice Mints bonding curve position 0 and, when the creator sent the launch, executes the dev buy.
    ///
    /// @dev design Decision 17's just-in-time curve: only position 0 exists when the launch transaction
    /// ends, so launch gas is independent of the template's position count. Position 0 spans the whole
    /// opening-to-far range holding a thirty-second of curve inventory, which is the thinnest book the
    /// curve ever offers — the structural anti-snipe that replaces the deleted fee decay (Decision 20).
    ///
    /// The dev buy runs the shared deployment path explicitly before swapping. It has to: the swap is
    /// issued by the hook itself, and v4 skips both swap callbacks when the hook is the swapper, so
    /// `beforeSwap` would never fire and the dev buy would sweep position 0 alone rather than the
    /// positions it actually consumes.
    function _genesis(PoolKey memory key, uint256 devBuyTokens, uint256 ethBudget) private returns (uint256 ethSpent) {
        PoolId poolId = key.toId();
        TransientLock.enter(TransientLock.LAUNCH, poolId);

        PoolState storage state = _pools[poolId];
        int24 opening = state.openingLevel;
        int24 far = state.farLevel;
        uint256 curveSupply = (state.totalSupply * curveSupplyShareWad) / WAD;

        uint128 liquidity = CurveLib.positionLiquidity(opening, far, curvePositions, curveSupply, 0);
        uint256 owed = _mintCurvePosition(key, opening, far, 0, liquidity);
        state.curveDeployed = 1;
        _settleCurrency(key.currency1, owed);

        emit CurvePositionsDeployed(poolId, 1, 1, owed);

        if (devBuyTokens != 0) {
            _deployCurveAhead(key, poolId, int256(devBuyTokens), TickMath.MIN_SQRT_PRICE + 1);
            ethSpent = _executeDevBuy(key, devBuyTokens, ethBudget);
        }

        TransientLock.exit(TransientLock.LAUNCH, poolId);
    }

    /// @notice Buys `devBuyTokens` for the creator against the freshly minted curve.
    ///
    /// @dev An exact-output swap, so the creator receives precisely the configured share of supply and
    /// pays whatever the curve charges for that quantity — including the pool's ordinary 1% fee, since
    /// Decision 20 removed the launch-window override the dev buy used to be exempt from. Because it
    /// consumes curve inventory and moves the price, the public raise shrinks proportionally.
    ///
    /// Returns the ETH actually spent so the caller can refund the remainder; the creator is never
    /// silently overcharged for supplying a generous budget.
    function _executeDevBuy(PoolKey memory key, uint256 devBuyTokens, uint256 ethBudget)
        private
        returns (uint256 ethSpent)
    {
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(devBuyTokens),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        ethSpent = uint256(uint128(-delta.amount0()));
        if (ethSpent > ethBudget) revert DevBuyEthInsufficient(ethBudget, ethSpent);

        _settleCurrency(key.currency0, ethSpent);
        _takeCurrency(key.currency1, address(this), uint256(uint128(delta.amount1())));
    }

    // --- Graduation internals ---

    /// @dev Burns the deployed curve positions, splits their quote proceeds, and seeds the locked
    /// full-range position. Runs entirely inside one unlock so the pool is never observable
    /// mid-transition.
    function _graduate(PoolKey memory key) private {
        PoolId poolId = key.toId();

        (uint256 quoteProceeds, uint256 tokenReturned, uint256 undeployedCurveTokens) = _burnCurves(key, poolId);
        _seedFullRange(key, poolId, quoteProceeds, tokenReturned, undeployedCurveTokens);
    }

    /// @dev Burns every *deployed* curve position and collects principal plus accrued fees.
    ///
    /// Undeployed positions are not an omission: their token was never settled into the manager, so it
    /// is already in hook custody, and the third return value is how much — reported so the caller can
    /// credit it to the ladder rather than leave it as untracked surplus. That satisfies the
    /// `graduation` requirement that unbought curve inventory become ladder inventory whether or not
    /// the price ever reached the position holding it.
    ///
    /// The nominal per-position amount is used for that figure rather than what was actually settled.
    /// v4 charges at most the nominal amount (liquidity floors, then the charge is the ceiling of what
    /// that liquidity needs), so subtracting nominal amounts under-counts what is really there — the
    /// safe direction, since over-counting would let a band mint attempt a transfer the balance cannot
    /// cover.
    function _burnCurves(PoolKey memory key, PoolId poolId)
        private
        returns (uint256 quote, uint256 token, uint256 undeployed)
    {
        PoolState storage state = _pools[poolId];
        uint32 deployedBits = state.curveDeployed;
        int24 opening = state.openingLevel;
        int24 far = state.farLevel;
        uint16 positions = curvePositions;
        uint256 curveSupply = (state.totalSupply * curveSupplyShareWad) / WAD;

        int256 delta0;
        int256 delta1;
        uint256 deployedNominal;

        for (uint256 i = 0; i < positions; i++) {
            if (deployedBits & (uint32(1) << uint8(i)) == 0) continue;

            deployedNominal += CurveLib.positionAmount(curveSupply, positions, i);
            (int128 d0, int128 d1) = _burnCurvePosition(key, poolId, opening, far, i);
            delta0 += d0;
            delta1 += d1;
        }

        // Burning can only credit the hook, so both deltas are non-negative here.
        quote = delta0 > 0 ? uint256(delta0) : 0;
        token = delta1 > 0 ? uint256(delta1) : 0;
        undeployed = curveSupply > deployedNominal ? curveSupply - deployedNominal : 0;
    }

    /// @dev One curve position, in its own frame to keep {_burnCurves} inside the stack limit.
    ///
    /// Liquidity is read back from the pool rather than recomputed. Both would agree today, but reading
    /// is authoritative: it burns exactly what exists, so a rounding difference could never leave a
    /// sliver of a curve position alive.
    function _burnCurvePosition(PoolKey memory key, PoolId poolId, int24 opening, int24 far, uint256 index)
        private
        returns (int128 amount0Delta, int128 amount1Delta)
    {
        int24 start = CurveLib.positionStart(opening, far, curvePositions, index);
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(start, far);
        bytes32 salt = curvePositionSalt(index);

        uint128 liquidity = poolManager.getPositionLiquidity(
            poolId, Position.calculatePositionKey(address(this), tickLower, tickUpper, salt)
        );
        if (liquidity == 0) return (0, 0);

        // A negative delta burns; the returned delta carries principal and accrued fees together, which
        // is how the graduation split ends up including curve fees without accounting for them apart.
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: salt
            }),
            ""
        );
        return (delta.amount0(), delta.amount1());
    }

    /// @dev Splits quote proceeds per the template, mints the full-range position, and nets settlement.
    ///
    /// The position spans the whole usable tick range and there is no code path anywhere in this
    /// protocol that removes liquidity from it — that absence, not a guard, is what "permanently locked"
    /// means here.
    ///
    /// Every token the curves released, plus every token their undeployed siblings never used, joins
    /// `carriedInventory`: it is ladder funding, and the `graduation` spec requires it reach the ladder
    /// rather than a recipient.
    function _seedFullRange(
        PoolKey memory key,
        PoolId poolId,
        uint256 quoteProceeds,
        uint256 tokenReturned,
        uint256 undeployedCurveTokens
    ) private {
        PoolState storage state = _pools[poolId];

        uint256 lpSeedQuote = (quoteProceeds * lpSeedWad) / WAD;
        uint256 creatorQuote = (quoteProceeds * proceedsCreatorWad) / WAD;
        uint256 protocolQuote = quoteProceeds - lpSeedQuote - creatorQuote;

        int24 tickLower = -Bounds.FULL_RANGE_TICK_BOUND;
        int24 tickUpper = Bounds.FULL_RANGE_TICK_BOUND;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            lpSeedQuote,
            (state.totalSupply * fullRangeSupplyShareWad) / WAD
        );

        int256 owed0;
        int256 owed1;
        if (liquidity != 0) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: FULL_RANGE_SALT
                }),
                ""
            );
            owed0 = delta.amount0();
            owed1 = delta.amount1();

            state.fullRangeLiquidity = liquidity;
            state.fullRangeTickLower = tickLower;
            state.fullRangeTickUpper = tickUpper;
        }

        // Net the burn credits against the seed obligations, then settle once per currency. Whatever the
        // seed could not use stays in hook custody, which is where the creator and protocol shares are
        // paid from.
        _netSettle(key.currency0, int256(quoteProceeds) + owed0);
        _netSettle(key.currency1, int256(tokenReturned) + owed1);

        state.carriedInventory += tokenReturned + undeployedCurveTokens;

        _accrueCreator(poolId, creatorQuote, AccrualSource.CURVE_PROCEEDS);
        _accrueProtocol(poolId, protocolQuote, AccrualSource.CURVE_PROCEEDS);

        emit Graduated(
            poolId, state.graduationLevel, quoteProceeds, lpSeedQuote, creatorQuote, protocolQuote, liquidity
        );
    }

    // --- Fee collection internals ---

    /// @notice Realises the full-range position's accrued fees and hands them to the waterfall.
    ///
    /// @dev design Decision 9 (revised). A zero-delta `modifyLiquidity` is v4's collect:
    /// `Position.update` computes fees owed from the position's *existing* liquidity and skips the
    /// principal branch entirely when the delta is zero, so this realises every wei the position has
    /// earned while leaving its liquidity, its bounds and the tick bitmap untouched. "Net position is
    /// preserved" is then not an outcome to check but a property of the call — nothing was removed to
    /// have to put back.
    ///
    /// v4 routes a zero delta to `beforeRemoveLiquidity`, where the hook's guard admits `address(this)`.
    function _collectFees(PoolKey memory key) private returns (uint256 quoteFees, uint256 tokenFees) {
        PoolId poolId = key.toId();
        PoolState storage state = _pools[poolId];

        (, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: state.fullRangeTickLower,
                tickUpper: state.fullRangeTickUpper,
                liquidityDelta: 0,
                salt: FULL_RANGE_SALT
            }),
            ""
        );

        // Fees can only ever credit the hook, but read defensively so a negative value could not be cast
        // into an enormous positive one and routed.
        int128 fee0 = feesAccrued.amount0();
        int128 fee1 = feesAccrued.amount1();
        quoteFees = fee0 > 0 ? uint256(uint128(fee0)) : 0;
        tokenFees = fee1 > 0 ? uint256(uint128(fee1)) : 0;
        if (quoteFees == 0 && tokenFees == 0) return (0, 0);

        _routeFees(key, poolId, state, quoteFees, tokenFees);
    }

    /// @notice Routes collected fees per currency: the quote side three ways, the token side entirely
    /// into pool-facing destinations.
    ///
    /// @dev design Decision 21. Token fees paid to a creator or to the protocol were income those
    /// parties could only realise by selling against their own holders, and the protocol has no use for
    /// a token balance it will never act on. So the token side splits between the milestone fund — the
    /// next band's inventory — and full-range compounding, and *nothing* on that side reaches a
    /// claimant. Creators earn ETH; token fees build walls and liquidity.
    ///
    /// Diversion happens first and only on the token side: band inventory is token offered for sale, so
    /// quote fees could only fund one by buying token, and the `milestone-ladder` requirement that
    /// inventory accrue "with no swap performed and no price impact" rules that out. Past the ladder cap
    /// there is no next band to fund, so diversion stops and the whole token amount compounds.
    function _routeFees(
        PoolKey memory key,
        PoolId poolId,
        PoolState storage state,
        uint256 quoteFees,
        uint256 tokenFees
    ) private {
        uint256 diverted;
        if (
            tokenFees != 0
                && LadderLib.withinLadderCap(
                    coreBandCount, state.nextBandIndex, state.feeFundedBandsCreated, maxFeeFundedBands
                )
        ) {
            diverted = (tokenFees * milestoneFundShareWad) / WAD;
            if (diverted != 0) state.milestoneFundAccrued += diverted;
        }

        uint256 creator0 = (quoteFees * Bounds.FEE_CREATOR_SHARE_WAD) / WAD;
        uint256 protocol0 = (quoteFees * Bounds.FEE_PROTOCOL_SHARE_WAD) / WAD;
        // The LP share takes the remainder rather than its own wad, so the three parts sum to the
        // collected amount exactly and integer-division dust lands in the pool.
        uint256 lp0 = quoteFees - creator0 - protocol0;
        uint256 lp1 = tokenFees - diverted;

        _accrueCreator(poolId, creator0, AccrualSource.SWAP_FEES);
        _accrueProtocol(poolId, protocol0, AccrualSource.SWAP_FEES);

        // The LP share joins whatever an earlier collection could not pair off, and the pair compounds.
        uint256 offered0 = state.pendingLpQuote + lp0;
        uint256 offered1 = state.pendingLpToken + lp1;
        (uint128 added, uint256 used0, uint256 used1) = _compoundFees(key, poolId, state, offered0, offered1);
        state.pendingLpQuote = offered0 - used0;
        state.pendingLpToken = offered1 - used1;

        // Whatever did not become liquidity leaves the manager: the ledgers owe real balances, the
        // milestone fund has to hold real token to mint a band from, and the unpaired LP share waits in
        // custody. A negative net is the case where this collection compounded more than it collected,
        // spending an earlier collection's carried balance — which is in custody, so settling it from
        // there is exact.
        _netSettle(key.currency0, int256(quoteFees) - int256(used0));
        _netSettle(key.currency1, int256(tokenFees) - int256(used1));

        emit FeesRouted(poolId, lp0, lp1, creator0, protocol0, diverted, added);
    }

    /// @notice Turns as much of the offered LP share as pairs at spot into full-range liquidity.
    ///
    /// @dev This is where "the LP share compounds" becomes true of `liquidity` rather than of fees owed:
    /// the share is added as *principal* to the same position, under the same salt, so it is thereafter
    /// indistinguishable from the graduation seed and equally locked.
    ///
    /// It needs both currencies, and a single collection's fees are generally lopsided — v4 charges the
    /// fee on the swap's input, so buys pay in quote and sells pay in token. Rather than swap to balance
    /// (price impact, and a swap inside a fee collection) or donate the excess (which would be re-split
    /// on the next collection, taxing the same value repeatedly), the unpaired remainder stays in
    /// custody as `pendingLp*` and is offered again next time. Over a two-sided market both sides
    /// arrive, so all of it compounds eventually.
    ///
    /// `used0`/`used1` cannot exceed what was offered: `getLiquidityForAmounts` floors the liquidity each
    /// side could support and takes the smaller, and v4 then charges `ceil` of the amounts that liquidity
    /// needs — and `ceil(floor(x/d)*d) <= x` for integer `x`. So the subtractions in the caller are safe,
    /// and left as plain subtraction so that a mistake in that reasoning reverts a collection rather than
    /// silently mis-stating what is still owed to the position.
    function _compoundFees(PoolKey memory key, PoolId poolId, PoolState storage state, uint256 amount0, uint256 amount1)
        private
        returns (uint128 added, uint256 used0, uint256 used1)
    {
        if (amount0 == 0 || amount1 == 0) return (0, 0, 0);

        int24 tickLower = state.fullRangeTickLower;
        int24 tickUpper = state.fullRangeTickUpper;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        added = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        if (added == 0) return (0, 0, 0);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(added)),
                salt: FULL_RANGE_SALT
            }),
            ""
        );

        // Adding liquidity in range can only ever owe both currencies, never credit them.
        int128 owed0 = delta.amount0();
        int128 owed1 = delta.amount1();
        used0 = owed0 < 0 ? uint256(uint128(-owed0)) : 0;
        used1 = owed1 < 0 ? uint256(uint128(-owed1)) : 0;

        state.fullRangeLiquidity += added;
    }
}
