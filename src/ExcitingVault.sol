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

/**
 * @title HookVault
 * @notice A vault that holds multiple ERC20 tokens, each with its own share accounting.
 *         Access is controlled by HOOK_ROLE for deposit/withdraw calls.
 *
 * @dev This contract is an extended version of your single-token HookVault,
 *      updated to support multiple tokens. Each token tracks:
 *         - totalShares[token]
 *         - shareBalance[token][user]
 *
 *      1 share = 1 token if no shares exist for that token, or if the vault is empty for that token.
 *      Otherwise, we maintain the ratio:
 *          shares : totalShares[token] :: depositAmount : vaultBalanceOf(token)
 */
contract HookVault is AccessControl, ReentrancyGuard {
    using SafeTransfer for IERC20;

    // ============================================================
    // Roles
    // ============================================================
    bytes32 public constant HOOK_ROLE = keccak256("HOOK_ROLE");

    // ============================================================
    // Data Structures
    // ============================================================

    /**
     * @dev Mapping from a token => total shares minted for that token.
     *      Each ERC20 tracks its own share supply.
     */
    mapping(IERC20 => uint256) public totalShares;

    /**
     * @dev Mapping from (token => (user => share balance)).
     *      shareBalance[usdc][alice] = how many USDC shares `alice` holds.
     */
    mapping(IERC20 => mapping(address => uint256)) public shareBalance;

    // ============================================================
    // Events
    // ============================================================

    /**
     * @notice Emitted when a user deposits a given token.
     * @param hook The caller that has the HOOK_ROLE.
     * @param account The account that receives shares.
     * @param token The ERC20 token deposited.
     * @param amount Amount of that token deposited.
     * @param shares Number of vault shares minted to `account`.
     */
    event Deposit(
        address hook,
        address indexed account,
        IERC20 indexed token,
        uint256 indexed amount,
        uint256 shares
    );

    /**
     * @notice Emitted when a user withdraws a given token.
     * @param hook The caller that has the HOOK_ROLE.
     * @param account The account whose shares are burned.
     * @param token The ERC20 token withdrawn.
     * @param amount Amount of that token sent out.
     * @param shares Number of vault shares burned.
     */
    event Withdraw(
        address hook,
        address indexed account,
        IERC20 indexed token,
        uint256 indexed amount,
        uint256 shares
    );

    // ============================================================
    // Constructor
    // ============================================================

    /**
     * @notice Deploys the HookVault with the deployer as DEFAULT_ADMIN_ROLE.
     * @dev You no longer store a single `token` in the constructor, as we support many tokens.
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============================================================
    // Public Functions
    // ============================================================

    /**
     * @notice Allows an authorized HOOK_ROLE caller to deposit ERC20 tokens on behalf of `account`.
     * @dev Mints shares proportional to the vault's balance for this token.
     *
     * @param token   The ERC20 being deposited.
     * @param account The user receiving vault shares.
     * @param amount  The amount of `token` to deposit.
     *
     * @return shares The number of shares minted to `account`.
     */
    function deposit(
        IERC20 token,
        address account,
        uint256 amount
    ) external onlyRole(HOOK_ROLE) nonReentrant returns (uint256 shares) {
        require(account != address(0), "Invalid account");
        require(amount > 0, "Deposit amount must be > 0");
        // Token address must be non-zero
        require(address(token) != address(0), "Invalid token");

        // Current token balance in this vault
        uint256 vaultBalance = token.balanceOf(address(this));
        uint256 currentTotalShares = totalShares[token];

        // If no shares exist yet, or vaultBalance == 0, set 1 share = 1 token
        if (currentTotalShares == 0 || vaultBalance == 0) {
            shares = amount;
        } else {
            // Maintain ratio: shares : totalShares[token] :: amount : vaultBalance
            shares = (amount * currentTotalShares) / vaultBalance;
        }

        // Update share balances for this token
        totalShares[token] = currentTotalShares + shares;
        shareBalance[token][account] += shares;

        // Transfer tokens from `account` into this vault
        token.safeTransferFrom(account, address(this), amount);

        emit Deposit(msg.sender, account, token, amount, shares);
        return shares;
    }

    /**
     * @notice Allows an authorized HOOK_ROLE caller to withdraw tokens from the vault on behalf of `account`.
     * @dev Burns a specified number of shares, returning the corresponding token amount to `account`.
     *
     * @param token   The ERC20 being withdrawn.
     * @param account The user whose shares are being burned.
     * @param shares  The number of vault shares to burn.
     *
     * @return amount The amount of `token` actually sent to `account`.
     */
    function withdraw(
        IERC20 token,
        address account,
        uint256 shares
    ) external onlyRole(HOOK_ROLE) nonReentrant returns (uint256 amount) {
        require(account != address(0), "Invalid account");
        require(shares > 0, "Shares must be > 0");
        require(shareBalance[token][account] >= shares, "Not enough shares");
        // Token address must be non-zero
        require(address(token) != address(0), "Invalid token");
        // Current token balance in this vault
        require(
            token.balanceOf(address(this)) > 0,
            "Vault balance must be > 0"
        );

        uint256 vaultBalance = token.balanceOf(address(this));
        uint256 currentTotalShares = totalShares[token];

        // Compute how many tokens correspond to the given shares
        amount = (shares * vaultBalance) / currentTotalShares;

        // Update share balances
        shareBalance[token][account] -= shares;
        totalShares[token] = currentTotalShares - shares;

        // Transfer tokens out to the user
        token.safeTransfer(account, amount);

        emit Withdraw(msg.sender, account, token, amount, shares);
        return amount;
    }

    // ============================================================
    // Role Management
    // ============================================================

    /**
     * @notice Grants the HOOK_ROLE to a hook address (e.g. your Hook contract).
     * @param hookAddress The address to grant HOOK_ROLE.
     */
    function grantHookRole(
        address hookAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(HOOK_ROLE, hookAddress);
    }

    /**
     * @notice Revokes the HOOK_ROLE from a hook address.
     * @param hookAddress The address to revoke HOOK_ROLE.
     */
    function revokeHookRole(
        address hookAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(HOOK_ROLE, hookAddress);
    }
}
