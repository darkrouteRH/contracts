// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title DarkStaking — non-custodial commitment escrow for $DARK
/// @notice Holding $DARK already qualifies an address for a fee tier. Staking here is a public
///         commitment on top of that: it keeps the tokens in one readable place and, while the
///         commitment is intact, marks the address as boosted.
///
/// Design notes, each one deliberate:
///
/// - **There is no admin.** No owner, no pause, no upgrade path, no sweep, no fee. Nothing in this
///   contract can move a user's tokens except that user. The only privileged address is the token
///   address itself, and that is immutable and set at construction.
///
/// - **Unstaking is always allowed, and there is no penalty burn.** That is the published design:
///   an early exit drops the boost immediately and costs nothing else. Penalties on a user's own
///   funds invite a regulatory argument nobody needs, and the boost is meant to be the carrot.
///   The practical consequence is that this escrow does not *force* supply off the market — it
///   makes a commitment legible, and breaking it is free apart from losing the boost.
///
/// - **tierBalance = staked + held**, so staking never lowers the tier an address already had.
///   Anyone reading tiers should read this one function rather than the raw token balance.
contract DarkStaking {
    IERC20 public immutable dark;

    struct Commitment {
        uint128 amount; // tokens held by this contract for the address
        uint32 lockDays; // 30, 90 or 180 — the length that was committed to
        uint64 until; // unix seconds; 0 once the commitment is broken or matured out
    }

    mapping(address => Commitment) private _commit;
    uint256 public totalStaked;

    event Staked(address indexed account, uint256 amount, uint32 lockDays, uint64 until);
    event Unstaked(address indexed account, uint256 amount, bool early);

    error ZeroAmount();
    error BadLock();
    error InsufficientStake();
    error TransferFailed();

    constructor(address darkToken) {
        if (darkToken == address(0)) revert ZeroAmount();
        dark = IERC20(darkToken);
    }

    /// @notice Stake `amount` and commit to leaving it for `lockDays`.
    /// @dev Staking again extends the commitment but never shortens one already running.
    function stake(uint256 amount, uint32 lockDays) external {
        if (amount == 0) revert ZeroAmount();
        if (lockDays != 30 && lockDays != 90 && lockDays != 180) revert BadLock();

        Commitment memory c = _commit[msg.sender];
        uint64 candidate = uint64(block.timestamp + uint256(lockDays) * 1 days);
        uint64 until = candidate > c.until ? candidate : c.until;

        _commit[msg.sender] = Commitment({
            amount: uint128(c.amount + amount), lockDays: candidate >= c.until ? lockDays : c.lockDays, until: until
        });
        totalStaked += amount;

        // interactions last
        if (!dark.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Staked(msg.sender, amount, lockDays, until);
    }

    /// @notice Withdraw staked tokens. Always permitted. Leaving early breaks the commitment and
    ///         the boost stops applying from that moment; nothing is confiscated or burned.
    function unstake(uint256 amount) external {
        Commitment memory c = _commit[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > c.amount) revert InsufficientStake();

        bool early = block.timestamp < c.until;
        uint128 remaining = uint128(c.amount - amount);

        // Any withdrawal ends the commitment: a promise partly kept is not the promise that was
        // made, and leaving a stale `until` would let a partial exit keep the boost.
        _commit[msg.sender] = Commitment({amount: remaining, lockDays: remaining == 0 ? 0 : c.lockDays, until: 0});
        totalStaked -= amount;

        if (!dark.transfer(msg.sender, amount)) revert TransferFailed();
        emit Unstaked(msg.sender, amount, early);
    }

    // ---------------------------------------------------------------- views

    /// @notice Tokens this contract holds for `account`.
    function stakedOf(address account) external view returns (uint256) {
        return _commit[account].amount;
    }

    /// @notice The commitment as recorded: amount, the length committed to, and when it matures.
    function commitmentOf(address account) external view returns (uint256 amount, uint32 lockDays, uint64 until) {
        Commitment memory c = _commit[account];
        return (c.amount, c.lockDays, c.until);
    }

    /// @notice True while an unbroken commitment is still running.
    function boostActive(address account) external view returns (bool) {
        Commitment memory c = _commit[account];
        return c.amount > 0 && c.until > block.timestamp;
    }

    /// @notice What a tier reader should use: staked here plus held in the wallet.
    function tierBalance(address account) external view returns (uint256) {
        return _commit[account].amount + dark.balanceOf(account);
    }
}
