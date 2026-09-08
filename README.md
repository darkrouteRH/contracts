# DarkRoute contracts

Solidity for [DarkRoute](https://darkroute.exchange) — a private, non-custodial swap router on
Robinhood Chain (chain id 4663). No account, no KYC; the venue that fills your order is named as-is
and the fee is printed before you deposit.

- App — https://app.darkroute.exchange
- Docs — https://darkroute.exchange/docs
- `$DARK` — `0xebb4c5b97e4117e30ec82ce025e6f21dded05436`

**Nothing here is deployed and nothing here is audited.** The tests pass; that is a different
claim. See the checklist at the bottom.

```bash
forge install foundry-rs/forge-std --no-git   # lib/ is gitignored
forge test -vv
```

## DarkStaking

A commitment escrow for $DARK. Holding already qualifies an address for a fee tier; staking here
keeps the tokens in one readable place and marks the address as boosted while the commitment runs.

**It has no admin.** No owner, no pause, no upgrade path, no sweep, no fee. The only address that
can move a user's tokens is that user. The token address is immutable and set at construction.
There is deliberately nothing to trust here beyond the code.

**Unstaking is always allowed and nothing is burned.** That is the published design — an early exit
drops the boost immediately and costs nothing else, because penalties on a user's own funds invite
a regulatory argument nobody needs. The honest consequence: this escrow makes a commitment legible,
it does not force supply off the market. A user who wants out is out.

Read `tierBalance(address)` for tiers — staked plus held, so staking never lowers a tier.

## DarkBurner

The burn wall's ledger. A thin recorder in front of the token's own `burnFrom`.

Burning is already possible without it — what is not possible without it is knowing *why* a burn
happened. Calling `burn()` on the token emits a transfer to the zero address and nothing more; no
amount of reading that log tells you which day's revenue paid for it. This attaches a note, a
running total, and a per-source total, so protocol burns can be shown apart from anyone else's.

**It never holds tokens.** `burnFrom` pulls from the caller and destroys them in the same call, so
the contract's balance is permanently zero. Nothing to steal, no admin-withdrawal question.

**Anyone may burn.** No owner, no allowlist. The spam control is that burning costs the caller
their own tokens.

The caller must `approve` the burner first.

## What the $DARK token itself turned out to be

Read from the deployed bytecode on 2026-09-08:

| | |
|---|---|
| `burn(uint256)`, `burnFrom(address,uint256)` | **present** — burns really lower `totalSupply` |
| `mint(address,uint256)` | **absent** — supply cannot be inflated |
| `owner()`, `transferOwnership()`, `pause()` | **absent** — the token has no admin at all |

That is a genuinely clean fair-launch token, and it is checkable by anyone against the bytecode
rather than taken on trust.

### Before it goes anywhere near mainnet

1. **External audit.** The blueprint commits to one before Phase 2 and this is Phase 2.
2. **Deploy from a key that is not on the server.** Nothing in DarkRoute's infrastructure needs the
   deployer key, and per the project's own rules a key that lives on a box is a key that leaks.
3. Constructor takes the $DARK token: `0xebb4c5b97e4117e30ec82ce025e6f21dded05436`.
4. Verify on Blockscout, then point the app's tier reader at `tierBalance()` instead of the raw
   `balanceOf` in `lib/chain.ts`.

Not deployed. Not audited. Tests pass; that is not the same thing.
