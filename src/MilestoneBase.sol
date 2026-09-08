// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {RevenueNFT} from "./RevenueNFT.sol";
import {LaunchSupport} from "./LaunchSupport.sol";
import {CurveLib} from "./libraries/CurveLib.sol";
import {LadderLib} from "./libraries/LadderLib.sol";
import {Orientation} from "./libraries/Orientation.sol";
import {Phase, PoolState, ProtocolTemplate, WAD} from "./types/LaunchTypes.sol";

/// @title MilestoneBase
/// @notice Storage layout, the protocol template, the event and error surface, and the settlement
/// primitives shared by {MilestoneHook} and {MilestoneColdPaths}.
///
/// @dev This contract exists for one reason: {MilestoneColdPaths} runs by DELEGATECALL from the hook,
/// so it executes against the *hook's* storage. Both contracts therefore have to agree on the layout
/// to the slot. Inheriting the declarations from a single place makes them agree by construction
/// rather than by review — the only way to break it is to declare a state variable in one of the two
/// derived contracts, which `make layout-check` rejects in CI.
///
/// The {ProtocolTemplate} is unpacked into immutables here rather than held in storage, so reading
/// geometry on the swap path costs nothing. Immutables resolve from the *executing* contract's own
/// bytecode even under delegatecall, so both halves must be constructed with the same template; the
/// Migration Plan asserts that at deployment, alongside the pool manager and NFT addresses.
///
/// Also here: the just-in-time bonding curve deployment path, because both halves need it. The hook
/// runs it from `beforeSwap` for ordinary buys, and the cold path runs it around the genesis dev buy —
/// which is a hook self-swap, and v4 skips both swap callbacks when the hook is the swapper, so the
/// dev buy would otherwise deploy nothing.
///
/// Marked `abstract` because it is never deployed on its own.
abstract contract MilestoneBase is ImmutableState {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Actions the protocol performs while the pool manager is unlocked.
    /// @dev Every action routes through the hook's `unlockCallback`; unrecognised values fail closed.
    /// Test subclasses add their own actions from 200 upward so they cannot collide with these.
    enum UnlockAction {
        GENESIS,
        GRADUATE,
        REDEEM_QUOTE,
        COLLECT_FEES
    }

    /// @notice Which mechanism produced an accrual. Emitted for off-chain attribution only; routing
    /// does not branch on it.
    enum AccrualSource {
        CURVE_PROCEEDS,
        SWAP_FEES,
        MILESTONE_HARVEST
    }

    /// @notice Salt of the single full-range position seeded at graduation.
    /// @dev A hash rather than a small number so it can never collide with a curve position salt, which
    /// is a small index in the low bits.
    bytes32 public constant FULL_RANGE_SALT = keccak256("milestone-launchpad.full-range");

    /// @dev Top bit set, so a band salt can never coincide with a curve salt — whose highest set bit is
    /// below bit 8 for a 32-position template — nor with {FULL_RANGE_SALT}.
    uint256 private constant _BAND_SALT_TAG = 1 << 255;

    /// @notice The shared revenue NFT collection. One token per pool, `tokenId == PoolId`.
    RevenueNFT public immutable revenueNFT;

    /// @notice Stateless helper holding launch-time token deployment and config validation.
    /// @dev Kept external so neither the token's creation bytecode nor the bounds table occupies a
    /// 24 KB budget. It holds no authority; see {LaunchSupport}.
    LaunchSupport public immutable launchSupport;

    // --- The protocol template (design Decision 16), unpacked into immutables ---
    //
    // `internal` rather than `public` deliberately. Twenty-six generated getters is roughly 1.3 KB of
    // pure accessor bytecode, and every byte of it would be duplicated across both halves of the
    // delegatecall pair — against a 24 KB limit that design.md names as the leading structural risk.
    // {MilestoneHook.template} returns the whole struct in one call, which is what an integrator
    // wants anyway.

    uint256 internal immutable openingFdvWei;
    uint16 internal immutable curvePositions;
    int24 internal immutable curveSpanLevels;
    int24 internal immutable bandLevelSpacing;
    int24 internal immutable bandWidthLevels;
    uint8 internal immutable coreBandCount;
    uint8 internal immutable maxFeeFundedBands;
    uint64 internal immutable curveSupplyShareWad;
    uint64 internal immutable ladderSupplyShareWad;
    uint64 internal immutable fullRangeSupplyShareWad;
    uint64 internal immutable lpSeedWad;
    uint64 internal immutable proceedsCreatorWad;
    uint64 internal immutable proceedsProtocolWad;
    uint24 internal immutable baseFeeHundredthsBip;
    uint8 internal immutable feeStepOneAtCompletions;
    uint24 internal immutable feeStepOneFee;
    uint8 internal immutable feeStepTwoAtCompletions;
    uint24 internal immutable feeStepTwoFee;
    uint64 internal immutable milestoneFundShareWad;
    uint8 internal immutable bandInventoryCapMultiple;
    uint8 internal immutable maxDeploysPerSwap;
    uint8 internal immutable maxHarvestsPerSwap;
    uint64 internal immutable defaultCreatorWad;
    uint64 internal immutable defaultBuybackWad;
    uint64 internal immutable defaultProtocolWad;
    uint64 internal immutable defaultLpWad;

    /// @notice A digest of the whole template, computed once at construction.
    ///
    /// @dev Exposed by {templateHash} on both halves. Held as a digest of the constructor argument rather
    /// than reassembled from the twenty-six immutables on demand: the reassembling form compiled to 1.2 KB
    /// in *each* half of the delegatecall pair, which is bytecode neither can spare, while this costs one
    /// immutable read at runtime and a single keccak in initcode.
    bytes32 internal immutable templateDigest;

    // --- Storage. Order is load-bearing: see the contract-level comment. ---

    /// @notice Recipient of the protocol's share of harvests, fees, and curve proceeds.
    /// @dev The only mutable protocol-level state in v1 (Decision 10).
    address public protocolRecipient;

    /// @notice Per-pool lifecycle state.
    mapping(PoolId poolId => PoolState) internal _pools;

    /// @notice Creator's claimable ETH balance per pool, claimable by the current revenue NFT holder.
    /// @dev Quote-denominated only. Decision 21 deleted the token ledgers: token fees are routed to
    /// pool-facing destinations, so there is nothing left for a claimant to hold but ETH.
    mapping(PoolId poolId => uint256) internal _creatorClaimable;

    /// @notice Protocol's claimable ETH balance per pool.
    mapping(PoolId poolId => uint256) internal _protocolClaimable;

    /// @notice When each band index was minted, for observability.
    /// @dev With reclaim removed (Decision 22) nothing in the protocol reads this; it exists so an
    /// indexer can age a live band without replaying logs.
    mapping(PoolId poolId => mapping(uint256 index => uint64 deployedAt)) internal _bandDeployedAt;

    event ProtocolRecipientSet(address indexed recipient);

    /// @notice Emitted whenever ETH accrues to the creator's claimable balance.
    event CreatorAccrued(PoolId indexed poolId, uint256 amount, AccrualSource source);

    /// @notice Emitted whenever ETH accrues to the protocol's claimable balance.
    event ProtocolAccrued(PoolId indexed poolId, uint256 amount, AccrualSource source);

    event CreatorClaimed(PoolId indexed poolId, address indexed holder, uint256 amount);
    event ProtocolClaimed(PoolId indexed poolId, address indexed recipient, uint256 amount);

    /// @notice Emitted once per launch, carrying everything needed to reconstruct the pool's geometry
    /// off-chain without reading storage.
    /// @dev Band ticks need only this event's `openingLevel`, {Graduated}'s `graduationLevel`, and the
    /// template — which is immutable and published — so the ladder is recomputable from logs alone.
    event Launched(
        PoolId indexed poolId,
        address indexed creator,
        address indexed token,
        uint256 totalSupply,
        int24 openingLevel,
        int24 farLevel,
        bytes32 configHash
    );

    /// @notice Emitted alongside {Launched} with the launch's chosen routing.
    event LaunchConfigured(
        PoolId indexed poolId,
        uint64 creatorWad,
        uint64 buybackWad,
        uint64 protocolWad,
        uint64 lpWad,
        uint64 devBuyShareWad,
        uint32 devBuyVestingSeconds
    );

    /// @notice Emitted when a launch includes a dev buy, recording what it cost and what it bought.
    event DevBuyExecuted(PoolId indexed poolId, uint256 tokensBought, uint256 ethSpent, uint32 vestingSeconds);

    /// @notice Emitted when a relayed launch's dev buy was skipped because the relayer is not the creator.
    /// @dev The dev-buy share simply remains curve inventory, which is the specified outcome rather than
    /// an error — so it is recorded rather than reverted.
    event DevBuySkipped(PoolId indexed poolId, address indexed relayer, uint256 tokensRequested);

    /// @notice Emitted when vested dev-buy tokens are released to the creator.
    event DevBuyReleased(PoolId indexed poolId, address indexed creator, uint256 amount);

    /// @notice Emitted when a pool graduates, recording the split and the seeded position.
    event Graduated(
        PoolId indexed poolId,
        int24 graduationLevel,
        uint256 quoteProceeds,
        uint256 lpSeedQuote,
        uint256 creatorQuote,
        uint256 protocolQuote,
        uint128 fullRangeLiquidity
    );

    /// @notice Emitted when bonding curve positions are minted just in time ahead of a swap.
    /// @dev `deployed` is the full bitmap after the mint, so an indexer never has to accumulate.
    event CurvePositionsDeployed(PoolId indexed poolId, uint256 minted, uint32 deployed, uint256 tokenSettled);

    /// @notice Emitted when a band is minted just in time ahead of an approaching swap.
    /// @dev Carries the band's full geometry so an indexer never has to recompute the ladder to know what
    /// is live, and `tokenInventory` is what the position actually consumed rather than what was offered.
    event BandDeployed(
        PoolId indexed poolId,
        uint32 indexed index,
        int24 levelLower,
        int24 levelUpper,
        uint128 liquidity,
        uint256 tokenInventory
    );

    /// @notice Emitted when the price rose past a band that was never deployed.
    /// @dev Reachable only as the deploy cap's fallback under simulation-driven deployment
    /// (Decision 15). `carriedInventory` is the pool's carried total *after* the skip, so the "inventory
    /// survives a capped-out swap" requirement is observable from logs alone.
    event BandSkipped(PoolId indexed poolId, uint32 indexed index, uint256 carriedInventory);

    /// @notice Emitted when a swap carried the price to a deployed band's top, completing the milestone.
    /// @dev `quoteProceeds` is the burn's full quote credit, principal and accrued band fees together, so
    /// it is the exact amount {HarvestRouted} then divides. `tokenResidue` is whatever token the position
    /// still held, which is rounding dust for a band completed above its top.
    event MilestoneHarvested(
        PoolId indexed poolId,
        uint32 indexed index,
        uint256 quoteProceeds,
        uint256 tokenResidue,
        uint32 completedMilestones
    );

    /// @notice Emitted alongside {MilestoneHarvested} with where each share of the proceeds went.
    /// @dev The four amounts sum to the harvest's `quoteProceeds`. `buybackQuote` is what the nested swap
    /// actually spent rather than what its share nominally was, and any shortfall is folded into
    /// `lpAmount`, so the sum holds even when the swap fills partially.
    event HarvestRouted(
        PoolId indexed poolId,
        uint32 indexed index,
        uint256 creatorAmount,
        uint256 buybackQuote,
        uint256 tokensBurned,
        uint256 protocolAmount,
        uint256 lpAmount
    );

    /// @notice Emitted when the permissionless path realises the full-range position's accrued swap fees.
    /// @dev The amounts are what the position had accrued, *before* any diversion or routing, so this event
    /// and {FeesRouted} together account for every wei.
    event FeesCollected(PoolId indexed poolId, address indexed caller, uint256 quoteFees, uint256 tokenFees);

    /// @notice Emitted alongside {FeesCollected} with where the collected fees went.
    ///
    /// @dev `lpQuote`/`lpToken` are the LP share as routed, not the part that became liquidity this call:
    /// what could not be paired at spot stays in `pendingLpQuote`/`pendingLpToken` for the next collection,
    /// and `liquidityAdded` is what the pairing actually minted. There are no token-denominated creator or
    /// protocol amounts, because Decision 21 routes the whole token side to the fund and the pool.
    event FeesRouted(
        PoolId indexed poolId,
        uint256 lpQuote,
        uint256 lpToken,
        uint256 creatorQuote,
        uint256 protocolQuote,
        uint256 divertedToNextBand,
        uint128 liquidityAdded
    );

    /// @notice Emitted when a milestone completion steps the stored base fee down.
    /// @dev Only emitted when the value actually changes, so its absence across a harvest is itself the
    /// observable form of "the base fee is unchanged between thresholds".
    event BaseFeeStepped(PoolId indexed poolId, uint32 completedMilestones, uint24 previousFee, uint24 newFee);

    error NotProtocolAdmin();
    error ZeroAddress();
    error NotAContract(address target);
    error NotRevenueNftHolder(PoolId poolId, address caller);
    error NotProtocolRecipient(address caller);
    error EthTransferFailed(address to, uint256 amount);
    error NotPoolManagerUnlock();
    error UnknownUnlockAction();
    error PoolAlreadyLaunched(PoolId poolId);
    error InitializerNotLaunchPath(address sender);
    error ExternalLiquidityNotAllowed(address sender);
    error TokenSupplyNotReceived(address token);
    error DevBuyEthInsufficient(uint256 provided, uint256 required);
    error DevBuyEthWithoutDevBuy(uint256 provided);
    error NotCreator(PoolId poolId, address caller);
    error NotInBondingCurvePhase(PoolId poolId, Phase phase);
    error FarLevelNotReached(int24 currentLevel, int24 farLevel);
    error InvalidTemplate();

    /// @dev `ImmutableState`'s constructor argument is deliberately *not* supplied here. {MilestoneHook}
    /// gets it from `BaseHook`, which also validates the mined hook address; {MilestoneColdPaths} passes
    /// it directly. Supplying it here would make one of those a duplicate initialisation.
    ///
    /// The template is sanity-checked rather than trusted. It is set once, for the life of the protocol,
    /// and a zero band count or a supply split that does not partition the supply would not fail at
    /// deployment — it would fail at some pool's first harvest. Better here.
    constructor(RevenueNFT revenueNft_, LaunchSupport launchSupport_, ProtocolTemplate memory template_) {
        if (address(revenueNft_) == address(0)) revert ZeroAddress();
        if (address(launchSupport_) == address(0)) revert ZeroAddress();

        revenueNFT = revenueNft_;
        launchSupport = launchSupport_;

        if (
            template_.openingFdvWei == 0 || template_.curvePositions == 0 || template_.curvePositions > 32
                || template_.curveSpanLevels <= 0 || template_.coreBandCount == 0 || template_.bandLevelSpacing <= 0
                || template_.bandWidthLevels <= 0 || template_.bandWidthLevels >= template_.bandLevelSpacing
                || template_.bandInventoryCapMultiple == 0 || template_.maxDeploysPerSwap == 0
                || template_.maxHarvestsPerSwap == 0 || uint256(template_.coreBandCount) + template_.maxFeeFundedBands > 256
                || uint256(template_.curveSupplyShareWad) + template_.ladderSupplyShareWad
                    + template_.fullRangeSupplyShareWad != WAD
                || uint256(template_.lpSeedWad) + template_.proceedsCreatorWad + template_.proceedsProtocolWad != WAD
        ) revert InvalidTemplate();

        openingFdvWei = template_.openingFdvWei;
        curvePositions = template_.curvePositions;
        curveSpanLevels = template_.curveSpanLevels;
        bandLevelSpacing = template_.bandLevelSpacing;
        bandWidthLevels = template_.bandWidthLevels;
        coreBandCount = template_.coreBandCount;
        maxFeeFundedBands = template_.maxFeeFundedBands;
        curveSupplyShareWad = template_.curveSupplyShareWad;
        ladderSupplyShareWad = template_.ladderSupplyShareWad;
        fullRangeSupplyShareWad = template_.fullRangeSupplyShareWad;
        lpSeedWad = template_.lpSeedWad;
        proceedsCreatorWad = template_.proceedsCreatorWad;
        proceedsProtocolWad = template_.proceedsProtocolWad;
        baseFeeHundredthsBip = template_.baseFeeHundredthsBip;
        feeStepOneAtCompletions = template_.feeStepOneAtCompletions;
        feeStepOneFee = template_.feeStepOneFee;
        feeStepTwoAtCompletions = template_.feeStepTwoAtCompletions;
        feeStepTwoFee = template_.feeStepTwoFee;
        milestoneFundShareWad = template_.milestoneFundShareWad;
        bandInventoryCapMultiple = template_.bandInventoryCapMultiple;
        maxDeploysPerSwap = template_.maxDeploysPerSwap;
        maxHarvestsPerSwap = template_.maxHarvestsPerSwap;
        defaultCreatorWad = template_.defaultCreatorWad;
        defaultBuybackWad = template_.defaultBuybackWad;
        defaultProtocolWad = template_.defaultProtocolWad;
        defaultLpWad = template_.defaultLpWad;

        templateDigest = keccak256(abi.encode(template_));
    }

    // --- Position salts ---
    //
    // Deterministic, so every path that touches a position recomputes its salt rather than storing it.
    // The three families are disjoint by construction, which is what lets curve burning, band harvest,
    // and the locked full-range position coexist over overlapping tick ranges.

    /// @notice Position salt for bonding curve position `index`.
    function curvePositionSalt(uint256 index) public pure returns (bytes32) {
        return bytes32(index);
    }

    /// @notice Position salt for band `index`.
    function bandSalt(uint256 index) public pure returns (bytes32) {
        return bytes32(_BAND_SALT_TAG | index);
    }

    // --- Claim ledger ---
    //
    // Accrual and payout are deliberately separate. Every routing path credits a balance here and
    // returns; nothing is ever pushed to a creator or to the protocol during settlement. That is what
    // makes a harvest independent of whether the recipient is an EOA, a contract that reverts on
    // receive, or a contract that would try to re-enter.

    /// @notice Credits the creator's claimable balance for a pool.
    /// @dev Internal-only: there is no external accrual entry point, so no caller can inflate a
    /// balance. Callers are the graduation split, the fee waterfall, and harvest routing.
    function _accrueCreator(PoolId poolId, uint256 amount, AccrualSource source) internal {
        if (amount == 0) return;

        _creatorClaimable[poolId] += amount;
        emit CreatorAccrued(poolId, amount, source);
    }

    /// @notice Credits the protocol's claimable balance for a pool.
    function _accrueProtocol(PoolId poolId, uint256 amount, AccrualSource source) internal {
        if (amount == 0) return;

        _protocolClaimable[poolId] += amount;
        emit ProtocolAccrued(poolId, amount, source);
    }

    /// @dev Native ETH payout. Uses `call` rather than `transfer` so recipients are not bound to the
    /// 2300-gas stipend, which would break contract holders of the revenue NFT. Safe because the
    /// balance is already zeroed at this point.
    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed(to, amount);
    }

    // --- Pool manager settlement ---
    //
    // Custody is direct (design Decision 2), so every interaction with the manager ends with the
    // hook's delta netted to zero. `CurrencyNotSettled` from core is the backstop: if any of these
    // pairings is wrong, the enclosing unlock reverts rather than silently stranding value.

    /// @notice Pays the manager what the hook owes in `currency`.
    /// @dev Native ETH goes out as call value. ERC20 needs the `sync` -> transfer -> `settle`
    /// sequence, because the manager derives the settled amount from its own balance delta and must
    /// checkpoint that balance before the tokens arrive.
    function _settleCurrency(Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            currency.transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    /// @notice Withdraws `amount` of `currency` from the manager to `to`, creating a debt that the
    /// caller must settle before the unlock ends.
    function _takeCurrency(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;

        poolManager.take(currency, to, amount);
    }

    /// @dev Takes a positive net delta into custody, settles a negative one from custody.
    function _netSettle(Currency currency, int256 net) internal {
        if (net > 0) {
            _takeCurrency(currency, address(this), uint256(net));
        } else if (net < 0) {
            _settleCurrency(currency, uint256(-net));
        }
    }

    // --- Claim-token custody (design Decision 13) ---
    //
    // `take` moves *real* currency, so it can only ever withdraw what the manager physically holds. Inside
    // a swap callback that is a hard constraint rather than a detail: the swapper has not settled its input
    // yet — v4 collects that after `swap` returns — so the manager's native balance is short by exactly the
    // amount of the swap in progress. A harvest triggered by a large buy is therefore *guaranteed* to be
    // unable to take its own proceeds, and would either revert or silently spend some other pool's float.
    //
    // ERC-6909 claims are the way out. Minting one converts the hook's credit into a persistent balance
    // *without moving any currency*, so it is always available; burning one converts it back into a credit
    // that offsets a debit in the same unlock. Value stays in the singleton, which is what claims are for,
    // and the redemption to real currency is deferred to {_ensureEth} on a path that is not mid-swap.

    /// @notice Converts a positive delta in `currency` into an ERC-6909 claim held by the hook.
    /// @dev Pure accounting: `mint` debits the delta and credits the claim, so nothing is transferred and
    /// the manager's balance is irrelevant. Usable inside a swap callback, unlike {_takeCurrency}.
    function _mintClaim(Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        poolManager.mint(address(this), currency.toId(), amount);
    }

    /// @notice Spends an ERC-6909 claim held by the hook, crediting its delta by `amount`.
    function _burnClaim(Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        poolManager.burn(address(this), currency.toId(), amount);
    }

    /// @notice Makes sure the hook holds at least `amount` of native ETH, redeeming claims if it does not.
    ///
    /// @dev The bridge between claim custody and the pull-payment paths, which owe real ETH. Accrued
    /// balances are backed by whichever the value happened to arrive as — raw ETH from a graduation, a
    /// claim from a harvest — and a claimant must not have to care which. Redeeming the shortfall rather
    /// than the whole claim keeps a single claim funding many partial claims.
    ///
    /// Native quote is an orientation invariant, so the claim being redeemed is always currency0's.
    function _ensureEth(uint256 amount) internal {
        uint256 held = address(this).balance;
        if (held >= amount) return;

        poolManager.unlock(abi.encode(uint8(UnlockAction.REDEEM_QUOTE), amount - held));
    }

    // --- Just-in-time bonding curve deployment (design Decisions 15 and 17) ---

    /// @notice Mints every undeployed curve position the incoming buy's simulated path will reach.
    ///
    /// @dev Declared here rather than in {MilestoneHook} because both halves call it. The hook runs it
    /// from `beforeSwap`; the cold path runs it around the genesis dev buy, which is a hook self-swap
    /// and therefore invisible to the hook's own swap callbacks.
    ///
    /// The walk is exact. Curve positions all terminate at the far level, so the in-range liquidity at
    /// any level is the sum of the deployed positions whose start is at or below it — computable from
    /// the bitmap and geometry with no `extsload`, since every position holds an equal token amount over
    /// a known span. From there each step is v4's own `SwapMath.computeSwapStep` on the same inputs
    /// `Pool.swap` is about to use.
    ///
    /// Nothing here may revert: it runs inside `beforeSwap`, where the specs forbid the hook from
    /// blocking a swap. Every step either mints or declines.
    ///
    /// @param amountSpecified The swap's own amount, in v4's sign convention.
    /// @param sqrtPriceLimitX96 The swap's own price limit, so a limited swap does not over-deploy.
    function _deployCurveAhead(PoolKey memory key, PoolId poolId, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
    {
        PoolState storage state = _pools[poolId];

        uint16 positions = curvePositions;
        int24 opening = state.openingLevel;
        int24 far = state.farLevel;
        uint256 curveSupply = (state.totalSupply * curveSupplyShareWad) / WAD;

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        uint256 index = CurveLib.firstPositionAbove(opening, far, positions, Orientation.toLevel(tick));
        if (index >= positions) return;

        uint32 deployedBits = state.curveDeployed;

        // In-range liquidity: every deployed position whose start sits at or below spot. Positions are
        // nested, so this is a prefix sum rather than a search.
        uint128 liquidity;
        for (uint256 i = 0; i < index; i++) {
            if (deployedBits & (uint32(1) << uint8(i)) != 0) {
                liquidity += CurveLib.positionLiquidity(opening, far, positions, curveSupply, i);
            }
        }

        LadderLib.Walk memory walk = LadderLib.Walk({
            sqrtPriceX96: sqrtPriceX96,
            amountRemaining: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            feePips: state.baseFeeHundredthsBip
        });

        uint256 minted;
        uint256 owed;

        for (; index < positions; index++) {
            int24 start = CurveLib.positionStart(opening, far, positions, index);
            if (start >= far) break;
            // The swap's budget or its price limit stops it below this position's start, so nothing at
            // or above it will be touched.
            if (!LadderLib.advance(walk, LadderLib.sqrtPriceAtLevel(start), liquidity)) break;

            uint128 positionLiquidity = CurveLib.positionLiquidity(opening, far, positions, curveSupply, index);

            if (deployedBits & (uint32(1) << uint8(index)) == 0 && positionLiquidity != 0) {
                owed += _mintCurvePosition(key, start, far, index, positionLiquidity);
                deployedBits |= (uint32(1) << uint8(index));
                minted += 1;
            }

            // Crossing the start makes the position active for the rest of the walk, whether it was
            // minted just now or on an earlier swap the price has since fallen back through.
            liquidity += positionLiquidity;
        }

        if (minted == 0) return;

        state.curveDeployed = deployedBits;
        _settleCurrency(key.currency1, owed);

        emit CurvePositionsDeployed(poolId, minted, deployedBits, owed);
    }

    /// @dev Mints one curve position and reports the token it owes, for the caller to settle in one go.
    ///
    /// Single-sided `currency1` by construction: the position's tick range is `[-far, -start]` and spot
    /// sits at or below `-start` in tick terms, so v4's accounting gives it no `currency0` obligation.
    /// A `currency0` debit here would be arithmetically unreachable, and `CurrencyNotSettled` on the
    /// enclosing unlock is the backstop if that reasoning is ever wrong.
    function _mintCurvePosition(PoolKey memory key, int24 start, int24 far, uint256 index, uint128 liquidity)
        internal
        returns (uint256 owed)
    {
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(start, far);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: curvePositionSalt(index)
            }),
            ""
        );

        int128 amount1 = delta.amount1();
        owed = amount1 < 0 ? uint256(uint128(-amount1)) : 0;
    }

    // --- Views ---

    /// @notice A digest of the template this deployment was constructed with.
    ///
    /// @dev Present on *both* halves, which is the point: an immutable resolves from the executing
    /// contract's own bytecode even while the satellite runs as the hook, so a hook and a satellite
    /// constructed with different templates would disagree at runtime — silently, since neither reads the
    /// other's copy. This is the handle the deployment gate compares to rule that out (Migration Plan
    /// step 4).
    ///
    /// `keccak256(abi.encode(template))`, so it is reproducible off-chain from the published struct with
    /// no knowledge of the field order the immutables happen to use.
    function templateHash() external view returns (bytes32) {
        return templateDigest;
    }
}
