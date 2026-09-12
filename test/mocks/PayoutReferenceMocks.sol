// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPayoutPlugin} from "../../src/interfaces/IPayoutPlugin.sol";
import {IPayoutPoolLookup} from "../../src/interfaces/IPayoutPlugin.sol";

contract MockPayoutHook is IPayoutPoolLookup {
    PoolId internal sourcePoolId;
    PoolKey internal sourceKey;
    address internal sourceToken;

    bool public flushCalled;
    bool public failFlush;
    bool public settlementCompleteAtFlush;
    bool public pluginCallAttempted;
    bool public pluginCallFailed;
    uint256 public tip;
    uint256 public pluginShare;
    uint256 public pluginCarry;
    address public plugin;
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

    function configurePluginFailure(address plugin_, uint256 share_) external {
        plugin = plugin_;
        pluginShare = share_;
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
        if (plugin != address(0)) {
            uint256 attempted = pluginShare + pluginCarry;
            pluginCarry = 0;
            pluginCallAttempted = true;
            (bool success,) = plugin.call{value: attempted}(
                abi.encodeWithSignature("onPayout(bytes32,address)", PoolId.unwrap(poolId), sourceToken)
            );
            if (!success) {
                pluginCallFailed = true;
                pluginCarry = attempted;
            }
        }
        if (tip != 0) {
            (bool sent,) = msg.sender.call{value: tip}("");
            require(sent, "tip failed");
        }
    }

    function payPlugin(address destination, PoolId poolId, address token)
        external
        payable
        returns (bool, bytes memory)
    {
        return destination.call{value: msg.value}(
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

contract RecordingPayoutPlugin is IPayoutPlugin {
    uint256 public calls;
    uint256 public totalReceived;
    uint256 public lastAmount;
    PoolId public lastPoolId;
    address public lastToken;

    function onPayout(PoolId poolId, address token) external payable virtual {
        _record(poolId, token);
    }

    /// @dev The recording body lives here rather than in {onPayout} because Solidity's `super` reaches
    /// only public and internal members: a derived plugin that wants to record *and* do something else
    /// cannot call an external base implementation at all.
    function _record(PoolId poolId, address token) internal {
        calls++;
        totalReceived += msg.value;
        lastAmount = msg.value;
        lastPoolId = poolId;
        lastToken = token;
    }
}

contract OrderedPayoutPlugin is RecordingPayoutPlugin {
    address public immutable recorder;
    uint256 public immutable marker;

    constructor(address recorder_, uint256 marker_) {
        recorder = recorder_;
        marker = marker_;
    }

    function onPayout(PoolId poolId, address token) external payable override {
        _record(poolId, token);
        OrderRecorder(recorder).record(marker);
    }
}

contract OrderRecorder {
    uint256[] public order;

    function record(uint256 marker) external {
        order.push(marker);
    }

    function length() external view returns (uint256) {
        return order.length;
    }
}

contract SwitchablePayoutPlugin is RecordingPayoutPlugin {
    bool public shouldRevert;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function onPayout(PoolId poolId, address token) external payable override {
        if (shouldRevert) revert("delivery rejected");
        _record(poolId, token);
    }
}

contract GasExhaustingPayoutPlugin is IPayoutPlugin {
    function onPayout(PoolId, address) external payable {
        while (true) {}
    }
}

contract ReturndataPayoutPlugin {
    enum Mode {
        EMPTY,
        MALFORMED,
        NON_EMPTY
    }

    Mode public mode;
    uint256 public calls;
    uint256 public totalReceived;

    function setMode(Mode value) external {
        mode = value;
    }

    /// @dev Present only so the payable fallback below is not the contract's sole ETH entry point; the
    /// delivery this mock exists for always arrives with `onPayout` calldata and lands in the fallback.
    receive() external payable {}

    fallback() external payable {
        calls++;
        totalReceived += msg.value;
        Mode current = mode;
        assembly ("memory-safe") {
            switch current
            case 0 { return(0, 0) }
            case 1 {
                mstore(0, 0x01)
                return(31, 1)
            }
            default {
                mstore(0, 0xfeedbeef)
                return(0, 32)
            }
        }
    }
}

interface IPayoutAttackTarget {
    function flushTo(PoolId poolId, address tipTo) external;
    function claimProtocol() external returns (uint256 amount);
    function claimCreator(PoolId poolId) external returns (uint256 amount);
}

contract ReentrantPayoutPlugin is RecordingPayoutPlugin {
    enum Attack {
        NONE,
        FLUSH,
        PROTOCOL_CLAIM,
        CREATOR_CLAIM
    }

    IPayoutAttackTarget public target;
    PoolId public attackPool;
    Attack public attack;
    bool public swallowFailure;
    bool public nestedSucceeded;

    function configure(IPayoutAttackTarget target_, PoolId poolId_, Attack attack_, bool swallowFailure_) external {
        target = target_;
        attackPool = poolId_;
        attack = attack_;
        swallowFailure = swallowFailure_;
        nestedSucceeded = false;
    }

    function onPayout(PoolId poolId, address token) external payable override {
        bytes memory payload;
        if (attack == Attack.FLUSH) payload = abi.encodeCall(IPayoutAttackTarget.flushTo, (attackPool, address(this)));
        if (attack == Attack.PROTOCOL_CLAIM) payload = abi.encodeCall(IPayoutAttackTarget.claimProtocol, ());
        if (attack == Attack.CREATOR_CLAIM) payload = abi.encodeCall(IPayoutAttackTarget.claimCreator, (attackPool));
        if (payload.length != 0) {
            (nestedSucceeded,) = address(target).call(payload);
            if (!nestedSucceeded && !swallowFailure) revert("nested rejected");
        }
        _record(poolId, token);
    }
}

interface ICreatorPathTarget {
    function claimCreatorPath(PoolId poolId) external returns (bool success, uint256 attemptedAmount);
}

interface IRevenueTransfer {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

contract OwnershipChangingPayoutPlugin is RecordingPayoutPlugin {
    IRevenueTransfer public revenueNft;
    uint256 public revenueTokenId;
    address public currentOwner;
    address public nextOwner;
    bool public moved;

    function configureOwnershipChange(IRevenueTransfer nft_, uint256 tokenId_, address nextOwner_) external {
        revenueNft = nft_;
        revenueTokenId = tokenId_;
        currentOwner = address(this);
        nextOwner = nextOwner_;
        moved = false;
    }

    /// @dev Variant for an NFT the plugin does not hold: the configured owner must have approved the
    /// plugin, which is what lets a delivery move the token out from under a creator-path batch.
    function configureOwnershipChangeFrom(IRevenueTransfer nft_, uint256 tokenId_, address from_, address nextOwner_)
        external
    {
        revenueNft = nft_;
        revenueTokenId = tokenId_;
        currentOwner = from_;
        nextOwner = nextOwner_;
        moved = false;
    }

    function claimCreatorPath(ICreatorPathTarget target, PoolId poolId) external returns (bool, uint256) {
        return target.claimCreatorPath(poolId);
    }

    function onPayout(PoolId poolId, address token) external payable override {
        revenueNft.transferFrom(currentOwner, nextOwner, revenueTokenId);
        moved = true;
        _record(poolId, token);
    }
}

interface ICallbackSwapRouter {
    function swapToLimit(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        payable
        returns (BalanceDelta);
}

contract CallbackSwapPayoutPlugin is RecordingPayoutPlugin {
    ICallbackSwapRouter public router;
    PoolKey private _key;
    int256 public amountSpecified;
    uint160 public sqrtPriceLimitX96;
    bool public nestedSucceeded;

    function configureCallbackSwap(ICallbackSwapRouter router_, PoolKey calldata key_, int256 amount_, uint160 limit_)
        external
    {
        router = router_;
        _key = key_;
        amountSpecified = amount_;
        sqrtPriceLimitX96 = limit_;
        nestedSucceeded = false;
    }

    function onPayout(PoolId poolId, address token) external payable override {
        (nestedSucceeded,) = address(router).call(
            abi.encodeCall(ICallbackSwapRouter.swapToLimit, (_key, true, amountSpecified, sqrtPriceLimitX96))
        );
        _record(poolId, token);
    }
}

interface IFlushTarget {
    function flushTo(PoolId poolId, address tipTo) external;
}

contract RejectingPayoutCaller {
    function flushTo(address target, PoolId poolId) external {
        IFlushTarget(target).flushTo(poolId, address(this));
    }

    receive() external payable {
        revert("reject ETH");
    }
}

contract RejectingRevenueHolder {
    function claimCreatorPath(address target, PoolId poolId) external returns (bool, uint256) {
        (bool ok, bytes memory data) =
            target.call(abi.encodeWithSignature("claimCreatorPath(bytes32)", PoolId.unwrap(poolId)));
        require(ok, "claim call reverted");
        return abi.decode(data, (bool, uint256));
    }

    receive() external payable {
        revert("reject ETH");
    }
}
