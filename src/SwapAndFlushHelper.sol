// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPayoutFlusher} from "./interfaces/IPayoutPlugin.sol";

/// @notice Opt-in router that composes one settled swap with the hook's independent cold flush.
/// @dev The immutable hook remains the sole source of payout routing. The helper exposes no destination,
/// take, gas, or plugin parameters and invokes `flush(poolId)` only after PoolManager.unlock has returned.
contract SwapAndFlushHelper is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IPayoutFlusher public immutable hook;

    error InvalidPoolManager();
    error InvalidHook();
    error UnauthorizedUnlock(address caller);
    error InsufficientNativeInput(uint256 required, uint256 available);
    error NativeForwardFailed();

    struct SwapRequest {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    constructor(IPoolManager poolManager_, IPayoutFlusher hook_) {
        if (address(poolManager_) == address(0)) revert InvalidPoolManager();
        if (address(hook_) == address(0) || address(hook_).code.length == 0) revert InvalidHook();
        poolManager = poolManager_;
        hook = hook_;
    }

    /// @notice Settles one swap, flushes its source pool, then returns every resulting asset to the caller.
    /// @dev Exact input and exact output are both supported. For ERC20 input, the helper pulls only the
    /// amount the PoolManager reports as owed. For native input, unused `msg.value` is forwarded with output
    /// and the flush tip. A flush revert is propagated; failure-isolated plugins must return carry as success.
    function swapAndFlush(SwapRequest calldata request) external payable returns (BalanceDelta delta) {
        uint256 nativeBaseline = address(this).balance - msg.value;
        uint256 token0Baseline = _balanceOf(request.key.currency0);
        uint256 token1Baseline = _balanceOf(request.key.currency1);

        bytes memory result = poolManager.unlock(abi.encode(msg.sender, request, msg.value));
        delta = abi.decode(result, (BalanceDelta));

        hook.flush(request.key.toId());
        _forwardBalances(request.key, msg.sender, nativeBaseline, token0Baseline, token1Baseline);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedUnlock(msg.sender);

        (address payer, SwapRequest memory request, uint256 nativeAvailable) =
            abi.decode(data, (address, SwapRequest, uint256));
        BalanceDelta delta = poolManager.swap(
            request.key,
            IPoolManager.SwapParams({
                zeroForOne: request.zeroForOne,
                amountSpecified: request.amountSpecified,
                sqrtPriceLimitX96: request.sqrtPriceLimitX96
            }),
            ""
        );

        _settleOrTake(request.key.currency0, delta.amount0(), payer, nativeAvailable);
        _settleOrTake(request.key.currency1, delta.amount1(), payer, nativeAvailable);
        return abi.encode(delta);
    }

    function _settleOrTake(Currency currency, int128 amount, address payer, uint256 nativeAvailable) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                if (owed > nativeAvailable) revert InsufficientNativeInput(owed, nativeAvailable);
                poolManager.settle{value: owed}();
            } else {
                IERC20 token = IERC20(Currency.unwrap(currency));
                token.safeTransferFrom(payer, address(this), owed);
                poolManager.sync(currency);
                token.safeTransfer(address(poolManager), owed);
                poolManager.settle();
            }
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    function _forwardBalances(
        PoolKey calldata key,
        address recipient,
        uint256 nativeBaseline,
        uint256 token0Baseline,
        uint256 token1Baseline
    ) private {
        _forwardToken(key.currency0, recipient, token0Baseline);
        _forwardToken(key.currency1, recipient, token1Baseline);

        uint256 nativeBalance = address(this).balance;
        if (nativeBalance > nativeBaseline) {
            (bool sent,) = recipient.call{value: nativeBalance - nativeBaseline}("");
            if (!sent) revert NativeForwardFailed();
        }
    }

    function _forwardToken(Currency currency, address recipient, uint256 baseline) private {
        if (currency.isAddressZero()) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 balance = token.balanceOf(address(this));
        if (balance > baseline) token.safeTransfer(recipient, balance - baseline);
    }

    function _balanceOf(Currency currency) private view returns (uint256) {
        if (currency.isAddressZero()) return 0;
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    receive() external payable {}
}
