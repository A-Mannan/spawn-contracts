// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @title SpawnSwapRouter
/// @notice Minimal exact-input swap router for Spawn pools (ETH <-> token).
/// @dev Local-dev settlement router on the TestRouter pattern: the pool is
/// unlocked, the swap runs, debts are settled (native from msg.value, ERC-20
/// pulled from the caller via allowance) and the output is taken straight to
/// the recipient with a slippage guard. Production use wants an audit.
contract SpawnSwapRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;

    error NotManager();
    error TooLittleReceived(uint256 minOut, uint256 received);
    error BadAmount();
    error EthRefundFailed();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    /// @param key Pool key (currency0 = ETH, currency1 = token for Spawn pools).
    /// @param zeroForOne True to buy (ETH in), false to sell (token in).
    /// @param amountIn Exact input (ETH wei on buys, token units on sells).
    /// @param amountOutMinimum Slippage guard on the output leg.
    /// @param recipient Receives the output (and any leftover ETH).
    function swapExactIn(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        address recipient
    ) external payable {
        if (amountIn == 0 || recipient == address(0)) revert BadAmount();
        bytes memory result = manager.unlock(
            abi.encode(key, zeroForOne, amountIn, amountOutMinimum, msg.sender, recipient)
        );
        uint256 out = abi.decode(result, (uint256));
        if (out < amountOutMinimum) revert TooLittleReceived(amountOutMinimum, out);
        // Safety net: anything left here (e.g. over-sent ETH) goes back.
        uint256 dust = address(this).balance;
        if (dust > 0) {
            (bool ok,) = recipient.call{value: dust}("");
            if (!ok) revert EthRefundFailed();
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (
            PoolKey memory key,
            bool zeroForOne,
            uint128 amountIn,
            uint128 amountOutMinimum,
            address payer,
            address recipient
        ) = abi.decode(data, (PoolKey, bool, uint128, uint128, address, address));

        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(amountIn)),
                sqrtPriceLimitX96: limit
            }),
            ""
        );

        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        int128 debt = zeroForOne ? delta.amount0() : delta.amount1();
        int128 credit = zeroForOne ? delta.amount1() : delta.amount0();

        // debt is negative by PoolManager convention; settle it in full.
        uint256 owed = uint256(uint128(-debt));
        if (input.isAddressZero()) {
            manager.settle{value: owed}();
        } else {
            manager.sync(input);
            bool ok = IERC20Minimal(Currency.unwrap(input)).transferFrom(
                payer, address(manager), owed
            );
            if (!ok) revert BadAmount();
            manager.settle();
        }

        uint256 got = uint256(uint128(credit));
        if (got < amountOutMinimum) revert TooLittleReceived(amountOutMinimum, got);
        manager.take(output, recipient, got);
        return abi.encode(got);
    }
}
