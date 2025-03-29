// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "../lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @dev A simplified mock for Aave Pool that:
 *      - On supply(asset, amount, onBehalfOf, referralCode) => track how much `onBehalfOf` deposited
 *      - On withdraw(asset, amount, to) => only the same `onBehalfOf` can withdraw its own deposit
 *      - Reverts if user tries to withdraw more than they deposited
 *
 * Also includes plenty of console logs for debugging.
 */
contract MockAavePool {
    // Track how much each user has deposited for each asset
    mapping(address => mapping(address => uint256)) public deposits;
    // Helper to show how many tokens total are "held" in this mock
    mapping(address => uint256) public totalSupplied; // asset => total

    /**
     * @notice For debugging we store how many tokens are "actually" supplied to the pool
     *         by each user: returns deposits[asset][user]
     */
    function suppliedBalances(
        address asset,
        address user
    ) external view returns (uint256) {
        return deposits[asset][user];
    }

    /**
     * @notice Supply tokens to "Aave". We do a transferFrom(...), then credit `deposits[asset][onBehalfOf]`.
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /*referralCode*/
    ) external {
        console.log(
            "=============== MockAavePool: supply Incoming =========================="
        );
        console.log("MockAavePool: msg.sender =>", msg.sender);
        console.log("MockAavePool: asset =>", asset);
        console.log("MockAavePool: amount =>", amount);
        console.log("MockAavePool: onBehalfOf =>", onBehalfOf);

        // Transfer the tokens in
        IERC20(asset).transferFrom(msg.sender, address(this), amount);

        // Increase "onBehalfOf" deposit record
        deposits[asset][onBehalfOf] += amount;
        totalSupplied[asset] += amount;
    }

    /**
     * @notice Withdraw tokens from "Aave". Only the same user can withdraw its own deposit.
     * @param asset The token asset
     * @param amount The max they want to withdraw
     * @param to The address that receives the tokens
     * @return finalAmount The actual withdrawn
     */
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256 finalAmount) {
        console.log(
            "=============== MockAavePool: withdraw Incoming =========================="
        );
        console.log("MockAavePool: msg.sender =>", msg.sender);
        console.log("MockAavePool: asset =>", asset);
        console.log("MockAavePool: amount =>", amount);
        console.log("MockAavePool: to =>", to);

        // Check how much msg.sender actually deposited
        uint256 userBal = deposits[asset][msg.sender];
        if (amount > userBal) {
            revert("Not enough");
        }

        // user can withdraw up to userBal
        finalAmount = amount;
        // Decrease deposit
        deposits[asset][msg.sender] = userBal - amount;
        // Transfer to the "to" address
        IERC20(asset).transfer(to, amount);
        totalSupplied[asset] -= amount;
    }

    /**
     * @notice For completeness, a read-only function to get internal record
     */
    function getReserveData(
        address /*asset*/
    )
        external
        pure
        returns (
            // returning only aTokenAddress for the Hook's getATokenAddress usage
            // We'll just pretend to return "address(this)"
            structData memory
        )
    {
        // We'll define an empty struct that has "aTokenAddress" as itself
        // to keep Hook's `getATokenAddress` happy
        return structData({aTokenAddress: address(0)});
    }

    // The actual Aave struct is big, but we only need to return aTokenAddress
    struct structData {
        address aTokenAddress;
    }
}
