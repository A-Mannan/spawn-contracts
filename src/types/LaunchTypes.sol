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

/// @notice Routing of a harvested milestone. Components sum to `WAD`.
/// @dev The one economic choice left to a creator (design Decision 16). Bounds from the `token-launch`
/// spec: `creatorWad <= 70%`, `buybackWad >= 10%`, `protocolWad >= 5%`.
struct HarvestSplit {
    uint64 creatorWad;
    uint64 buybackWad;
    uint64 protocolWad;
    uint64 lpWad;
}

/// @notice Everything a creator signs, and the whole of what varies between launches.
///
/// @dev design Decision 16 moved every launch-*shape* parameter into {ProtocolTemplate}: there is no
/// geometry here, no supply split, no fee schedule and no anti-snipe window, because a creator cannot
/// choose them. What remains is the creator's identity, token identity, the optional dev buy, and the
/// harvest split.
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
    uint256 totalSupply;
    uint64 devBuyShareWad;
    uint32 devBuyVestingSeconds;
    HarvestSplit harvestSplit;
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
/// Both the hook and its delegatecall satellite must be constructed with the *same* template: an
/// immutable resolves from the executing contract's own bytecode even under delegatecall, so a
/// mismatch would make the two halves disagree at runtime. The Migration Plan asserts this at
/// deployment.
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
    int24 bandLevelSpacing;
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
    // --- Fees ---
    uint24 baseFeeHundredthsBip;
    /// @dev Two permanent step-downs, scaled to the band count (Decision 8, revised). A zero threshold
    /// disables that step.
    uint8 feeStepOneAtCompletions;
    uint24 feeStepOneFee;
    uint8 feeStepTwoAtCompletions;
    uint24 feeStepTwoFee;
    // --- Milestone fund ---
    uint64 milestoneFundShareWad;
    uint8 bandInventoryCapMultiple;
    // --- Per-swap work caps (Decision 15, Decision 4 revised) ---
    uint8 maxDeploysPerSwap;
    uint8 maxHarvestsPerSwap;
    // --- Harvest split defaults, published for front-ends; a launch may choose within Bounds. ---
    uint64 defaultCreatorWad;
    uint64 defaultBuybackWad;
    uint64 defaultProtocolWad;
    uint64 defaultLpWad;
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
    /// @dev Current base fee. Milestone completions step it down, permanently.
    uint24 baseFeeHundredthsBip;
    // --- Launch shape, derived at launch from the template and the supply ---
    uint256 totalSupply;
    int24 openingLevel;
    int24 farLevel;
    uint32 devBuyVestingSeconds;
    HarvestSplit harvestSplit;
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
    // --- Dev buy vesting, hook-held ---
    uint256 devBuyTotal;
    uint256 devBuyReleased;
    // --- Full-range position, code-locked ---
    uint128 fullRangeLiquidity;
    int24 fullRangeTickLower;
    int24 fullRangeTickUpper;
    /// @dev The LP share of collected fees that could not yet be turned into liquidity, held in hook
    /// custody until the other currency catches up. A full-range position takes both currencies in the
    /// ratio spot implies, but fees arrive in whichever currency traders paid in — so the LP share of
    /// one collection is generally lopsided even though the pair balances out over many. Carrying the
    /// excess across collections is what lets all of it eventually compound; see design Decision 9.
    uint256 pendingLpQuote;
    uint256 pendingLpToken;
}

/// @notice Protocol-wide bounds every launch is validated against, plus the canonical template.
///
/// @dev Declared as constants rather than storage so no governance action can widen them. What lives
/// here after design Decision 16 is only what a launch can still *choose*: the dev buy and the harvest
/// split. Everything else moved into {ProtocolTemplate}.
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

    /// @notice Half-width of the "full range" position seeded at graduation.
    ///
    /// @dev Deliberately inside `TickMath.MIN_TICK`/`MAX_TICK` rather than equal to them. If the position
    /// spanned the literal extremes, a pool whose price had run to `MIN_SQRT_PRICE` would sit exactly on
    /// the position's lower bound, and the liquidity-for-amount1 formula divides by `sqrtP - sqrtLower` —
    /// one wei of denominator, an astronomically large liquidity, and a `SafeCastOverflow` that would
    /// make graduation revert forever.
    ///
    /// That price is reachable: nothing provides liquidity above `farLevel` until graduation runs, so a
    /// buy large enough to consume the last curve position pushes spot to the limit. Keeping the bounds
    /// inside the extremes means such a price falls *outside* the position, where the single-sided
    /// formula applies and no division degenerates.
    int24 internal constant FULL_RANGE_TICK_BOUND = 880000;

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
    uint32 internal constant MAX_DEV_BUY_VESTING_SECONDS = 365 days;

    uint64 internal constant MAX_CREATOR_HARVEST_SHARE_WAD = 0.7e18;
    uint64 internal constant MIN_BUYBACK_HARVEST_SHARE_WAD = 0.1e18;
    /// @dev Retained from the pre-rework bounds: the buyback moves the price after every harvest, and
    /// the design's Risks register measures that push against the next band's lower bound at this cap.
    uint64 internal constant MAX_BUYBACK_HARVEST_SHARE_WAD = 0.4e18;
    uint64 internal constant MIN_PROTOCOL_HARVEST_SHARE_WAD = 0.05e18;

    /// @notice Fee routing on collection of quote-denominated fees: 60% LP, 30% creator, 10% protocol.
    uint64 internal constant FEE_LP_SHARE_WAD = 0.6e18;
    uint64 internal constant FEE_CREATOR_SHARE_WAD = 0.3e18;
    uint64 internal constant FEE_PROTOCOL_SHARE_WAD = 0.1e18;

    /// @notice The canonical protocol template (design Decision 16).
    ///
    /// @dev Not consulted by any protocol code path — the hook reads its own constructor-supplied
    /// immutables — but it is the single place the published numbers are written down, so the
    /// deployment script and the test fixtures cannot drift from each other or from the design.
    ///
    /// The ladder's 2235-level spacing is a 1.25x market-cap step and its 447-level walls are a fifth of
    /// that gap, roughly a 4.5% price band. 30 core bands at 1.25x reach about 800x the graduation
    /// valuation; 30 fee-funded extensions continue from there.
    function defaultTemplate() internal pure returns (ProtocolTemplate memory t) {
        t.openingFdvWei = 125 ether;

        t.curvePositions = 32;
        t.curveSpanLevels = LEVELS_PER_DOUBLING;

        t.bandLevelSpacing = BAND_LEVEL_SPACING;
        t.bandWidthLevels = BAND_WIDTH_LEVELS;
        t.coreBandCount = 30;
        t.maxFeeFundedBands = 30;

        t.curveSupplyShareWad = 0.25e18;
        t.ladderSupplyShareWad = 0.65e18;
        t.fullRangeSupplyShareWad = 0.1e18;

        t.lpSeedWad = 0.4e18;
        t.proceedsCreatorWad = 0.55e18;
        t.proceedsProtocolWad = 0.05e18;

        t.baseFeeHundredthsBip = 10_000; // 1%
        t.feeStepOneAtCompletions = 8;
        t.feeStepOneFee = 5_000; // 0.5%
        t.feeStepTwoAtCompletions = 16;
        t.feeStepTwoFee = 2_500; // 0.25%

        t.milestoneFundShareWad = 0.2e18;
        t.bandInventoryCapMultiple = 2;

        t.maxDeploysPerSwap = 8;
        t.maxHarvestsPerSwap = 8;

        t.defaultCreatorWad = 0.6e18;
        t.defaultBuybackWad = 0.2e18;
        t.defaultProtocolWad = 0.1e18;
        t.defaultLpWad = 0.1e18;
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
        config.totalSupply = totalSupply_;
        config.devBuyShareWad = 0;
        config.devBuyVestingSeconds = 0;
        config.harvestSplit = HarvestSplit({creatorWad: 0.6e18, buybackWad: 0.2e18, protocolWad: 0.1e18, lpWad: 0.1e18});
        config.deadline = type(uint256).max;
    }
}
