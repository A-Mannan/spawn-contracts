// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MilestoneHook} from "../../src/MilestoneHook.sol";
import {RevenueNFT} from "../../src/RevenueNFT.sol";
import {LaunchSupport} from "../../src/LaunchSupport.sol";
import {Bounds, PoolState} from "../../src/types/LaunchTypes.sol";

/// @notice Test-only subclass exposing the hook's internal accrual ledger and settlement helpers.
///
/// @dev The production contract has no external accrual entry point on purpose — every credit comes
/// from a settlement path inside the contract, so no caller can inflate a balance. Tests still need
/// to place value in the ledger without running a whole lifecycle, which is what this provides.
/// It adds no capability the production hook has; it only reaches what is already internal.
contract MilestoneHookHarness is MilestoneHook {
    /// @dev Test-only unlock actions. Numbered from 200 so they cannot collide with any production
    /// {UnlockAction}; anything below that range is delegated to the production dispatch.
    uint8 internal constant SETTLE_TAKE_ROUND_TRIP = 200;

    constructor(
        IPoolManager poolManager_,
        RevenueNFT revenueNft_,
        LaunchSupport launchSupport_,
        address coldPaths_,
        address protocolAdmin_,
        address protocolRecipient_
    ) MilestoneHook(poolManager_, revenueNft_, launchSupport_, coldPaths_, protocolAdmin_, protocolRecipient_) {}

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

    /// @notice Places a pool in the state the ladder ends in: every core band retired and the fee-funded
    /// extension cap reached, so no further band can ever be created.
    ///
    /// @dev Manufactured rather than played out, because playing it out is not reachable in a unit test.
    /// Getting there organically needs `bandCount` core bands plus {Bounds.MAX_FEE_FUNDED_BANDS} fee-funded
    /// ones — forty bands at the default config, each a market-cap doubling above the last, so the price
    /// would have to rise by a factor of about `2**40` against a full-range position, and every fee-funded
    /// band would have to be paid for out of swap fees along the way.
    ///
    /// What the manufactured state buys is a test of the *production* diversion path in the only condition
    /// where its ladder-cap guard bites. It writes the two counters that guard reads and nothing else — no
    /// balance, no ledger, no band — so a diversion observed against it is the real code declining for the
    /// real reason. Both counters are ordinarily forward-only, and this only ever moves them forward.
    function forceLadderCappedOut(PoolId poolId) external {
        PoolState storage state = _pools[poolId];
        state.bandCursor = _configs[poolId].bandCount;
        state.feeFundedBandsCreated = Bounds.MAX_FEE_FUNDED_BANDS;
    }

    function _dispatchUnlock(bytes calldata data) internal override returns (bytes memory) {
        // Below the harness range this is a production action (curve minting, and later graduation and
        // harvest), so it must reach the real dispatch rather than being swallowed here.
        if (uint8(uint256(bytes32(data[0:32]))) < 200) return super._dispatchUnlock(data);

        (, Currency currency, uint256 amount, bool skipSettle) = abi.decode(data, (uint8, Currency, uint256, bool));

        _takeCurrency(currency, address(this), amount);
        if (!skipSettle) _settleCurrency(currency, amount);

        return "";
    }
}
