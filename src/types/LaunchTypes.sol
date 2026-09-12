// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Fixed-point unit for every share in this protocol. All `*Wad` fields are fractions of this value,
// so a set of shares "summing to one whole unit" means summing to exactly WAD.
uint256 constant WAD = 1e18;

// Pool fee denominator used by v4 (`LPFeeLibrary.MAX_LP_FEE`): 1e6 == 100%.
uint24 constant FEE_DENOMINATOR = 1_000_000;

/// @notice Lifecycle phase of a pool. Advances one way only, and never leaves the pool.
/// @dev `NONE` means "not a launch of ours", which is what makes the `beforeInitialize` guard work.
enum Phase {
    NONE,
    BONDING_CURVE,
    GRADUATED
}

/// @notice Everything a creator signs, and the whole of what varies between launches.
///
/// @dev Launch economics are selected only through the exact registry bitset in `payoutPlan`.
/// Geometry, the static trading fee, graduation economics, and payout-plugin terms are protocol-defined.
///
/// `creator` is *declared* rather than inferred, and the signature is checked against it. Recovery alone
/// could not reject an altered configuration — it would simply yield some other address and attribute
/// the launch to it — so the declared field is what turns "a relayer modified a field" into a revert
/// rather than into a silently misattributed token. It also makes the launch's CREATE2 address derivable
/// from the configuration on its own, with no signature to recover first.
///
/// `deadline` is signed but deliberately excluded from the CREATE2 salt (design Decision 19, revision),
/// so a configuration whose signature lapsed can be re-signed and still lands at the address its token
/// page has advertised since creation.
struct LaunchConfig {
    address creator;
    string name;
    string symbol;
    /// @dev Off-chain metadata location stored verbatim as the token's {MilestoneToken.tokenURI}.
    string uri;
    uint256 totalSupply;
    uint64 devBuyShareWad;
    uint256 payoutPlan;
    uint256 deadline;
}

/// @notice The launch shape, fixed once at protocol deployment and identical for every launch.
///
/// @dev design Decision 16. The launch validator was the whole of the protocol's trust surface
/// (Decision 10) and had grown to guard configurations no buyer ever priced differently — geometry
/// knobs whose degenerate values are pure foot-guns. One audited template is the Virtuals posture:
/// uniform terms, comparable launches, publishable economics.
///
/// Passed as a constructor argument rather than declared as constants so the numbers are visible in
/// the deployment transaction and can be changed by redeploying the protocol — which is the only way
/// anything changes in v1. The fields are unpacked into immutables by {MilestoneBase}, so reading them
/// on the swap path costs no storage access.
///
/// The hook and both delegatecall satellites must be constructed with the *same* template: an immutable
/// resolves from the executing contract's own bytecode even under delegatecall, so a mismatch would make
/// the three implementations disagree at runtime. Deployment verifies this parity before any launch.
struct ProtocolTemplate {
    // --- Opening valuation (Decision 16) ---
    /// @dev Every launch opens at this ETH-denominated fully diluted valuation, whatever its supply.
    uint256 openingFdvWei;
    // --- Bonding curve shape (Decision 17) ---
    /// @dev Nested single-sided positions; position `i` spans `[opening + i*span/n, far]`.
    uint16 curvePositions;
    /// @dev Level distance from the opening level to the far (graduation) level.
    int24 curveSpanLevels;
    // --- Ladder geometry ---
    /// @dev The first step above graduation and the per-step decay are template fields while the floor
    /// is `bandLevelSpacing`: band `i+1` starts `max(bandLevelSpacing, bandFirstStepLevels -
    /// bandStepDecayLevels*i)` levels above band `i`, so early milestones sit at wide market-cap
    /// multiples and later ones settle at the floor's constant 1.2504x ratio.
    int24 bandLevelSpacing;
    int24 bandFirstStepLevels;
    int24 bandStepDecayLevels;
    int24 bandWidthLevels;
    uint8 coreBandCount;
    uint8 maxFeeFundedBands;
    // --- Supply split. The three shares sum to WAD. ---
    uint64 curveSupplyShareWad;
    uint64 ladderSupplyShareWad;
    uint64 fullRangeSupplyShareWad;
    // --- Graduation proceeds split. The three shares sum to WAD. ---
    uint64 lpSeedWad;
    uint64 proceedsCreatorWad;
    uint64 proceedsProtocolWad;
    // --- Static trading fee ---
    uint24 tradingFeeHundredthsBip;
    // --- Per-swap work caps (Decision 15, Decision 4 revised) ---
    uint8 bandInventoryCapMultiple;
    uint8 maxDeploysPerSwap;
    uint8 maxHarvestsPerSwap;
}

/// @notice Per-pool protocol state, keyed by `PoolId` in the hook.
///
/// @dev Band and curve geometry are not stored: they are derived on demand from the immutable template
/// plus `openingLevel` and `graduationLevel`. What needs storage is which positions exist and which are
/// finished, which is what the three bitmaps are (design Decision 4, revised).
struct PoolState {
    Phase phase;
    address creator;
    address token;
    uint64 launchedAt;
    uint64 graduatedAt;
    uint256 totalSupply;
    int24 openingLevel;
    int24 farLevel;
    /// @dev Exact immutable registry bitset selected by the creator.
    uint256 payoutPlan;
    // --- Bonding curve progress ---
    /// @dev One bit per template curve position. Position 0 is set at genesis; the rest are set as the
    /// simulated swap path reaches them (Decision 15).
    uint32 curveDeployed;
    // --- Ladder progress ---
    int24 graduationLevel;
    /// @dev One bit per band index. `deployedBands & ~completedBands` is the live set, which may hold
    /// several bands at once — the single-live-band invariant is superseded (Decision 4, revised).
    uint256 deployedBands;
    uint256 completedBands;
    /// @dev Lowest index that has never been deployed or skipped. Deployment order is strictly
    /// ascending, so nothing below this ever mints again.
    uint32 nextBandIndex;
    uint32 feeFundedBandsCreated;
    uint32 completedMilestones;
    // --- Inventory awaiting the next band: skipped bands and fee accrual ---
    uint256 ladderInventoryRemaining;
    uint256 carriedInventory;
    uint256 milestoneFundAccrued;
    // --- Full-range position, code-locked ---
    uint128 fullRangeLiquidity;
    int24 fullRangeTickLower;
    int24 fullRangeTickUpper;
    // --- Wall position, code-locked ---
    /// @dev Single-sided token-only reserve seeded at graduation from whatever the full-range seed did
    /// not consume. Its range starts one level above graduation and holds no currency0 by construction,
    /// so it can never owe the pool ETH; its principal converts to locked pool liquidity as price climbs.
    uint128 wallLiquidity;
    int24 wallTickLower;
    int24 wallTickUpper;
}

/// @notice Protocol-wide bounds every launch is validated against, plus the canonical template.
///
/// @dev Declared as constants rather than storage so no governance action can widen them. The remaining
/// launch-specific bounded choice is the immediate dev-buy share; payout-plan validity additionally
/// depends on immutable registry entries and is checked by {LaunchSupport}. Everything else belongs to
/// {ProtocolTemplate} or the controller's capped global economics.
library Bounds {
    /// @notice Pool tick spacing, fixed protocol-wide rather than configurable.
    ///
    /// @dev A spacing of 1 lets curve and band bounds sit at exactly the levels the geometry computes,
    /// with no rounding step between "the band the template describes" and "the position actually
    /// minted". That matters more here than the usual gas argument: band bounds are derived from a
    /// market-cap multiple (a 1.25x step is 2235 ticks, which is not a multiple of any conventional
    /// spacing), so any coarser spacing would silently move every band and make harvest levels
    /// disagree with the advertised milestones.
    int24 internal constant POOL_TICK_SPACING = 1;

    /// @notice Tick bounds of the graduation full-range position, derived from its market-cap range.
    ///
    /// @dev The position spans the price band from a $150B fully diluted valuation down to a $5,100 one
    /// at the reference $2,500/ETH: the expensive bound is level -28,135 and the cheap bound level
    /// -200,114, which in tick space (level = -tick) is `[FULL_RANGE_TICK_LOWER, FULL_RANGE_TICK_UPPER]`
    /// = `[28_135, 200_114]`. They are constants rather than derived per launch because total supply is
    /// pinned to {FIXED_TOTAL_SUPPLY} and the template anchors the opening and graduation FDVs, so the
    /// graduation tick is always 186,449 and always sits strictly inside these bounds — a property
    /// {MilestoneColdPaths.launch} asserts for every launch rather than assumes.
    ///
    /// The cheap bound doubles as the pool's hard price floor: the seed's entire ETH share sits between
    /// the graduation price and this tick, so once price reaches it the position is exhausted and
    /// nothing provides liquidity below. The narrow span is what concentrates that seed — the same ETH
    /// spread over the old near-unlimited range would backstop twice the distance at half the depth.
    int24 internal constant FULL_RANGE_TICK_LOWER = 28_135;
    int24 internal constant FULL_RANGE_TICK_UPPER = 200_114;

    /// @notice Level width of the wall position seeded at graduation above the full-range position.
    ///
    /// @dev The wall spans `[graduationLevel + 1, graduationLevel + WALL_WIDTH_LEVELS]` and absorbs every
    /// token the full-range seed did not consume, so its width sets how thinly that inventory is spread.
    /// At 880,000 levels the whole reserve sits at uniform liquidity across a range reaching roughly
    /// `1.0001^880000 ~ 1.6e38` times the graduation price — effectively unbounded above — which makes
    /// the wall permanent buy-side backing rather than a sellable treasury: only a thin layer sells per
    /// price move (about 7% of it by the top of the core ladder), and its converted principal stays
    /// locked in the pool exactly like the full-range position's.
    int24 internal constant WALL_WIDTH_LEVELS = 880_000;

    /// @notice The only total supply a launch may declare.
    ///
    /// @dev Supply determines the launch's opening and graduation levels from the template's anchored
    /// FDVs, and the full-range and wall bounds above are constants that assume the graduation tick this
    /// supply produces. Pinning supply makes that derivation a protocol invariant instead of a per-launch
    /// variable, and makes every launch's geometry directly comparable.
    uint256 internal constant FIXED_TOTAL_SUPPLY = 1_000_000_000 ether;

    /// @notice Level width of the first step above graduation: a 2x market-cap multiple
    /// (`1.0001^6932 ~= 2.0004`).
    ///
    /// @dev One level above the doubling width so the first milestone lands at or just above a clean 2x
    /// the graduation valuation. The schedule decays from here, per {BAND_STEP_DECAY_LEVELS}, down to
    /// {BAND_LEVEL_SPACING}.
    int24 internal constant BAND_FIRST_STEP_LEVELS = 6_932;

    /// @notice How many levels each successive step shrinks by, down to the {BAND_LEVEL_SPACING} floor.
    ///
    /// @dev With first step 6,932 and floor 2,235 the decay runs 12 shrinking steps (6,541 ... 2,240)
    /// before locking at the floor, so the 22-band core ladder opens at 2x graduation and tops out near
    /// 2,900x (~$58M at the reference ETH price) instead of the uniform schedule's ~$24M.
    int24 internal constant BAND_STEP_DECAY_LEVELS = 391;

    /// @notice Levels in a 2x market-cap step: `ln(2) / ln(1.0001)`.
    int24 internal constant LEVELS_PER_DOUBLING = 6931;

    /// @notice The ladder's uniform band spacing: a 1.25x market-cap step.
    ///
    /// @dev `ln(1.25) / ln(1.0001)` is 2231.4, and the specified value is 2235 — 1.2504x rather than
    /// 1.2500x, four ten-thousandths dearer per rung. The rounding is deliberate and is the number the
    /// `milestone-ladder` spec fixes, because it makes the spacing exactly five times the 447-level
    /// wall width: the wall is then a clean fifth of every gap rather than an awkward 447/2231.
    int24 internal constant BAND_LEVEL_SPACING = 2235;

    /// @notice Band width: a fifth of {BAND_LEVEL_SPACING}, roughly a 4.5% price band.
    int24 internal constant BAND_WIDTH_LEVELS = 447;

    // --- The only per-launch bounds left (Decision 16) ---

    /// @dev Against a thin nested book, a larger dev buy sweeps expensive bins and prices the creator's
    /// own entry (Decision 17).
    uint64 internal constant MAX_DEV_BUY_SHARE_WAD = 0.1e18;

    /// @notice Immutable static Uniswap v4 fee: 1% in hundredths of a bip.
    uint24 internal constant TRADING_FEE_HUNDREDTHS_BIP = 10_000;
    uint64 internal constant DEFAULT_HARVEST_SERVICE_FEE_WAD = 0.1e18;
    uint64 internal constant DEFAULT_QUOTE_CREATOR_SHARE_WAD = 0.75e18;
    uint64 internal constant DEFAULT_TOKEN_MILESTONE_FUND_SHARE_WAD = 1e18;
    uint64 internal constant MAX_HARVEST_SERVICE_FEE_WAD = 0.2e18;
    uint64 internal constant MAX_QUOTE_CREATOR_SHARE_WAD = 0.9e18;
    uint64 internal constant MAX_TOKEN_MILESTONE_FUND_SHARE_WAD = 1e18;

    // --- Published plugin-delivery gas constants (payout-plugins spec) ---

    /// @dev Conservative cover for the value-bearing `CALL` base, cold-account access, and the
    /// instructions between the preflight check and the opcode.
    uint256 internal constant CALL_FIXED_GAS = 15_000;

    /// @dev One worst-case carry restoration, aggregate/bitmap update, event, and loop step per
    /// unresolved call.
    uint256 internal constant POST_CALL_GAS = 100_000;

    /// @dev Creator credit, liability assertions, events, guard exit, and return.
    uint256 internal constant FINALIZE_GAS = 100_000;

    /// @dev Upper bound on a single untrusted plugin call and on the creator-path final transfer;
    /// registration rejects stipends above it.
    uint256 internal constant MAX_PLUGIN_CALL_GAS = 500_000;

    /// @dev Gas allowance for a flush's machinery outside the plugin calls: the redemption unlock,
    /// tip transfer, plan-walk base, events, and the closing solvency assertion. The unit suite
    /// measures real flushes against the ceiling built from this constant, so a change that widens
    /// the base path must raise it rather than let the ceiling go stale.
    uint256 internal constant FLUSH_BASE_GAS = 250_000;

    /// @notice The canonical protocol template (design Decision 16).
    ///
    /// @dev Not consulted by any protocol code path — the hook reads its own constructor-supplied
    /// immutables — but it is the single place the published numbers are written down, so the
    /// deployment script and the test fixtures cannot drift from each other or from the design.
    ///
    /// The ladder opens with a 2x step above graduation and decays by 391 levels per band to the
    /// 2,235-level (1.2504x) floor. 22 core bands carry that schedule to roughly 2,900x the graduation
    /// valuation (~$58M at the reference $2,500/ETH); up to 30 fee-funded extensions continue from there
    /// at the floor spacing. Supply is pinned to {FIXED_TOTAL_SUPPLY}: 25% trades the bonding curve, 10%
    /// funds the ladder, and 65% seeds the graduation full-range position and its wall reserve.
    function defaultTemplate() internal pure returns (ProtocolTemplate memory t) {
        t.openingFdvWei = 2 ether;

        t.curvePositions = 32;
        t.curveSpanLevels = 2 * LEVELS_PER_DOUBLING;

        t.bandLevelSpacing = BAND_LEVEL_SPACING;
        t.bandFirstStepLevels = BAND_FIRST_STEP_LEVELS;
        t.bandStepDecayLevels = BAND_STEP_DECAY_LEVELS;
        t.bandWidthLevels = BAND_WIDTH_LEVELS;
        t.coreBandCount = 22;
        t.maxFeeFundedBands = 30;

        t.curveSupplyShareWad = 0.25e18;
        t.ladderSupplyShareWad = 0.1e18;
        t.fullRangeSupplyShareWad = 0.65e18;

        t.lpSeedWad = 0.2e18;
        t.proceedsCreatorWad = 0.7e18;
        t.proceedsProtocolWad = 0.1e18;

        t.tradingFeeHundredthsBip = TRADING_FEE_HUNDREDTHS_BIP;
        t.bandInventoryCapMultiple = 2;

        t.maxDeploysPerSwap = 8;
        t.maxHarvestsPerSwap = 8;
    }

    /// @notice The default per-launch configuration, used by tests and deployment scripts as the
    /// canonical starting point.
    function defaultConfig(address creator_, string memory name_, string memory symbol_, uint256 totalSupply_)
        internal
        pure
        returns (LaunchConfig memory config)
    {
        config.creator = creator_;
        config.name = name_;
        config.symbol = symbol_;
        config.uri = "";
        config.totalSupply = totalSupply_;
        config.devBuyShareWad = 0;
        config.payoutPlan = 0;
        config.deadline = type(uint256).max;
    }
}
