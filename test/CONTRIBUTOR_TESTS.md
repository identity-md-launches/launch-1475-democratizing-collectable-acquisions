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
| `ClaimLifecycleInvariant.t.sol` | Three traders, two conversion markets, changing limits, complete liquidity withdrawal/restoration, donated claims, unavailable native cash, rejecting recipients, unauthorized configuration and repeated redemptions. Uses `helpers/ClaimLifecycleHandler.sol`. |

The new stateless fee properties run 1,000 cases each. Both new invariant campaigns
run 256 sequences of 64 calls with unexpected reverts treated as failures. All
actions are explicitly targeted; no assumptions discard generated inputs.

The lifecycle model checks these identities after every action:

- Pair fees measured from wallet changes, plus donated pair claims, equal pair
  actually converted plus outstanding pair claims.
- ETH earned from conversion, plus donated ETH claims, equals the creator's ETH
  receipts plus outstanding ETH claims.
- Tracked holders retain the entire fixed DCA supply; the router and hook retain
  no unaccounted swap assets; the PoolManager is locked with no outstanding deltas.

After each lifecycle sequence, the handler restores recipient acceptance,
conversion liquidity and permissive price limits. A further trade and redemption
must recover the accumulated claims. A deterministic scenario also exercises the
empty-market, market-switch, rejected-payout and recovery transitions.

The token model records requested transfers and approvals independently of the
token's balances. Every holder balance and every holder/spender allowance is
compared to that model, including after rejected operations.

Run from the repository root:

```sh
forge build --offline
forge test --offline
forge coverage --offline --report summary
```

Local validation: 77 reported passes, zero failures and zero skips across 12
suites (Foundry groups each invariant campaign as one result). The coverage run
reports DCAHook at 99.29% lines, 98.00% statements and 91.18% branches; DCAToken,
HookBase and HookFlags have 100% line coverage. Coverage is not a security proof.

No implementation defect was reproduced by these additions. The paired token
and ETH recipient behavior are local simulations; these checks do not establish
production conversion-market liquidity or compatibility with live FWA contracts.
