// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Basic library for safe transfers of IERC20 tokens.
 *      If you prefer, you could import OpenZeppelin's SafeERC20 instead.
 */
library SafeTransfer {
    function safeTransferFrom(
        IERC20 token,
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        bool success = token.transferFrom(sender, recipient, amount);
        require(success, "TransferFrom failed");
    }

    function safeTransfer(
        IERC20 token,
        address recipient,
        uint256 amount
    ) internal {
        bool success = token.transfer(recipient, amount);
        require(success, "Transfer failed");
    }
}

contract HookVault is AccessControl, ReentrancyGuard {
    using SafeTransfer for IERC20;
    
    bytes32 public constant HOOK_ROLE = keccak256("HOOK_ROLE");

    IERC20 public immutable token; // The underlying ERC20 token
    uint256 public totalShares; // Total shares in circulation

    mapping(address => uint256) public shareBalance;

    // --- Events ---
    event Deposit(
        address hook, 
        address indexed account,
        uint256 indexed amount,
        uint256 indexed shares 
    );

    event Withdraw(
        address hook, 
        address indexed account, 
        uint256 indexed amount, 
        uint256 indexed shares
    );

    // --- Constructor ---
    constructor(IERC20 _token) {
        token = _token;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // --- Functions ---
    function deposit(
        address account,
        uint256 amount
    ) external onlyRole(HOOK_ROLE) nonReentrant returns (uint256 shares) {
        require(account != address(0), "Invalid account");
        require(amount > 0, "Deposit amount must be > 0");

        uint256 vaultBalance = token.balanceOf(address(this));

        // If no shares exist yet, 1 share = 1 token
        if (totalShares == 0 || vaultBalance == 0) {
            shares = amount;
        } else {
            // Maintain the ratio: shares : totalShares :: amount : vaultBalance
            shares = (amount * totalShares) / vaultBalance;
        }

        // Update share balances
        totalShares += shares;
        shareBalance[account] += shares;

        // Transfer tokens from the specified account into this vault
        token.safeTransferFrom(account, address(this), amount);

        emit Deposit(msg.sender, account, amount, shares);

        return shares;
    }

    function withdraw(
        address account,
        uint256 shares
    ) external onlyRole(HOOK_ROLE) nonReentrant returns (uint256 amount) {
        require(account != address(0), "Invalid account");
        require(shares > 0, "Shares must be > 0");
        require(shareBalance[account] >= shares, "Not enough shares");

        uint256 vaultBalance = token.balanceOf(address(this));

        // Calculate how many tokens correspond to these shares
        amount = (shares * vaultBalance) / totalShares;

        // Update share balances
        shareBalance[account] -= shares;
        totalShares -= shares;

        // Transfer tokens to the user
        token.safeTransfer(account, amount);

        emit Withdraw(msg.sender, account, amount, shares);

        return amount;
    }

    function grantHookRole(
        address hookAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(HOOK_ROLE, hookAddress);
    }

    function revokeHookRole(
        address hookAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(HOOK_ROLE, hookAddress);
    }
}
