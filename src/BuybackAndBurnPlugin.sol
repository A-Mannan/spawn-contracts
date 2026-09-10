// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPayoutPlugin, IPayoutPoolLookup} from "./interfaces/IPayoutPlugin.sol";

interface IBurnableLaunchToken is IERC20 {
    function burn(uint256 amount) external;
}

/// @notice Reference payout destination that atomically buys and burns a source launch token.
/// @dev The plugin owns no routing state beyond immutable protocol dependencies and execution bounds.
/// Every payout opens a fresh PoolManager unlock, settles exactly the native input consumed, takes the
/// token output, and burns it before returning. Any mismatch or failed burn reverts the whole plugin call.
contract BuybackAndBurnPlugin is IPayoutPlugin, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    address public immutable hook;
    uint160 public immutable sqrtPriceLimitX96;

    error InvalidPoolManager();
    error InvalidHook();
    error InvalidPriceLimit();
    error UnauthorizedHook(address caller);
    error UnauthorizedUnlock(address caller);
    error PoolMismatch(PoolId expected, PoolId actual);
    error TokenMismatch(address expected, address actual);
    error InvalidPoolOrientation();
    error InvalidSwapDelta(int128 amount0, int128 amount1);
    error PartialFill(uint256 expected, uint256 actual);
    error BurnIncomplete(uint256 expected, uint256 actual);

    constructor(IPoolManager poolManager_, address hook_, uint160 sqrtPriceLimitX96_) {
        if (address(poolManager_) == address(0)) revert InvalidPoolManager();
        if (hook_ == address(0) || hook_.code.length == 0) revert InvalidHook();
        if (sqrtPriceLimitX96_ <= TickMath.MIN_SQRT_PRICE || sqrtPriceLimitX96_ >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidPriceLimit();
        }

        poolManager = poolManager_;
        hook = hook_;
        sqrtPriceLimitX96 = sqrtPriceLimitX96_;
    }

    function onPayout(PoolId poolId, address token) external payable {
        if (msg.sender != hook) revert UnauthorizedHook(msg.sender);
        if (msg.value == 0) return;

        (PoolKey memory key, address sourceToken) = IPayoutPoolLookup(hook).payoutPool(poolId);
        PoolId actualId = key.toId();
        if (PoolId.unwrap(actualId) != PoolId.unwrap(poolId)) revert PoolMismatch(poolId, actualId);
        if (sourceToken != token) revert TokenMismatch(sourceToken, token);
        if (key.currency0.isAddressZero() == false || Currency.unwrap(key.currency1) != token) {
            revert InvalidPoolOrientation();
        }

        bytes memory result = poolManager.unlock(abi.encode(poolId, key, token, msg.value));
        uint256 tokensBought = abi.decode(result, (uint256));

        uint256 supplyBefore = IBurnableLaunchToken(token).totalSupply();
        IBurnableLaunchToken(token).burn(tokensBought);
        uint256 supplyAfter = IBurnableLaunchToken(token).totalSupply();
        if (supplyBefore < supplyAfter || supplyBefore - supplyAfter != tokensBought) {
            revert BurnIncomplete(tokensBought, supplyBefore < supplyAfter ? 0 : supplyBefore - supplyAfter);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedUnlock(msg.sender);

        (PoolId poolId, PoolKey memory key, address token, uint256 amountIn) =
            abi.decode(data, (PoolId, PoolKey, address, uint256));
        PoolId actualId = key.toId();
        if (PoolId.unwrap(actualId) != PoolId.unwrap(poolId)) revert PoolMismatch(poolId, actualId);
        if (Currency.unwrap(key.currency1) != token || key.currency0.isAddressZero() == false) {
            revert InvalidPoolOrientation();
        }
        if (amountIn > uint256(type(int256).max)) revert PartialFill(amountIn, 0);

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        if (amount0 >= 0 || amount1 <= 0) revert InvalidSwapDelta(amount0, amount1);

        uint256 spent = uint256(uint128(-amount0));
        if (spent != amountIn) revert PartialFill(amountIn, spent);

        uint256 tokensBought = uint256(uint128(amount1));
        poolManager.settle{value: spent}();
        poolManager.take(key.currency1, address(this), tokensBought);
        return abi.encode(tokensBought);
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert UnauthorizedUnlock(msg.sender);
    }
}
