// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateView} from "v4-periphery/src/lens/StateView.sol";

import {TestRouter} from "../test/Fixtures.sol";
import {MilestoneHook} from "../src/MilestoneHook.sol";
import {MilestoneToken} from "../src/MilestoneToken.sol";
import {Orientation} from "../src/libraries/Orientation.sol";
import {PoolState} from "../src/types/LaunchTypes.sol";

/// @notice Drives a launched pool through the full protocol lifecycle so the
/// substreams data layer observes every event family:
/// buys (curve) -> graduation -> band deployments -> milestone harvests ->
/// payout flush (plugin delivery + burns) -> sells -> fee collection.
contract DriveLifecycle is Script {
    address constant HOOK = 0x7f245BaC7d8fEdb5be065878180cf94193d0BaC0;
    address constant POOL_MANAGER = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    PoolId constant POOL = PoolId.wrap(0xdd760cf0a88061bb963c34fdae2733dfd07d88a930c1034e0af7b0a4b752f5f8);

    function run() external {
        uint256 actorKey = vm.envUint("ACTOR_KEY");
        address actor = vm.addr(actorKey);
        vm.startBroadcast(actorKey);

        MilestoneHook hook = MilestoneHook(payable(HOOK));
        TestRouter router = new TestRouter(IPoolManager(POOL_MANAGER));
        StateView view_ = new StateView(IPoolManager(POOL_MANAGER));
        console2.log("router", address(router));

        (PoolKey memory key, address tokenAddr) = hook.payoutPool(POOL);
        MilestoneToken token = MilestoneToken(tokenAddr);

        PoolState memory state = hook.poolState(POOL);
        console2.log("far level", int256(state.farLevel));

        // ---- 1. buy through the curve to beyond far => auto-graduation ----
        int24 beyond = state.farLevel + 300;
        if (beyond > Orientation.MAX_LEVEL) beyond = Orientation.MAX_LEVEL;
        uint160 limit = TickMath.getSqrtPriceAtTick(Orientation.toTick(beyond));
        router.swapToLimit{value: 70 ether}(key, true, -int256(60 ether), limit);
        console2.log("graduation buy done, phase now", uint256(uint8(hook.poolState(POOL).phase)));

        // ---- 2. ladder buys: cross bands so they deploy & complete ----
        for (uint256 i = 0; i < 4; i++) {
            (, int24 tick,,) = view_.getSlot0(POOL);
            int24 lvl = Orientation.toLevel(tick);
            if (lvl > Orientation.MAX_LEVEL - 2600) break;
            int24 target = lvl + 2500;
            uint160 lim = TickMath.getSqrtPriceAtTick(Orientation.toTick(target));
            router.swapToLimit{value: 90 ether}(key, true, -int256(80 ether), lim);
            (, tick,,) = view_.getSlot0(POOL);
            console2.log("ladder buy done, level now", int256(Orientation.toLevel(tick)));
        }
        console2.log("bands deployed", uint256(hook.poolState(POOL).deployedBands));
        console2.log("bands completed", uint256(hook.poolState(POOL).completedBands));

        // ---- 3. flush: delivers pot to the buyback plugin (which burns tokens) ----
        // The script's own address cannot receive the tip, so it is directed to a dead address.
        hook.flushTo(POOL, address(0xdead));
        console2.log("flushed");

        // ---- 4. sell a quarter of holdings (sell-side volume) ----
        uint256 held = token.balanceOf(actor);
        console2.log("actor tokens", held);
        if (held > 0) {
            token.approve(address(POOL_MANAGER), type(uint256).max);
            uint256 sellAmt = held / 4;
            router.swapToLimit{value: 2 ether}(key, false, -int256(sellAmt), TickMath.MIN_SQRT_PRICE + 1);
            console2.log("sold", sellAmt);
        }

        // ---- 5. collect fees (burn path for token fees) ----
        hook.collectFees(key);
        console2.log("fees collected");

        vm.stopBroadcast();
    }
}
