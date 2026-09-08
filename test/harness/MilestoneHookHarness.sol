// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {PoolState, ProtocolTemplate} from "../../src/types/LaunchTypes.sol";

/// @notice Test-only subclass that records the ladder's *mid-transaction* state, which no external call
/// can otherwise observe, and reaches the internal accrual and settlement primitives directly.
///
/// @dev Two distinct jobs, both of which need a subclass rather than a helper contract. The recording half
/// overrides `_afterSwap`; the reaching half exposes internals the production surface deliberately has no
/// entry point for — every accrual in production comes from a settlement path inside the contract, so no
/// caller can inflate a balance, but tests still need to place value in the ledger without playing out a
/// whole lifecycle. Neither half adds a capability the production hook lacks.
///
/// Several `milestone-ladder` requirements are about state that exists only while a swap is in
/// flight. "Multiple bands may be live simultaneously" is the clearest case: band `i+1` sits above band
/// `i`'s top, so reaching it means crossing band `i`'s top, which harvests band `i`. Live bands therefore
/// pile up only between `beforeSwap`'s deployments and `afterSwap`'s harvests — by the time the
/// transaction ends the harvest cap has drained all but the leftover. Asserting on post-transaction state
/// alone would silently weaken the requirement into something the single-band case already satisfies.
///
/// The override snapshots and then delegates. It changes no behaviour, reads no private state, and adds
/// no capability: everything it records is derived from `poolState`, just at a moment an external caller
/// cannot reach.
///
/// Storage here is appended *after* every slot {MilestoneBase} declares, so it cannot collide with the
/// layout {MilestoneColdPaths} shares by DELEGATECALL — the cold paths write base slots only and never
/// see these. `make layout-check` compares the two production halves by name and does not look at test
/// contracts, so this file is outside its scope by construction rather than by omission.
contract MilestoneHookHarness is MilestoneHook {
    using PoolIdLibrary for PoolKey;

    /// @dev Test-only unlock actions. Numbered from 200 so they cannot collide with any production
    /// {UnlockAction}; anything below that range is delegated to the production dispatch.
    uint8 internal constant SETTLE_TAKE_ROUND_TRIP = 200;

    /// @notice `deployedBands & ~completedBands` sampled at the top of every `afterSwap`, in call order.
    uint256[] public liveBandsOnAfterSwap;

    /// @notice The level `afterSwap` decided completion against, sampled alongside the bitmap above.
    int24[] public levelOnAfterSwap;

    constructor(
        IPoolManager poolManager_,
        RevenueNFT revenueNft_,
        LaunchSupport launchSupport_,
        ProtocolTemplate memory template_,
        address coldPaths_,
        address protocolAdmin_,
        address protocolRecipient_
    )
        MilestoneHook(poolManager_, revenueNft_, launchSupport_, template_, coldPaths_, protocolAdmin_, protocolRecipient_)
    {}

    /// @notice Snapshots the live-band set before the harvest loop drains it, then runs the real path.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        liveBandsOnAfterSwap.push(_pools[poolId].deployedBands & ~_pools[poolId].completedBands);
        levelOnAfterSwap.push(_currentLevel(poolId));

        return super._afterSwap(sender, key, params, delta, hookData);
    }

    /// @notice How many `afterSwap` snapshots have been taken.
    function snapshotCount() external view returns (uint256) {
        return liveBandsOnAfterSwap.length;
    }

    /// @notice The number of bands live at the top of snapshot `i`'s `afterSwap`.
    function liveBandCountAt(uint256 i) external view returns (uint256 count) {
        uint256 bits = liveBandsOnAfterSwap[i];
        while (bits != 0) {
            bits &= bits - 1;
            count += 1;
        }
    }

    /// @notice Whether band `index` was live at the top of snapshot `i`'s `afterSwap`.
    ///
    /// @dev Per-index rather than a count, because the requirement is that "each live band's deployed
    /// state is tracked independently by its index" — a count alone would pass on a bitmap that had the
    /// right population and the wrong bits.
    function bandLiveAt(uint256 i, uint256 index) external view returns (bool) {
        return liveBandsOnAfterSwap[i] & (uint256(1) << index) != 0;
    }

    /// @notice Clears the snapshot log, so a test can measure one swap without the setup's swaps in view.
    function resetSnapshots() external {
        delete liveBandsOnAfterSwap;
        delete levelOnAfterSwap;
    }

    // --- Accrual ledger (tasks 6.x, 11.x) ---

    function accrueCreator(PoolId poolId, uint256 amount) external {
        _accrueCreator(poolId, amount, AccrualSource.MILESTONE_HARVEST);
    }

    function accrueProtocol(PoolId poolId, uint256 amount) external {
        _accrueProtocol(poolId, amount, AccrualSource.MILESTONE_HARVEST);
    }

    function accrueCreatorFrom(PoolId poolId, uint256 amount, AccrualSource source) external {
        _accrueCreator(poolId, amount, source);
    }

    function accrueProtocolFrom(PoolId poolId, uint256 amount, AccrualSource source) external {
        _accrueProtocol(poolId, amount, source);
    }

    /// @notice Mints a pool's revenue NFT, standing in for the launch path.
    function mintRevenueNft(PoolId poolId, address to) external returns (uint256) {
        return revenueNFT.mint(poolId, to);
    }

    // --- Settlement helper exercise (task 3.7) ---

    /// @notice Takes `amount` of `currency` out of the manager and immediately settles it back,
    /// leaving a net-zero delta.
    /// @dev v4 permits taking without prior credit — core documents it as a free flash loan — which
    /// makes take-then-settle a self-contained round trip over both helpers. If either helper were
    /// wrong, the manager's `CurrencyNotSettled` check would revert the unlock.
    function settleTakeRoundTrip(Currency currency, uint256 amount) external {
        poolManager.unlock(abi.encode(SETTLE_TAKE_ROUND_TRIP, currency, amount, false));
    }

    /// @notice Takes without settling, to prove the manager rejects an unsettled delta.
    function takeWithoutSettling(Currency currency, uint256 amount) external {
        poolManager.unlock(abi.encode(SETTLE_TAKE_ROUND_TRIP, currency, amount, true));
    }

    // --- Terminal ladder state (task 10.3) ---

    /// @notice Places a pool in the state the ladder ends in: every core band consumed and the fee-funded
    /// extension cap reached, so no further band can ever be created.
    ///
    /// @dev Manufactured rather than played out, because playing it out is not reachable in a unit test.
    /// Getting there organically needs `coreBandCount` core bands plus `maxFeeFundedBands` fee-funded ones —
    /// sixty bands at the default template, each a 1.25x market-cap step above the last, so the price would
    /// have to rise by a factor of about `1.25**60` against a full-range position, and every fee-funded band
    /// would have to be paid for out of swap fees along the way.
    ///
    /// What the manufactured state buys is a test of the *production* diversion path in the only condition
    /// where its ladder-cap guard bites. It writes the two counters that guard reads and nothing else — no
    /// balance, no ledger, no band — so a diversion observed against it is the real code declining for the
    /// real reason. Both counters are ordinarily forward-only, and this only ever moves them forward.
    function forceLadderCappedOut(PoolId poolId) external {
        PoolState storage state = _pools[poolId];
        state.nextBandIndex = coreBandCount;
        state.feeFundedBandsCreated = maxFeeFundedBands;
    }

    /// @notice Places a pool at the boundary the fee-funded extension begins at: the core ladder spent,
    /// the cursor on the first extension index, and no inventory carried.
    ///
    /// @dev Sibling of {forceLadderCappedOut}, and manufactured for a narrower version of the same reason.
    /// The core ladder *can* be walked in a unit test, but not into the state the extension scenarios need.
    /// Every band has to *complete* rather than skip, because a skipped band moves a whole per-band share
    /// into `carriedInventory` — and thirty bands of carry would fund the first extension band on their own,
    /// which is precisely what "extension requires accrued inventory" must be able to rule out. Completing
    /// all thirty means thirty harvests, each routing a buyback that pushes price further up, so bands ahead
    /// of the cursor keep falling behind spot and skipping instead. Left to run, the walk converges on a
    /// large carry, which is the one state these tests cannot use.
    ///
    /// So the three fields the funding decision reads are set directly, and nothing else is: no band is
    /// marked deployed or completed, no balance moves, no ledger is touched, and `milestoneFundAccrued` is
    /// left exactly as the test found it. `feeFundedBandsCreated` stays zero, so the extension cap is fully
    /// open. What a test then observes — whether a band appears, what funds it, whether it counts against
    /// the cap — is the production path deciding for production reasons.
    function forceCoreLadderExhausted(PoolId poolId) external {
        PoolState storage state = _pools[poolId];
        state.nextBandIndex = coreBandCount;
        state.ladderInventoryRemaining = 0;
        state.carriedInventory = 0;
    }

    function _dispatchUnlock(bytes calldata data) internal override returns (bytes memory) {
        // Below the harness range this is a production action, so it must reach the real dispatch rather
        // than being swallowed here.
        if (uint8(uint256(bytes32(data[0:32]))) < 200) return super._dispatchUnlock(data);

        (, Currency currency, uint256 amount, bool skipSettle) = abi.decode(data, (uint8, Currency, uint256, bool));

        _takeCurrency(currency, address(this), amount);
        if (!skipSettle) _settleCurrency(currency, amount);

        return "";
    }
}
