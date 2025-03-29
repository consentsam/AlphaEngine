// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ITellerWithMultiAssetSupport} from "../src/interfaces/ITellerWithMultiAssetSupport.sol";
import {IERC20} from "../lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockTeller
 * @dev A mock aggregator implementing the ITellerWithMultiAssetSupport interface.
 */
contract MockTeller is ITellerWithMultiAssetSupport {
    /// @notice Stores total "deposits" by (asset => user).
    mapping(address => mapping(address => uint256)) public shareBalances;
    function deposit(
        address depositAsset,
        uint256 depositAmount,
        uint256 /* minimumMint */
    ) external override returns (uint256 shares) {
        shares = depositAmount;
        // In a real aggregator, there would be an ERC20 transferFrom here:
        IERC20(depositAsset).transferFrom(
            msg.sender,
            address(this),
            depositAmount
        );
        shareBalances[depositAsset][msg.sender] += shares;

        emit DepositCalled(depositAsset, depositAmount, shares, msg.sender);
    }

    /// @notice Event emitted whenever a deposit is simulated.
    event DepositCalled(
        address depositAsset,
        uint256 depositAmount,
        uint256 sharesMinted,
        address caller
    );
}
