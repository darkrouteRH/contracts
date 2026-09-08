// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20Burnable {
    function burnFrom(address account, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

/// @title DarkBurner — the burn wall's ledger
/// @notice A thin, non-custodial recorder in front of the token's own `burnFrom`. Burning is
///         already possible without this contract; what is not possible without it is a
///         structured, queryable public record of *why* each burn happened.
///
/// Why it exists at all:
///
/// - Calling `burn()` on the token directly emits a transfer to the zero address and nothing else.
///   No amount of reading that log tells you which day's revenue paid for it. This contract
///   attaches a note and a running total, which is what a burn wall actually needs.
///
/// - **It never holds tokens.** `burnFrom` pulls straight from the caller and destroys them in the
///   same call, so this contract's balance is always zero and there is nothing here to steal, and
///   no admin-withdrawal question to answer.
///
/// - **It really reduces supply.** The token exposes `burnFrom` and has no mint function, so a burn
///   here lowers `totalSupply` permanently rather than parking tokens at a dead address.
///
/// - **Anyone may burn.** There is no owner and no allowlist. Burning costs the caller their own
///   tokens, which is the only spam control this needs, and every entry records who did it so the
///   wall can show protocol burns separately from anyone else's.
contract DarkBurner {
    IERC20Burnable public immutable dark;

    uint256 public totalBurned;
    uint256 public burnCount;
    mapping(address => uint256) public burnedBy;

    event Burned(address indexed by, uint256 amount, uint256 totalBurned, string note);

    error ZeroAmount();
    error NoteTooLong();

    constructor(address darkToken) {
        if (darkToken == address(0)) revert ZeroAmount();
        dark = IERC20Burnable(darkToken);
    }

    /// @notice Destroy `amount` of the caller's $DARK and record it publicly.
    /// @param note Free text tying the burn to its source, e.g. "fees 2026-09-08". Kept short
    ///        because it is emitted, not stored, and calldata is the cost.
    /// @dev Requires the caller to have approved this contract for `amount` first.
    function burn(uint256 amount, string calldata note) external {
        if (amount == 0) revert ZeroAmount();
        if (bytes(note).length > 64) revert NoteTooLong();

        totalBurned += amount;
        burnCount += 1;
        burnedBy[msg.sender] += amount;

        // interactions last; reverts here undo the accounting above
        dark.burnFrom(msg.sender, amount);
        emit Burned(msg.sender, amount, totalBurned, note);
    }

    /// @notice Circulating supply as the token now reports it, after every burn to date.
    function supplyRemaining() external view returns (uint256) {
        return dark.totalSupply();
    }
}
