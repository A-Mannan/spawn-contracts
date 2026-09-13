// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateView} from "v4-periphery/src/lens/StateView.sol";

import {MilestoneHook} from "../src/MilestoneHook.sol";
import {MilestoneToken} from "../src/MilestoneToken.sol";
import {LaunchConfig} from "../src/types/LaunchTypes.sol";

contract LaunchAndSwap is Script {
    address constant HOOK = 0x7f245BaC7d8fEdb5be065878180cf94193d0BaC0;
    address constant POOL_MANAGER = 0x5FbDB2315678afecb367f032d93F642f64180aa3;

    function run() external {
        address creator = vm.envAddress("CREATOR");
        uint256 creatorKey = vm.envUint("CREATOR_KEY");
        uint256 ethForDevBuy = 10 ether;

        vm.startBroadcast(creatorKey);

        MilestoneHook hook = MilestoneHook(payable(HOOK));
        LaunchConfig memory config = LaunchConfig({
            creator: creator,
            name: "Second Token",
            symbol: "SCND",
            uri: "",
            totalSupply: 1_000_000_000 ether,
            devBuyShareWad: 0.05e18,
            payoutPlan: 0, // empty plan
            deadline: 0 // creator-direct launch: deadline-independent
        });

        (PoolId poolId, address token, PoolKey memory key) = hook.launch{value: ethForDevBuy}(config, bytes(""));
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("token", token);
        console2.log("curve0", Currency.unwrap(key.currency0));
        console2.log("currency1", Currency.unwrap(key.currency1));

        MilestoneToken tkn = MilestoneToken(token);
        console2.log("name", tkn.name());
        console2.log("supply", tkn.totalSupply());

        vm.stopBroadcast();
    }
}
