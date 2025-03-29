// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title ITellerWithMultiAssetSupport
 * @dev Minimal interface for an aggregator (Teller) that supports multiple assets.
 *      This includes a deposit function for tokens.
 */
interface ITellerWithMultiAssetSupport {
    /**
     * @notice Deposit tokens into the aggregator (Teller).
     * @param depositAsset The token being deposited.
     * @param depositAmount The number of tokens to deposit.
     * @param minimumMint If >0, the aggregator might revert if minted shares < this.
     * @return shares The amount of aggregator shares minted.
     */
    function deposit(
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint
    ) external returns (uint256 shares);
}
