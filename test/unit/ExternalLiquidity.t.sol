// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MilestoneBase} from "../../src/MilestoneBase.sol";
import {MilestoneToken} from "../../src/MilestoneToken.sol";
import {LaunchpadTest} from "../Fixtures.sol";
import {Phase, PoolState} from "../../src/types/LaunchTypes.sol";

/// @notice A minimal third-party LP: a real Uniswap v4 integrator that unlocks, modifies its own
/// positions, settles what it owes, and takes what it is owed. Exactly the caller the phase guard
/// decides about.
contract ExternalLP {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;

    struct Op {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function modify(Op calldata op) external returns (BalanceDelta delta) {
        bytes memory result = manager.unlock(abi.encode(op));
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Op memory op = abi.decode(data, (Op));

        (BalanceDelta delta,) = manager.modifyLiquidity(
            op.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: op.tickLower,
                tickUpper: op.tickUpper,
                liquidityDelta: op.liquidityDelta,
                salt: op.salt
            }),
            ""
        );

        if (delta.amount1() < 0) {
            Currency token = op.key.currency1;
            uint256 owed = uint256(uint128(-delta.amount1()));
            manager.sync(token);
            MilestoneToken(Currency.unwrap(token)).transfer(address(manager), owed);
            manager.settle();
        } else if (delta.amount1() > 0) {
            manager.take(op.key.currency1, address(this), uint256(uint128(delta.amount1())));
        }

        if (delta.amount0() < 0) {
            manager.settle{value: uint256(uint128(-delta.amount0()))}();
        } else if (delta.amount0() > 0) {
            manager.take(op.key.currency0, address(this), uint256(uint128(delta.amount0())));
        }

        return abi.encode(delta);
    }

    receive() external payable {}
}

/// @notice External liquidity admission: closed on the curve, open after graduation, with the
/// protocol's own positions unreachable either way.
contract ExternalLiquidityTest is LaunchpadTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    ExternalLP internal lp;
    MilestoneToken internal launchToken;
    IPoolManager internal mgr;
    bytes32 internal constant LP_SALT = bytes32(uint256(1));

    function setUp() public override {
        super.setUp();
        lp = new ExternalLP(IPoolManager(address(manager)));
        launchToken = token;
        mgr = IPoolManager(address(manager));
    }

    // --- Scenario: External liquidity is rejected on the curve ---

    /// @dev The phase guard, not v4 ownership, is what rejects a well-formed third-party position on
    /// the curve. Both directions of a modify are exercised. The hook's `ExternalLiquidityNotAllowed`
    /// reverts inside the manager's hook dispatch, which wraps it (ERC-7751) as
    /// `WrappedError(hook, beforeModify-selector, reason, HookCallFailed)` — so that wrapper, with the
    /// guard's error as the inner reason, is the exact observable outcome on the surface.
    function test_externalLiquidityIsRejectedOnTheCurve() public {
        (int24 lower, int24 upper,,) = _rangeAboveSpot();

        vm.prank(STRANGER);
        vm.expectRevert(_curveGuardWrapped(IHooks.beforeAddLiquidity.selector));
        lp.modify(ExternalLP.Op({key: key, tickLower: lower, tickUpper: upper, liquidityDelta: 1e15, salt: LP_SALT}));

        vm.prank(STRANGER);
        vm.expectRevert(_curveGuardWrapped(IHooks.beforeRemoveLiquidity.selector));
        lp.modify(ExternalLP.Op({key: key, tickLower: lower, tickUpper: upper, liquidityDelta: -1, salt: LP_SALT}));
    }

    // --- Scenario: Graduated pools accept external liquidity ---

    /// @dev A stranger opens a real token-side position above the graduated price, buys through it so
    /// it earns fees, then removes and gets paid like any Uniswap v4 LP. The protocol's own liquidity
    /// is untouched by all of it.
    function test_graduatedPoolsAcceptExternalLiquidity() public {
        _graduatePool();
        _fundLp(2_000 ether);

        (int24 lower, int24 upper, uint160 sqrtLower, uint160 sqrtUpper) = _rangeAboveSpot();
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, 1_000 ether);
        uint128 hookLiquidity = hook.poolState(poolId).fullRangeLiquidity;

        vm.prank(STRANGER);
        BalanceDelta added = lp.modify(
            ExternalLP.Op({
                key: key,
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: LP_SALT
            })
        );
        assertTrue(added.amount1() < 0, "the external position took inventory to open");
        assertGt(
            mgr.getPositionLiquidity(poolId, Position.calculatePositionKey(address(lp), lower, upper, LP_SALT)),
            0,
            "the stranger's position exists"
        );
        assertEq(hook.poolState(poolId).fullRangeLiquidity, hookLiquidity, "the locked position did not move");

        // Trade through the stranger's range so the position earns real fees.
        _buyToLevel(20 ether, _level() + 800);

        vm.prank(STRANGER);
        BalanceDelta removed = lp.modify(
            ExternalLP.Op({
                key: key,
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: LP_SALT
            })
        );

        // Removing credits principal and any accrued fees; at least one side pays the LP.
        assertTrue(removed.amount0() > 0 || removed.amount1() > 0, "the LP was not paid back");
        assertEq(uint8(hook.poolState(poolId).phase), uint8(Phase.GRADUATED), "the pool stayed graduated");
    }

    // --- Scenario: Protocol positions are not externally reachable ---

    /// @dev v4 keys positions to (owner, range, salt). A stranger reusing the hook's full-range bounds
    /// and salt therefore addresses *their own* empty position, not the hook's: their zero-delta
    /// "collection" resolves to that empty position and is turned away by v4's own
    /// `CannotUpdateEmptyPosition` (wrapped, since it reverts inside the manager), while the hook's
    /// position record never moves and the hook's own collection still realizes the accrued fees.
    function test_protocolPositionsAreNotExternallyReachable() public {
        _graduatePool();

        // Accrue real fees to the hook's full-range position.
        _buyToLevel(2 ether, _level() + 500);
        PoolState memory s = hook.poolState(poolId);
        (, uint256 hookGrowthBefore,,) = _fullRangeFeeState();

        // The stranger "collects" the hook's exact range and salt, as a zero-delta modify. The op is
        // built before the expectation is armed: its field reads are staticcalls that would otherwise
        // consume the `vm.expectRevert` slot before the modify ever runs.
        ExternalLP.Op memory op = ExternalLP.Op({
            key: key,
            tickLower: s.fullRangeTickLower,
            tickUpper: s.fullRangeTickUpper,
            liquidityDelta: 0,
            salt: hook.FULL_RANGE_SALT()
        });
        vm.prank(STRANGER);
        vm.expectRevert(Position.CannotUpdateEmptyPosition.selector);
        lp.modify(op);

        (, uint256 hookGrowthAfter,,) = _fullRangeFeeState();
        assertEq(hookGrowthAfter, hookGrowthBefore, "the protocol position's fee record moved for a stranger");

        // The hook's own permissionless collection still realizes what its position earned.
        (uint256 quoteFees,) = hook.collectFees(key);
        assertGt(quoteFees, 0, "the protocol's own collection lost its accrual");
    }

    // --- Only the phase gates: derived, no scenario of its own ---

    function test_zeroDeltaCollectionIsRejectedOnTheCurveToo() public {
        (int24 lower, int24 upper,,) = _rangeAboveSpot();
        vm.prank(STRANGER);
        vm.expectRevert(_curveGuardWrapped(IHooks.beforeRemoveLiquidity.selector));
        lp.modify(ExternalLP.Op({key: key, tickLower: lower, tickUpper: upper, liquidityDelta: 0, salt: LP_SALT}));
    }

    // --- Helpers ---

    /// @dev The exact revert the manager surfaces when the hook's phase guard turns a third-party
    /// modify away: the ERC-7751 wrapper v4's `callHook` places around the guard's own error.
    function _curveGuardWrapped(bytes4 hookCallback) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookCallback,
            abi.encodeWithSelector(MilestoneBase.ExternalLiquidityNotAllowed.selector, address(lp)),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _graduatePool() internal {
        int24 far = hook.poolState(poolId).farLevel;
        router.swapToLimit(key, true, -int256(2_000 ether), _sqrtAtLevel(far));
        router.swap(key, true, -int256(1_000));
        require(hook.poolPhase(poolId) == Phase.GRADUATED, "setup: pool did not graduate");
    }

    /// @dev Moves ladder inventory from hook custody to the external LP, exactly the way any holder
    /// would have obtained tokens.
    function _fundLp(uint256 amount) internal {
        vm.prank(address(hook));
        launchToken.transfer(address(lp), amount);
    }

    /// @dev A narrow range whose prices sit above the current price: in tick space that is *below* the
    /// current tick, because level is -tick. Buys move the price up in level space, down in ticks, and
    /// straight into the range.
    function _rangeAboveSpot()
        internal
        view
        returns (int24 tickLower, int24 tickUpper, uint160 sqrtLower, uint160 sqrtUpper)
    {
        (, int24 tick,,) = mgr.getSlot0(poolId);
        tickUpper = tick - 500;
        tickLower = tickUpper - 500;
        sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
    }

    function _fullRangeFeeState()
        internal
        view
        returns (uint128 liq, uint256 growth0, uint256 growth1, uint256 unused)
    {
        PoolState memory s = hook.poolState(poolId);
        (liq, growth0, growth1) = mgr.getPositionInfo(
            poolId, address(hook), s.fullRangeTickLower, s.fullRangeTickUpper, hook.FULL_RANGE_SALT()
        );
        unused = 0;
    }
}
