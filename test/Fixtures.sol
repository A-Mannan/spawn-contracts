// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MilestoneHook} from "../src/MilestoneHook.sol";
import {MilestoneBase} from "../src/MilestoneBase.sol";
import {MilestoneColdPaths} from "../src/MilestoneColdPaths.sol";
import {MilestoneToken} from "../src/MilestoneToken.sol";
import {RevenueNFT} from "../src/RevenueNFT.sol";
import {LaunchSupport} from "../src/LaunchSupport.sol";
import {Orientation} from "../src/libraries/Orientation.sol";
import {LadderLib} from "../src/libraries/LadderLib.sol";
import {Bounds, HarvestSplit, LaunchConfig, PoolState, ProtocolTemplate} from "../src/types/LaunchTypes.sol";

/// @notice Router that performs swaps and liquidity operations through the manager on behalf of tests,
/// standing in for an ordinary third-party integrator.
///
/// @dev Deliberately not built on v4's own test routers: the point is that nothing about this protocol
/// requires a cooperating counterparty, so the tests drive it through the plainest possible
/// `unlock`/`swap`/`settle` sequence an integrator would write.
contract TestRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    enum Op {
        SWAP,
        ADD_LIQUIDITY,
        REMOVE_LIQUIDITY
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        external
        payable
        returns (BalanceDelta)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return _swap(key, zeroForOne, amountSpecified, limit);
    }

    /// @notice Swap with an explicit price limit, so a large buy stops at a chosen price rather than
    /// draining every position and running the price to the extreme.
    ///
    /// @dev This is what you want for any buy large enough to matter. Nothing provides liquidity above
    /// the far level until graduation runs, so an unlimited buy that consumes the whole curve carries
    /// the price to the edge of tick space at zero marginal cost.
    function swapToLimit(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        payable
        returns (BalanceDelta)
    {
        return _swap(key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        private
        returns (BalanceDelta)
    {
        bytes memory result = manager.unlock(abi.encode(Op.SWAP, key, zeroForOne, amountSpecified, limit));
        return abi.decode(result, (BalanceDelta));
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        payable
    {
        manager.unlock(abi.encode(Op.ADD_LIQUIDITY, key, tickLower, tickUpper, liquidityDelta));
    }

    function removeLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) external {
        manager.unlock(abi.encode(Op.REMOVE_LIQUIDITY, key, tickLower, tickUpper, liquidityDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Op op = Op(uint8(uint256(bytes32(data[0:32]))));

        if (op == Op.SWAP) {
            (, PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit) =
                abi.decode(data, (uint8, PoolKey, bool, int256, uint160));

            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: limit
                }),
                ""
            );

            _settleOrTake(key.currency0, delta.amount0());
            _settleOrTake(key.currency1, delta.amount1());
            return abi.encode(delta);
        }

        (, PoolKey memory k, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
            abi.decode(data, (uint8, PoolKey, int24, int24, int256));

        (BalanceDelta d,) = manager.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
        _settleOrTake(k.currency0, d.amount0());
        _settleOrTake(k.currency1, d.amount1());
        return "";
    }

    function _settleOrTake(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                currency.transfer(address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @notice Shared wiring for every unit suite: a local `PoolManager`, the protocol deployed as it is on
/// chain, and the launch helpers the signed-relay model needs.
///
/// @dev The hook must live at an address encoding its permission flags, so it is placed with
/// `deployCodeTo` rather than `new`. {MilestoneColdPaths} is deployed first because the hook's
/// constructor rejects a codeless satellite, and both halves get the *same* {ProtocolTemplate} — a
/// mismatch would make them disagree about their own immutables at runtime, which is exactly what the
/// Migration Plan asserts against.
abstract contract LaunchpadTest is Test {
    using StateLibrary for IPoolManager;

    /// @dev `0xBEEF << 20 | 15040` encodes before/after initialize, before/after swap, and the two
    /// liquidity guards — the flag set {MilestoneHook.getHookPermissions} declares.
    address internal constant HOOK_ADDR = address(uint160((uint160(0xBEEF) << 20) | 15040));

    address internal constant PROTOCOL_ADMIN = address(0xADD1);
    address internal constant PROTOCOL_RECIPIENT = address(0xFEE5);
    address internal constant RELAYER = address(0x2E1A4);
    address internal constant BUYER = address(0xB0B);
    address internal constant STRANGER = address(0x57A);

    /// @dev The creator signs, so it needs a key rather than just an address.
    uint256 internal constant CREATOR_PK = 0xA11CE;
    uint256 internal constant IMPOSTER_PK = 0xBADBEEF;

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    PoolManager internal manager;
    MilestoneHook internal hook;
    MilestoneColdPaths internal coldPaths;
    RevenueNFT internal nft;
    LaunchSupport internal support;
    TestRouter internal router;

    address internal creator;
    address internal imposter;

    ProtocolTemplate internal template;

    PoolId internal poolId;
    PoolKey internal key;
    MilestoneToken internal token;

    /// @dev An absolute base for every warp in a test. `via_ir` common-subexpression-eliminates
    /// `block.timestamp`, so two `vm.warp(block.timestamp + delta)` calls in one function collapse into
    /// a single warp. Computing from a saved base is the only reliable form.
    uint256 internal launchTime;

    function setUp() public virtual {
        creator = vm.addr(CREATOR_PK);
        imposter = vm.addr(IMPOSTER_PK);

        _deployProtocol();

        (poolId, key, token) = _launchDirect(_defaultConfig("Milestone", "MILE"));
        launchTime = block.timestamp;

        vm.deal(BUYER, 100_000 ether);
        vm.deal(RELAYER, 100_000 ether);
        vm.deal(creator, 100_000 ether);
        vm.deal(address(router), 100_000 ether);
    }

    function _deployProtocol() internal {
        manager = new PoolManager(address(this));
        nft = new RevenueNFT();
        support = new LaunchSupport();
        template = Bounds.defaultTemplate();

        coldPaths = new MilestoneColdPaths(IPoolManager(address(manager)), nft, support, template);

        deployCodeTo(
            _hookArtifact(),
            abi.encode(
                IPoolManager(address(manager)),
                nft,
                support,
                template,
                address(coldPaths),
                PROTOCOL_ADMIN,
                PROTOCOL_RECIPIENT
            ),
            HOOK_ADDR
        );
        hook = MilestoneHook(payable(HOOK_ADDR));
        nft.setMinter(HOOK_ADDR);

        router = new TestRouter(IPoolManager(address(manager)));
    }

    /// @notice The artifact placed at {HOOK_ADDR}.
    ///
    /// @dev A seam, not a configuration point: the hook's address encodes its permission flags, so a
    /// suite that needs the harness cannot simply `new` it somewhere else. Overriding this keeps the rest
    /// of the wiring — the satellite, the shared template, the NFT minter — identical to production, which
    /// is the property the Migration Plan asserts against.
    function _hookArtifact() internal view virtual returns (string memory) {
        return "MilestoneHook.sol:MilestoneHook";
    }

    // --- Launch helpers ---

    /// @dev Declares `creator` as the launch creator, which both entry points check the identity against.
    function _defaultConfig(string memory name_, string memory symbol_) internal view returns (LaunchConfig memory) {
        return Bounds.defaultConfig(creator, name_, symbol_, SUPPLY);
    }

    /// @notice The creator's own transaction — no signature, identity is the sender.
    function _launchDirect(LaunchConfig memory config)
        internal
        returns (PoolId id, PoolKey memory k, MilestoneToken t)
    {
        return _launchDirectWithValue(config, 0);
    }

    function _launchDirectWithValue(LaunchConfig memory config, uint256 value)
        internal
        returns (PoolId id, PoolKey memory k, MilestoneToken t)
    {
        vm.deal(creator, creator.balance + value);
        vm.prank(creator);
        (PoolId poolId_, address tokenAddr, PoolKey memory key_) = hook.launch{value: value}(config, "");
        return (poolId_, key_, MilestoneToken(tokenAddr));
    }

    /// @notice A relayed launch: the creator signs off-chain, `relayer` pays the gas.
    function _launchRelayed(LaunchConfig memory config, address relayer)
        internal
        returns (PoolId id, PoolKey memory k, MilestoneToken t)
    {
        return _launchRelayedSignedBy(config, relayer, CREATOR_PK);
    }

    /// @notice A relayed launch signed by an arbitrary key, for the tests that care *who* signed.
    function _launchRelayedSignedBy(LaunchConfig memory config, address relayer, uint256 privateKey)
        internal
        returns (PoolId id, PoolKey memory k, MilestoneToken t)
    {
        bytes memory signature = _sign(config, privateKey);
        vm.prank(relayer);
        (PoolId poolId_, address tokenAddr, PoolKey memory key_) = hook.launch(config, signature);
        return (poolId_, key_, MilestoneToken(tokenAddr));
    }

    function _sign(LaunchConfig memory config, uint256 privateKey) internal view returns (bytes memory) {
        bytes32 digest = support.launchDigest(config, HOOK_ADDR);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // --- Price and level helpers ---

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    function _level() internal view returns (int24) {
        (, int24 tick) = _slot0();
        return Orientation.toLevel(tick);
    }

    function _levelOf(PoolId id) internal view returns (int24) {
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(id);
        return Orientation.toLevel(tick);
    }

    /// @dev `using StateLibrary for IPoolManager` is file-scoped and does not reach inheriting suites, so
    /// pool reads are exposed as helpers here rather than repeated as directives in every file.
    function _sqrtPriceOf(PoolId id) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(id);
    }

    function _baseFeeOf(PoolId id) internal view returns (uint24 lpFee) {
        (,,, lpFee) = IPoolManager(address(manager)).getSlot0(id);
    }

    /// @notice The pool's liquidity in range at spot — what a marginal trade actually meets.
    function _poolLiquidity(PoolId id) internal view returns (uint128) {
        return IPoolManager(address(manager)).getLiquidity(id);
    }

    function _sqrtAtLevel(int24 level) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(Orientation.toTick(level));
    }

    /// @notice Buys with `ethIn`, stopping at `targetLevel` rather than running the price to the extreme.
    function _buyToLevel(uint256 ethIn, int24 targetLevel) internal returns (BalanceDelta) {
        return router.swapToLimit(key, true, -int256(ethIn), _sqrtAtLevel(targetLevel));
    }

    function _buy(uint256 ethIn) internal returns (BalanceDelta) {
        return router.swap(key, true, -int256(ethIn));
    }

    function _sell(uint256 tokensIn) internal returns (BalanceDelta) {
        return router.swap(key, false, -int256(tokensIn));
    }

    /// @notice Sells down to `targetLevel`, stopping there rather than running the price to the floor.
    ///
    /// @dev The mirror of {_buyToLevel}. A sell is `!zeroForOne`, so it moves *up* in tick space and
    /// therefore *down* in level space, and v4 wants a limit above the current sqrt price.
    function _sellToLevel(uint256 tokensIn, int24 targetLevel) internal returns (BalanceDelta) {
        return router.swapToLimit(key, false, -int256(tokensIn), _sqrtAtLevel(targetLevel));
    }

    /// @notice Sells everything the router is holding, down to `targetLevel`.
    /// @dev The router is the only party that has bought, so its balance is the whole tradeable float.
    function _sellAllToLevel(int24 targetLevel) internal returns (BalanceDelta) {
        return _sellToLevel(token.balanceOf(address(router)), targetLevel);
    }

    /// @notice Drives the pool to graduation and completes the transition.
    ///
    /// @dev Two steps by design (Decision 18): the crossing swap cannot graduate in its own `afterSwap`,
    /// so a second, trivial swap triggers the auto-graduation in `beforeSwap`. The crossing buy stops one
    /// level *above* the far level rather than at the extreme, so the graduation price is a real one.
    function _graduate() internal {
        int24 far = hook.poolState(poolId).farLevel;
        _buyToLevel(2_000 ether, far);
        // A dust buy whose only job is to arrive after the crossing. It cannot reuse the far level as
        // its own limit: the crossing swap ended exactly there, and v4 rejects a limit at or beyond the
        // current price.
        _buy(1_000);
    }

    // --- Position helpers ---

    function _positionLiquidity(int24 levelLower, int24 levelUpper, bytes32 salt) internal view returns (uint128) {
        (int24 tickLower, int24 tickUpper) = Orientation.levelRangeToTicks(levelLower, levelUpper);
        return IPoolManager(address(manager)).getPositionLiquidity(
            poolId, Position.calculatePositionKey(HOOK_ADDR, tickLower, tickUpper, salt)
        );
    }

    function _bandLiquidity(uint256 index) internal view returns (uint128) {
        (int24 lower, int24 upper, bool exists) = hook.bandLevels(poolId, index);
        if (!exists) return 0;
        return _positionLiquidity(lower, upper, hook.bandSalt(index));
    }

    /// @notice Band `index`'s lower level bound, read from the hook rather than re-derived.
    /// @dev Tests size their buys against band boundaries constantly. Reading them from the contract keeps
    /// a template change from turning a geometry drift into a mystifying mis-sized swap.
    function _bandLower(uint256 index) internal view returns (int24 lower) {
        (lower,,) = hook.bandLevels(poolId, index);
    }

    /// @notice Band `index`'s upper level bound — the level a swap must reach to complete it.
    function _bandUpper(uint256 index) internal view returns (int24 upper) {
        (, upper,) = hook.bandLevels(poolId, index);
    }

    function _curveLiquidity(uint256 index) internal view returns (uint128) {
        PoolState memory state = hook.poolState(poolId);
        return _positionLiquidity(hook.curvePositionStart(poolId, index), state.farLevel, hook.curvePositionSalt(index));
    }

    function _fullRangeLiquidity() internal view returns (uint128) {
        return IPoolManager(address(manager)).getPositionLiquidity(
            poolId,
            Position.calculatePositionKey(
                HOOK_ADDR, -Bounds.FULL_RANGE_TICK_BOUND, Bounds.FULL_RANGE_TICK_BOUND, hook.FULL_RANGE_SALT()
            )
        );
    }

    function _deployedBandCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < uint256(template.coreBandCount) + template.maxFeeFundedBands; i++) {
            if (hook.bandDeployed(poolId, i)) count += 1;
        }
    }

    function _deployedCurveCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < template.curvePositions; i++) {
            if (hook.curvePositionDeployed(poolId, i)) count += 1;
        }
    }

    function _completedBandCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < uint256(template.coreBandCount) + template.maxFeeFundedBands; i++) {
            if (hook.bandCompleted(poolId, i)) count += 1;
        }
    }

    /// @notice The token inventory one core band is entitled to, straight from the template.
    function _perBand() internal view returns (uint256) {
        return LadderLib.perBandInventory(SUPPLY, template.ladderSupplyShareWad, template.coreBandCount);
    }

    /// @notice Everything the ladder still holds in hook custody: undrawn share, carry, accrued fund.
    ///
    /// @dev The three fields move between each other constantly — a skip shifts share into carry, a
    /// deployment drains carry and zeroes the fund — so no single one of them is a conservation quantity.
    /// Their sum is.
    function _undeployedInventory() internal view returns (uint256) {
        PoolState memory s = hook.poolState(poolId);
        return s.ladderInventoryRemaining + s.carriedInventory + s.milestoneFundAccrued;
    }

    // --- Log helpers ---
    //
    // Several ladder requirements are about *ordering* and *multiplicity* inside one transaction —
    // "deploys each before filling it", "in ascending order", "every band it completes within the cap".
    // Post-transaction state cannot express any of those, so the assertions run against the recorded log.

    function _countLogs(Vm.Log[] memory logs, bytes32 selector) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == selector) n += 1;
        }
    }

    /// @notice The band indices carried by every `selector` log, in emission order.
    /// @dev Every ladder event indexes the band in `topics[2]`, so one extractor serves deploys, skips,
    /// harvests, and routings alike.
    function _bandIndices(Vm.Log[] memory logs, bytes32 selector) internal pure returns (uint32[] memory out) {
        out = new uint32[](_countLogs(logs, selector));
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != selector) continue;
            out[n] = uint32(uint256(logs[i].topics[2]));
            n += 1;
        }
    }

    /// @notice Position in `logs` of the first `selector` entry, or `type(uint256).max` if absent.
    function _firstLogAt(Vm.Log[] memory logs, bytes32 selector) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == selector) return i;
        }
        return type(uint256).max;
    }

    /// @notice Position in `logs` of the last `selector` entry, or `type(uint256).max` if absent.
    function _lastLogAt(Vm.Log[] memory logs, bytes32 selector) internal pure returns (uint256 at) {
        at = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == selector) at = i;
        }
    }

    /// @notice Token inventory summed across every {MilestoneBase.BandDeployed} in the window.
    function _tokenDeployed(Vm.Log[] memory logs) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.BandDeployed.selector) continue;
            (,,, uint256 tokenInventory) = abi.decode(logs[i].data, (int24, int24, uint128, uint256));
            total += tokenInventory;
        }
    }

    /// @notice Token residue summed across every {MilestoneBase.MilestoneHarvested} in the window.
    function _tokenReturned(Vm.Log[] memory logs) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.MilestoneHarvested.selector) continue;
            (, uint256 tokenResidue,) = abi.decode(logs[i].data, (uint256, uint256, uint32));
            total += tokenResidue;
        }
    }

    /// @notice The `tokenInventory` field of the {MilestoneBase.BandDeployed} log for `index`.
    function _deployedInventoryOf(Vm.Log[] memory logs, uint32 index) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != MilestoneBase.BandDeployed.selector) continue;
            if (uint32(uint256(logs[i].topics[2])) != index) continue;
            (,,, uint256 tokenInventory) = abi.decode(logs[i].data, (int24, int24, uint128, uint256));
            return tokenInventory;
        }
        revert("no BandDeployed for index");
    }

    /// @notice A harvest split with the given creator share, the rest arranged to satisfy every bound.
    function _split(uint64 creatorWad, uint64 buybackWad, uint64 protocolWad)
        internal
        pure
        returns (HarvestSplit memory)
    {
        return HarvestSplit({
            creatorWad: creatorWad,
            buybackWad: buybackWad,
            protocolWad: protocolWad,
            lpWad: uint64(1e18) - creatorWad - buybackWad - protocolWad
        });
    }

    receive() external payable {}
}
