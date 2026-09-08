// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPayoutFlusher, IPayoutPoolLookup} from "../../src/interfaces/IPayoutPlugin.sol";

contract MockPayoutHook is IPayoutPoolLookup, IPayoutFlusher {
    PoolId internal sourcePoolId;
    PoolKey internal sourceKey;
    address internal sourceToken;

    bool public flushCalled;
    bool public failFlush;
    bool public settlementCompleteAtFlush;
    uint256 public tip;
    MockPoolManager internal manager;

    function setSource(PoolId poolId, PoolKey memory key, address token) external {
        sourcePoolId = poolId;
        sourceKey = key;
        sourceToken = token;
    }

    function setManager(MockPoolManager manager_) external {
        manager = manager_;
    }

    function configureFlush(uint256 tip_, bool failFlush_) external {
        tip = tip_;
        failFlush = failFlush_;
    }

    function payoutPool(PoolId poolId) external view returns (PoolKey memory key, address token) {
        require(PoolId.unwrap(poolId) == PoolId.unwrap(sourcePoolId), "unknown pool");
        return (sourceKey, sourceToken);
    }

    function flush(PoolId poolId) external {
        require(PoolId.unwrap(poolId) == PoolId.unwrap(sourcePoolId), "wrong pool");
        flushCalled = true;
        if (address(manager) != address(0)) {
            settlementCompleteAtFlush = manager.unlockComplete() && manager.settleCount() != 0;
        }
        if (failFlush) revert("flush failed");
        if (tip != 0) {
            (bool sent,) = msg.sender.call{value: tip}("");
            require(sent, "tip failed");
        }
    }

    function payPlugin(address plugin, PoolId poolId, address token) external payable returns (bool, bytes memory) {
        return plugin.call{value: msg.value}(
            abi.encodeWithSignature("onPayout(bytes32,address)", PoolId.unwrap(poolId), token)
        );
    }

    receive() external payable {}
}

contract MockPoolManager {
    IUnlockCallback internal activeCallback;
    bool public unlockComplete;
    uint256 public unlockCount;
    uint256 public settleCount;
    uint256 public swapCount;
    uint256 public configuredSpend;
    uint256 public configuredOutput;
    Currency public configuredOutputCurrency;

    function configureSwap(uint256 spend, uint256 output, Currency outputCurrency) external {
        configuredSpend = spend;
        configuredOutput = output;
        configuredOutputCurrency = outputCurrency;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        unlockComplete = false;
        unlockCount++;
        activeCallback = IUnlockCallback(msg.sender);
        bytes memory result = activeCallback.unlockCallback(data);
        activeCallback = IUnlockCallback(address(0));
        unlockComplete = true;
        return result;
    }

    function swap(PoolKey memory, IPoolManager.SwapParams memory, bytes calldata) external returns (BalanceDelta) {
        require(msg.sender == address(activeCallback), "not callback");
        swapCount++;
        return toBalanceDelta(-int128(uint128(configuredSpend)), int128(uint128(configuredOutput)));
    }

    function settle() external payable returns (uint256 paid) {
        settleCount++;
        return msg.value;
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(currency == configuredOutputCurrency, "wrong output currency");
        if (currency.isAddressZero()) {
            (bool sent,) = to.call{value: amount}("");
            require(sent, "native take failed");
        } else {
            (bool ok, bytes memory result) =
                Currency.unwrap(currency).call(abi.encodeCall(IERC20Like.transfer, (to, amount)));
            require(ok && (result.length == 0 || abi.decode(result, (bool))), "token take failed");
        }
    }

    function sync(Currency) external {}

    receive() external payable {}
}

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
}
