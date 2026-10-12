# Additional adversarial tests

These tests extend the accepted suite using its real PoolManager, mined DCAHook,
DCAToken, local router and paired-token mock. No network, environment variables,
forks, new dependencies or implementation changes are required.

| File | Additional guarantees checked |
| --- | --- |
| `FeeBoundaries.t.sol` | All four swap modes and both currency orderings; one-wei and 19/20-unit rounding boundaries; wallet-derived 5% fees; conversion amounts independently read from PoolManager events; no full-input substitution; maximum signed delta and exact-output gross-up boundary. |
| `HookFailurePaths.t.sol` | Exact error selectors for invalid state, pool identity, amounts and conversion configuration; partial-fill, settlement and late-slippage failures restore both pools, LP fee growth, existing claims and creator payments. |
| `ClaimRedemption.t.sol` | Old and new ETH credits with partial cash availability or a rejecting recipient; redemption above the signed-delta limit; replay prevention; rejected nested unlock leaves no authorization behind; even the owner cannot change the conversion route during a payout. |
| `TokenStateful.t.sol` | Four-holder model of balances and allowances across transfers, full-balance transfers, approvals, delegated transfers and rejected operations; allowance rollback, revocation, infinite allowances and self-transfers. |
| `ClaimLifecycleInvariant.t.sol` | Three traders, two conversion markets, changing limits, complete liquidity withdrawal/restoration, donated claims, unavailable native cash, rejecting recipients, unauthorized configuration, repeated redemptions, direct market manipulation in both directions, block advances and the owner's FWA exit. A ghost model of the anchor ratchet (first anchor is the configured price, at most one bound step up per promotion, at most one change per block, no change outside a trade or configuration). Uses `helpers/ClaimLifecycleHandler.sol`. |
| `AnchorAndPairExit.t.sol` | The per-block conversion anchor under a move made in an earlier block (one deferral, then one capped step per block until the bound clears spot, then exact catch-up), a lowered spot tightening the bound, a dip held across a block boundary deferring for a counted number of blocks and then recovering, reconfiguration resetting the anchor, and a 400-case property that no sale ever passes the owner's relative bound or absolute ceiling and no promotion lifts the anchor over one step under same-block or earlier-block manipulation. The owner's FWA exit with a separate owner and recipient, chunking above the signed-delta limit, isolation from the ETH exit, and refusal from inside a foreign unlock. |

The stateless fee properties run 1,000 cases each; the anchor property runs 400.
Both invariant campaigns run 256 sequences of 64 calls with unexpected reverts
treated as failures. All actions are explicitly targeted; no assumptions discard
generated inputs.

The lifecycle model checks these identities after every action:

- Pair fees measured from wallet changes, plus donated pair claims, equal pair
  actually converted plus pair paid out by the owner's exit plus outstanding pair
  claims; the recipient holds exactly the exited FWA.
- ETH earned from conversion, plus donated ETH claims, equals the creator's ETH
  receipts plus outstanding ETH claims.
- Every hook sale on the conversion market, read from the market's own Swap
  event, ends at or below the owner's relative bound from the anchor the hook
  promoted in an earlier block, and below the absolute ceiling, whatever
  manipulation preceded it in the same or an earlier block.
- The anchor the hook reports is the one the handler watched it promote: zero
  after a configuration, then exactly the configured price, then never more
  than one bound step above its previous value, changing at most once per block
  and only inside a trade.
- Tracked holders retain the entire fixed DCA supply; the router and hook retain
  no unaccounted swap assets; the PoolManager is locked with no outstanding deltas.

After each lifecycle sequence, the handler restores recipient acceptance,
conversion liquidity and permissive price limits. Trades in fresh blocks must then
drain the backlog at the capped pace (each sells its own fee plus at most four
times it), and anything a bounded number of trades leaves must clear through the
owner's exit; nothing may be stranded. Deterministic scenarios also exercise the
empty-market, market-switch, rejected-payout and recovery transitions, and the
earlier-block manipulation, deferral, promotion and owner-exit sequence.

The token model records requested transfers and approvals independently of the
token's balances. Every holder balance and every holder/spender allowance is
compared to that model, including after rejected operations.

Run from the repository root:

```sh
forge build --offline
forge test --offline
forge coverage --offline --report summary
```

Local validation: 100 reported passes, zero failures and zero skips across 14
suites (Foundry groups each invariant campaign as one result). The coverage
figures in the previous revision were measured before the anchor ratchet was
added to the implementation and are not repeated here. Coverage is not a
security proof.

Revision after the anchor ratchet: the earlier test that expected the anchor to
adopt an earlier-block move wholesale now expects one capped step per block,
and the ratchet is modelled in the fuzz property and the invariant handler.

One defect in the ratcheted implementation is reported in `.imd-findings.json`
rather than asserted as correct: a promotion is triggered by any fee-bearing
swap, and a 20 wei buy pays a 1 wei fee, so the anchor can be walked up to a
spike held across blocks for a few wei per block (13 blocks to 1.8x in sqrt
price at the maximum setting), after which the backlog is sold into the spike
and the attacker profits. The README's statement that each step costs a 5% fee
describes 1 wei. The accepted ceiling is the only bound that holds against this.
A second, lower point is tested rather than reported with a proof: a dip held
across a block boundary is adopted in full, so a griefer can defer conversion
for a counted number of blocks (seven for a 30% sqrt dip) at the cost of two
market swaps; no fee is lost. An owner-chosen conversion market with its own
hook remains trusted by the owner, who is the recipient. The paired token and
ETH recipient behavior are local simulations; these checks do not establish
production conversion-market liquidity or compatibility with live FWA contracts.
