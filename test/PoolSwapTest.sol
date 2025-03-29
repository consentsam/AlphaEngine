// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {CurrencyLibrary, Currency} from "../lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IPoolManager} from "../lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "../lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "../lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {IUnlockCallback} from "../lib/v4-periphery/lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "../lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract PoolSwapTest is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(
                abi.encode(CallbackData(msg.sender, key, params, hookData))
            ),
            (BalanceDelta)
        );
    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == address(manager), "Not manager");

        CallbackData memory decoded = abi.decode(data, (CallbackData));

        // Execute the swap
        BalanceDelta delta = manager.swap(
            decoded.key,
            decoded.params,
            decoded.hookData
        );

        // Handle the balance changes
        if (decoded.params.zeroForOne) {
            if (delta.amount0() > 0) {
                // Take currency0 from the sender and send to the manager
                IERC20(Currency.unwrap(decoded.key.currency0)).transferFrom(
                    decoded.sender,
                    address(manager),
                    uint256(int256(delta.amount0()))
                );
            }
            if (delta.amount1() < 0) {
                // Take currency1 from the manager and send to the sender
                manager.take(
                    decoded.key.currency1,
                    decoded.sender,
                    uint256(int256(-delta.amount1()))
                );
            }
        } else {
            if (delta.amount1() > 0) {
                // Take currency1 from the sender and send to the manager
                IERC20(Currency.unwrap(decoded.key.currency1)).transferFrom(
                    decoded.sender,
                    address(manager),
                    uint256(int256(delta.amount1()))
                );
            }
            if (delta.amount0() < 0) {
                // Take currency0 from the manager and send to the sender
                manager.take(
                    decoded.key.currency0,
                    decoded.sender,
                    uint256(int256(-delta.amount0()))
                );
            }
        }

        // Return the delta for the calling contract
        return abi.encode(delta);
    }

    receive() external payable {}
}
