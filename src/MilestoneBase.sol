// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
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
import {TransientLock} from "./libraries/TransientLock.sol";
import {IPayoutPluginRegistry, IProtocolControllerIdentity} from "./interfaces/IPayoutPluginRegistry.sol";
import {Bounds, Phase, PoolState, ProtocolTemplate, WAD} from "./types/LaunchTypes.sol";
import {EconomicConfig} from "./types/PayoutTypes.sol";

/// @title MilestoneBase
/// @notice Storage layout, the protocol template, the event and error surface, and the settlement
/// primitives shared by {MilestoneHook}, {MilestoneColdPaths}, and {MilestonePayoutPaths}.
///
/// @dev Both satellites run by DELEGATECALL from the hook, so they execute against the *hook's* storage.
/// All three contracts therefore have to agree on the layout to the slot. Inheriting the declarations
/// from a single place makes them agree by construction; `make layout-check` rejects mutable state in a
/// derived implementation.
///
/// The {ProtocolTemplate} is unpacked into immutables here rather than held in storage, so reading
/// geometry on the swap path costs nothing. Immutables resolve from the *executing* contract's own
/// bytecode even under delegatecall, so all three implementations must be constructed with matching
/// templates and dependencies; deployment verifies that parity explicitly.
///
/// Also here: the just-in-time bonding curve deployment path, because the hook and lifecycle satellite
/// both need it. The hook runs it from `beforeSwap` for ordinary buys, and the cold path runs it around
/// the genesis dev buy — which is a hook self-swap, and v4 skips both swap callbacks when the hook is the
/// swapper, so the dev buy would otherwise deploy nothing.
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
        COLLECT_FEES,
        REDEEM_PAYOUT_POT,
        REDEEM_PROTOCOL_BACKING
    }

    /// @notice Which mechanism produced an accrual. Emitted for off-chain attribution only; routing
    /// does not branch on it.
    enum AccrualSource {
        CURVE_PROCEEDS,
        SWAP_FEES,
        MILESTONE_HARVEST
    }

    /// @dev Bundles the curve-walk geometry so the deployment frame stays small. "no-via_ir stack limit"
    /// marks shapes that exist only for the fast test profile's no-via_ir build: under the legacy
    /// codegen that profile compiles with, deep frames overflow where via_ir compiles fine. Behavior
    /// is identical either way.
    struct CurveGeometry {
        uint16 positions;
        int24 opening;
        int24 far;
        uint256 curveSupply;
    }

    /// @notice Salt of the single full-range position seeded at graduation.
    /// @dev A hash rather than a small number so it can never collide with a curve position salt, which
    /// is a small index in the low bits.
    bytes32 public constant FULL_RANGE_SALT = keccak256("milestone-launchpad.full-range");

    /// @notice Salt of the wall position seeded at graduation above the full-range position.
    /// @dev Same hash family as {FULL_RANGE_SALT} and disjoint from it, from the curve salts (low bits),
    /// and from the band salts (top bit) by construction.
    bytes32 public constant WALL_SALT = keccak256("milestone-launchpad.wall");

    /// @dev Top bit set, so a band salt can never coincide with a curve salt — whose highest set bit is
    /// below bit 8 for a 32-position template — nor with {FULL_RANGE_SALT}.
    uint256 private constant _BAND_SALT_TAG = 1 << 255;

    /// @notice The shared revenue NFT collection. One token per pool, `tokenId == PoolId`.
    RevenueNFT public immutable revenueNFT;

    /// @notice Stateless helper holding launch-time token deployment and config validation.
    /// @dev Kept external so neither the token's creation bytecode nor the bounds table occupies a
    /// 24 KB budget. It holds no authority; see {LaunchSupport}.
    LaunchSupport public immutable launchSupport;

    /// @notice Exact append-only resolver whose stable indices launch plans bind.
    IPayoutPluginRegistry public immutable payoutPluginRegistry;

    /// @notice Sole authority allowed to replace economics or the protocol recipient.
    address public immutable protocolController;

    // --- The protocol template (design Decision 16), unpacked into immutables ---
    //
    // `internal` rather than `public` deliberately. Twenty-six generated getters is roughly 1.3 KB of
    // pure accessor bytecode, and every byte of it would be duplicated across the three implementations
    // against an EIP-170 limit that design.md names as the leading structural risk. {MilestoneHook.template}
    // returns the whole struct in one call, which is what an integrator wants anyway.

    uint256 internal immutable openingFdvWei;
    uint16 internal immutable curvePositions;
    int24 internal immutable curveSpanLevels;
    int24 internal immutable bandLevelSpacing;
    int24 internal immutable bandFirstStepLevels;
    int24 internal immutable bandStepDecayLevels;
    int24 internal immutable bandWidthLevels;
    uint8 internal immutable coreBandCount;
    uint8 internal immutable maxFeeFundedBands;
    uint64 internal immutable curveSupplyShareWad;
    uint64 internal immutable ladderSupplyShareWad;
    uint64 internal immutable fullRangeSupplyShareWad;
    uint64 internal immutable lpSeedWad;
    uint64 internal immutable proceedsCreatorWad;
    uint64 internal immutable proceedsProtocolWad;
    uint24 internal immutable tradingFeeHundredthsBip;
    uint8 internal immutable bandInventoryCapMultiple;
    uint8 internal immutable maxDeploysPerSwap;
    uint8 internal immutable maxHarvestsPerSwap;

    /// @notice A digest of the whole template, computed once at construction.
    ///
    /// @dev Exposed by {templateHash} on the hook and both satellites. Held as a digest of the constructor
    /// argument rather than reassembled from the immutables on demand: reassembly compiled to about 1.2 KB
    /// in every implementation, while this costs one immutable read at runtime and a single keccak in
    /// initcode.
    bytes32 internal immutable templateDigest;

    // --- Storage. Order is load-bearing: see the contract-level comment. ---

    /// @notice Recipient of the protocol's global revenue ledger.
    /// @dev Mutable only through the typed protocol controller, alongside the versioned economic tuple.
    address public protocolRecipient;

    /// @notice The off-chain launch operator whose EIP-712 signature authorizes relayed launches.
    /// @dev This is the protocol's trust-and-safety key: creators declare themselves in the
    /// configuration and the operator vouches for the launch, which is what lets a first buyer relay
    /// it without the creator ever signing. Zero disables the relayed path entirely (direct creator
    /// launches still work). Mutable only through the typed protocol controller.
    address public trustedOperator;

    /// @notice Per-pool lifecycle state.
    mapping(PoolId poolId => PoolState) internal _pools;

    /// @notice Current complete economic tuple, replaced atomically by the protocol controller.
    EconomicConfig internal _economicConfig;

    mapping(PoolId poolId => uint256 amount) internal _payoutPot;
    mapping(PoolId poolId => mapping(uint8 index => uint256 amount)) internal _pluginCarry;
    mapping(PoolId poolId => uint256 bitmap) internal _carryBitmap;
    mapping(PoolId poolId => uint256 amount) internal _creatorPathClaimable;

    /// @notice Creator's direct claimable ETH balance per pool.
    mapping(PoolId poolId => uint256) internal _creatorClaimable;

    /// @notice Protocol's claimable ETH balance, aggregated globally across every pool.
    uint256 internal _protocolClaimable;

    /// @notice Exact subset of global protocol revenue still held as PoolManager native claims.
    uint256 internal _protocolClaimBacked;

    uint256 internal _totalCreatorLiability;
    uint256 internal _totalPayoutPotLiability;
    uint256 internal _totalPluginCarryLiability;
    uint256 internal _totalCreatorPathLiability;

    /// @notice When each band index was minted, for observability.
    /// @dev With reclaim removed (Decision 22) nothing in the protocol reads this; it exists so an
    /// indexer can age a live band without replaying logs.
    mapping(PoolId poolId => mapping(uint256 index => uint64 deployedAt)) internal _bandDeployedAt;

    event EconomicConfigSet(
        uint64 indexed version,
        uint64 harvestServiceFeeWad,
        uint64 quoteCreatorShareWad,
        uint64 tokenMilestoneFundShareWad
    );
    event ProtocolRecipientSet(address indexed recipient);
    event TrustedOperatorSet(address indexed operator);

    /// @notice Emitted whenever ETH accrues to the creator's claimable balance.
    event CreatorAccrued(PoolId indexed poolId, uint256 amount, AccrualSource source, uint64 economicVersion);

    /// @notice Emitted whenever ETH accrues to the protocol's claimable balance.
    event ProtocolAccrued(PoolId indexed poolId, uint256 amount, AccrualSource source, uint64 economicVersion);

    event CreatorClaimed(PoolId indexed poolId, address indexed holder, uint256 amount);
    event ProtocolClaimed(address indexed recipient, uint256 amount);

    /// @notice Emitted once per launch, carrying the token's metadata and everything needed to
    /// reconstruct the pool's geometry off-chain without reading storage.
    /// @dev Band ticks need only this event's `openingLevel`, {Graduated}'s `graduationLevel`, and the
    /// template — which is immutable and published — so the ladder is recomputable from logs alone.
    /// The metadata triple is what a token page needs before it can render: name, symbol, and the
    /// off-chain URI the token contract stores as {MilestoneToken.tokenURI}.
    event Launched(
        PoolId indexed poolId,
        address indexed creator,
        address indexed token,
        string name,
        string symbol,
        string uri,
        uint256 totalSupply,
        int24 openingLevel,
        int24 farLevel,
        bytes32 configHash
    );

    /// @notice Emitted alongside {Launched} with the launch's exact immutable payout plan.
    event LaunchConfigured(PoolId indexed poolId, uint256 payoutPlan, uint64 devBuyShareWad);

    /// @notice Emitted when a launch includes a dev buy, recording what it cost and delivered.
    event DevBuyExecuted(PoolId indexed poolId, uint256 tokensBought, uint256 ethSpent);

    /// @notice Emitted when a relayed launch's dev buy was skipped because the relayer is not the creator.
    /// @dev The dev-buy share simply remains curve inventory, which is the specified outcome rather than
    /// an error — so it is recorded rather than reverted.
    event DevBuySkipped(PoolId indexed poolId, address indexed relayer, uint256 tokensRequested);

    /// @notice Records the harvest pot funding after the active service fee is deducted.
    event PayoutPotFunded(
        PoolId indexed poolId,
        uint32 indexed milestoneIndex,
        uint256 grossQuote,
        uint256 serviceFee,
        uint256 netQuote,
        uint64 economicVersion
    );

    event PayoutPotRedeemed(PoolId indexed poolId, uint256 amount);

    /// @notice Emitted when a flush pays the 1% tip. The recipient is the immediate caller for
    /// {MilestonePayoutPaths.flush} or the caller-directed recipient for {MilestonePayoutPaths.flushTo}.
    event PayoutTipPaid(PoolId indexed poolId, address indexed recipient, uint256 amount);
    event PluginPayoutDelivered(
        PoolId indexed poolId,
        uint8 indexed pluginIndex,
        address indexed plugin,
        uint256 currentShare,
        uint256 previousCarry,
        uint256 delivered
    );
    event PluginPayoutCarried(
        PoolId indexed poolId,
        uint8 indexed pluginIndex,
        address indexed plugin,
        uint256 currentShare,
        uint256 previousCarry,
        uint256 carried
    );
    event PluginPayoutRedirected(
        PoolId indexed poolId,
        uint8 indexed pluginIndex,
        uint256 currentShare,
        uint256 previousCarry,
        uint256 redirected
    );
    event CreatorPathAccrued(PoolId indexed poolId, uint256 amount);
    event CreatorPathClaimed(PoolId indexed poolId, address indexed holder, uint256 amount);
    event CreatorPathClaimFailed(PoolId indexed poolId, address indexed holder, uint256 amount);

    /// @notice Emitted when a pool graduates, recording the split and the seeded positions.
    /// @dev Both seeded positions' liquidity rides the event so an indexer observes the pool's post-grad
    /// depth without a state read; their bounds are derived constants.
    event Graduated(
        PoolId indexed poolId,
        int24 graduationLevel,
        uint256 quoteProceeds,
        uint256 lpSeedQuote,
        uint256 creatorQuote,
        uint256 protocolQuote,
        uint128 fullRangeLiquidity,
        uint128 wallLiquidity
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
    /// @dev `quoteProceeds` is the burn's full quote credit, principal and accrued band fees together. It
    /// is the gross amount from which {PayoutPotFunded} records the service fee and net pot.
    /// `tokenResidue` is whatever token the position still held, which is rounding dust for a band
    /// completed above its top.
    event MilestoneHarvested(
        PoolId indexed poolId,
        uint32 indexed index,
        uint256 quoteProceeds,
        uint256 tokenResidue,
        uint32 completedMilestones
    );

    /// @notice Emitted when the permissionless path realises the full-range position's accrued swap fees.
    /// @dev The amounts are what the position had accrued, *before* any diversion or routing, so this event
    /// and {FeesRouted} together account for every wei.
    event FeesCollected(PoolId indexed poolId, address indexed caller, uint256 quoteFees, uint256 tokenFees);

    /// @notice Records exactly where one fee collection went.
    ///
    /// @dev `economicVersion` is the tuple the routing actually used, read once before any arithmetic.
    /// Without it an indexer cannot attribute a split: governance replaces economics prospectively and a
    /// collection lands under whichever version was live when its unlock ran, so the same pool can emit
    /// two differently-proportioned routings with nothing on-chain to distinguish them.
    event FeesRouted(
        PoolId indexed poolId,
        uint256 creatorQuote,
        uint256 protocolQuote,
        uint256 divertedToNextBand,
        uint256 tokensBurned,
        uint64 economicVersion
    );

    error NotProtocolController();
    error ControllerRegistryMismatch(address controllerRegistry, address supportRegistry);
    error InvalidEconomicConfig();
    error ZeroAddress();
    error NotAContract(address target);
    error NotRevenueNftHolder(PoolId poolId, address caller);
    error NotProtocolRecipient(address caller);
    error UnauthorizedLaunchSigner(address recovered);
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
    error FarTickOutsideFullRange(int24 farTick, int24 lower, int24 upper);
    error InvalidTemplate();
    error Insolvent(uint256 backing, uint256 liabilities);
    error ClaimBackingInsolvent(uint256 backing, uint256 liabilities);
    error RawEthInsolvent(uint256 backing, uint256 liabilities);
    error InvalidProtocolBacking(uint256 claimBacked, uint256 totalClaimable);
    error InsufficientPayoutGas(uint256 available, uint256 required);
    error RevenueNftOwnerChanged(PoolId poolId, address expected, address actual);

    /// @dev `ImmutableState`'s constructor argument is deliberately *not* supplied here. {MilestoneHook}
    /// gets it from `BaseHook`, which also validates the mined hook address; {MilestoneColdPaths} passes
    /// it directly. Supplying it here would make one of those a duplicate initialisation.
    ///
    /// The template is sanity-checked rather than trusted. It is set once, for the life of the protocol,
    /// and a zero band count or a supply split that does not partition the supply would not fail at
    /// deployment — it would fail at some pool's first harvest. Better here.
    constructor(
        RevenueNFT revenueNft_,
        LaunchSupport launchSupport_,
        ProtocolTemplate memory template_,
        address protocolController_
    ) {
        if (address(revenueNft_) == address(0)) revert ZeroAddress();
        if (address(launchSupport_) == address(0)) revert ZeroAddress();
        if (protocolController_ == address(0)) revert ZeroAddress();
        if (address(revenueNft_).code.length == 0) revert NotAContract(address(revenueNft_));
        if (address(launchSupport_).code.length == 0) revert NotAContract(address(launchSupport_));
        if (protocolController_.code.length == 0) revert NotAContract(protocolController_);

        revenueNFT = revenueNft_;
        launchSupport = launchSupport_;
        payoutPluginRegistry = launchSupport_.payoutPluginRegistry();
        protocolController = protocolController_;

        // The two halves of the payout authority arrive independently — the resolver through launch
        // support, the mutator as a bare address — and no runtime path ever reads one against the other.
        // A mismatched pair would therefore validate launch plans against one registry while governance
        // suspended entries in another, with no revert and no event to show for it. Proving the identity
        // here is what makes the pairing an invariant of the deployment rather than a convention of the
        // script that produced it.
        address controllerRegistry = IProtocolControllerIdentity(protocolController_).registry();
        if (controllerRegistry != address(payoutPluginRegistry)) {
            revert ControllerRegistryMismatch(controllerRegistry, address(payoutPluginRegistry));
        }

        if (
            template_.openingFdvWei == 0 || template_.curvePositions == 0 || template_.curvePositions > 32
                || template_.curveSpanLevels <= 0 || template_.coreBandCount == 0 || template_.bandLevelSpacing <= 0
                || template_.bandFirstStepLevels < template_.bandLevelSpacing || template_.bandStepDecayLevels <= 0
                || template_.bandWidthLevels <= 0 || template_.bandWidthLevels >= template_.bandLevelSpacing
                || template_.bandInventoryCapMultiple == 0 || template_.maxDeploysPerSwap == 0
                || template_.maxHarvestsPerSwap == 0 || template_.tradingFeeHundredthsBip != 10_000
                || uint256(template_.coreBandCount) + template_.maxFeeFundedBands > 256
                || uint256(template_.curveSupplyShareWad) + template_.ladderSupplyShareWad
                    + template_.fullRangeSupplyShareWad != WAD
                || uint256(template_.lpSeedWad) + template_.proceedsCreatorWad + template_.proceedsProtocolWad != WAD
        ) revert InvalidTemplate();

        openingFdvWei = template_.openingFdvWei;
        curvePositions = template_.curvePositions;
        curveSpanLevels = template_.curveSpanLevels;
        bandLevelSpacing = template_.bandLevelSpacing;
        bandFirstStepLevels = template_.bandFirstStepLevels;
        bandStepDecayLevels = template_.bandStepDecayLevels;
        bandWidthLevels = template_.bandWidthLevels;
        coreBandCount = template_.coreBandCount;
        maxFeeFundedBands = template_.maxFeeFundedBands;
        curveSupplyShareWad = template_.curveSupplyShareWad;
        ladderSupplyShareWad = template_.ladderSupplyShareWad;
        fullRangeSupplyShareWad = template_.fullRangeSupplyShareWad;
        lpSeedWad = template_.lpSeedWad;
        proceedsCreatorWad = template_.proceedsCreatorWad;
        proceedsProtocolWad = template_.proceedsProtocolWad;
        tradingFeeHundredthsBip = template_.tradingFeeHundredthsBip;
        bandInventoryCapMultiple = template_.bandInventoryCapMultiple;
        maxDeploysPerSwap = template_.maxDeploysPerSwap;
        maxHarvestsPerSwap = template_.maxHarvestsPerSwap;

        _economicConfig = EconomicConfig({
            harvestServiceFeeWad: Bounds.DEFAULT_HARVEST_SERVICE_FEE_WAD,
            quoteCreatorShareWad: Bounds.DEFAULT_QUOTE_CREATOR_SHARE_WAD,
            tokenMilestoneFundShareWad: Bounds.DEFAULT_TOKEN_MILESTONE_FUND_SHARE_WAD,
            version: 1
        });

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

    // --- Direct revenue ledgers and payout-pot funding ---
    //
    // Graduation and quote-fee routing credit the raw-backed creator or global protocol ledger and return;
    // neither recipient is pushed value during settlement. Harvest quote instead funds the claim-backed
    // protocol subset and source pool's payout pot; asynchronous delivery later records creator-path
    // entitlement and plugin carry as separate raw-backed liabilities.

    /// @notice Credits the direct creator claimable balance for a pool.
    /// @dev Internal-only: there is no external accrual entry point, so no caller can inflate a balance.
    /// Callers are the graduation split and quote-fee routing; payout-plan value uses the separate creator
    /// path ledger.
    function _accrueCreator(PoolId poolId, uint256 amount, AccrualSource source) internal {
        if (amount == 0) return;

        _creatorClaimable[poolId] += amount;
        _totalCreatorLiability += amount;
        emit CreatorAccrued(poolId, amount, source, _economicConfig.version);
    }

    /// @notice Credits the global protocol claimable balance.
    function _accrueProtocol(PoolId poolId, uint256 amount, AccrualSource source) internal {
        if (amount == 0) return;

        _protocolClaimable += amount;
        emit ProtocolAccrued(poolId, amount, source, _economicConfig.version);
    }

    function _fundPayoutPot(PoolId poolId, uint32 index, uint256 grossQuote) internal {
        if (grossQuote == 0) return;

        EconomicConfig memory economics = _economicConfig;
        uint256 serviceFee = FullMath.mulDiv(grossQuote, economics.harvestServiceFeeWad, WAD);
        uint256 netQuote = grossQuote - serviceFee;

        if (serviceFee != 0) {
            _protocolClaimable += serviceFee;
            _protocolClaimBacked += serviceFee;
            emit ProtocolAccrued(poolId, serviceFee, AccrualSource.MILESTONE_HARVEST, economics.version);
        }
        if (netQuote != 0) {
            _payoutPot[poolId] += netQuote;
            _totalPayoutPotLiability += netQuote;
        }

        _assertSolvent();
        emit PayoutPotFunded(poolId, index, grossQuote, serviceFee, netQuote, economics.version);
    }

    function _setEconomicConfig(EconomicConfig calldata config) internal {
        EconomicConfig memory current = _economicConfig;
        if (
            current.version == type(uint64).max || config.version != current.version + 1
                || config.harvestServiceFeeWad > Bounds.MAX_HARVEST_SERVICE_FEE_WAD
                || config.quoteCreatorShareWad > Bounds.MAX_QUOTE_CREATOR_SHARE_WAD
                || config.tokenMilestoneFundShareWad > Bounds.MAX_TOKEN_MILESTONE_FUND_SHARE_WAD
        ) revert InvalidEconomicConfig();

        _economicConfig = config;
        emit EconomicConfigSet(
            config.version, config.harvestServiceFeeWad, config.quoteCreatorShareWad, config.tokenMilestoneFundShareWad
        );
    }

    function _claimBackedLiabilities() internal view returns (uint256) {
        return _totalPayoutPotLiability + _protocolClaimBacked;
    }

    function _rawEthLiabilities() internal view returns (uint256) {
        if (_protocolClaimBacked > _protocolClaimable) {
            revert InvalidProtocolBacking(_protocolClaimBacked, _protocolClaimable);
        }
        return _totalPluginCarryLiability + _totalCreatorPathLiability + _totalCreatorLiability
            + (_protocolClaimable - _protocolClaimBacked);
    }

    function _totalLiabilities() internal view returns (uint256) {
        return _claimBackedLiabilities() + _rawEthLiabilities();
    }

    function _claimBacking() internal view returns (uint256) {
        return IERC6909Claims(address(poolManager)).balanceOf(address(this), 0);
    }

    function _nativeBacking() internal view returns (uint256) {
        return address(this).balance + _claimBacking();
    }

    function _assertSolvent() internal view {
        uint256 claimBacking = _claimBacking();
        uint256 claimLiabilities = _claimBackedLiabilities();
        if (claimBacking < claimLiabilities) revert ClaimBackingInsolvent(claimBacking, claimLiabilities);

        uint256 rawBacking = address(this).balance;
        uint256 rawLiabilities = _rawEthLiabilities();
        if (rawBacking < rawLiabilities) revert RawEthInsolvent(rawBacking, rawLiabilities);

        uint256 backing = rawBacking + claimBacking;
        uint256 liabilities = claimLiabilities + rawLiabilities;
        if (backing < liabilities) revert Insolvent(backing, liabilities);
    }

    /// @dev Native ETH payout. Uses `call` rather than `transfer` so recipients are not bound to the
    /// 2300-gas stipend. Callers remove the source liability before entering this interaction.
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
    // and exact redemption is deferred to a liability-class-specific unlock outside the active swap.

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

    /// @notice Makes a direct creator claim's raw-ETH backing available without consuming another class.
    /// @dev Direct creator revenue is always raw-backed. Ambient claims belong to payout pots or the exact
    /// claim-backed protocol subset and are therefore unavailable to this path.
    function _ensureDirectCreatorEth(uint256 amount) internal view {
        uint256 required = amount + _totalCreatorLiability + _totalPluginCarryLiability + _totalCreatorPathLiability
            + (_protocolClaimable - _protocolClaimBacked);
        uint256 held = address(this).balance;
        if (held < required) revert RawEthInsolvent(held, required);
    }

    /// @notice Whether untrusted plugin delivery currently suppresses protocol work.
    function payoutDeliveryInFlight() external view returns (bool) {
        return TransientLock.payoutDeliveryInFlight();
    }

    // --- Just-in-time bonding curve deployment (design Decisions 15 and 17) ---

    /// @notice Mints every undeployed curve position the incoming buy's simulated path will reach.
    ///
    /// @dev Declared here rather than in {MilestoneHook} because the hook and lifecycle satellite both
    /// call it. The hook runs it from `beforeSwap`; the cold path runs it around the genesis dev buy,
    /// which is a hook self-swap and therefore invisible to the hook's own swap callbacks.
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

        // no-via_ir stack limit: the geometry travels as one memory struct, four locals collapsed into one.
        CurveGeometry memory g = CurveGeometry({
            positions: curvePositions,
            opening: state.openingLevel,
            far: state.farLevel,
            curveSupply: FullMath.mulDiv(state.totalSupply, curveSupplyShareWad, WAD)
        });

        LadderLib.Walk memory walk;
        uint256 index;
        {
            (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
            walk = LadderLib.Walk({
                sqrtPriceX96: sqrtPriceX96,
                amountRemaining: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                feePips: tradingFeeHundredthsBip
            });
            index = CurveLib.firstPositionAbove(g.opening, g.far, g.positions, Orientation.toLevel(tick));
        }
        if (index >= g.positions) return;

        // In-range liquidity: every deployed position whose start sits at or below spot. Positions are
        // nested, so this is a prefix sum rather than a search. Its loop lives in its own frame.
        uint128 liquidity = _deployedCurveLiquidityBelow(state, g, index);

        uint256 minted;
        uint256 owed;

        for (; index < g.positions; index++) {
            int24 start = CurveLib.positionStart(g.opening, g.far, g.positions, index);
            if (start >= g.far) break;
            // The swap's budget or its price limit stops it below this position's start, so nothing at
            // or above it will be touched.
            if (!LadderLib.advance(walk, LadderLib.sqrtPriceAtLevel(start), liquidity)) break;

            uint128 positionLiquidity = CurveLib.positionLiquidity(g.opening, g.far, g.positions, g.curveSupply, index);

            if (state.curveDeployed & (uint32(1) << uint8(index)) == 0 && positionLiquidity != 0) {
                owed += _mintCurvePosition(key, start, g.far, index, positionLiquidity);
                state.curveDeployed |= uint32(1) << uint8(index);
                minted += 1;
            }

            // Crossing the start makes the position active for the rest of the walk, whether it was
            // minted just now or on an earlier swap the price has since fallen back through.
            liquidity += positionLiquidity;
        }

        if (minted == 0) return;

        _settleCurrency(key.currency1, owed);

        emit CurvePositionsDeployed(poolId, minted, state.curveDeployed, owed);
    }

    /// @dev no-via_ir stack limit: the prefix sum of deployed curve liquidity at or below `index`, in its
    /// own frame.
    function _deployedCurveLiquidityBelow(PoolState storage state, CurveGeometry memory g, uint256 index)
        private
        view
        returns (uint128 liquidity)
    {
        for (uint256 i = 0; i < index; i++) {
            if (state.curveDeployed & (uint32(1) << uint8(i)) != 0) {
                liquidity += CurveLib.positionLiquidity(g.opening, g.far, g.positions, g.curveSupply, i);
            }
        }
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
