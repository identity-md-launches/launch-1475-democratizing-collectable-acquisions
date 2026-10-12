# Local security review

Scope: DCAToken, DCAHook, HookBase, HookFlags, and the explicit-argument salt miner. This is the implementer's local review, informed by the supplied Ethereum and Uniswap v4 security references. It is not an independent audit. The vendored real PoolManager is used in integration tests; production RPC state was not consulted.

## Permissions and authority

| Surface | Restriction / assessment |
| --- | --- |
| Initialization | Only the immutable manager can call; callback sender must be the immutable factory. Exact token/FWA, hook, fee 12500 and spacing 60 are validated. One initialization per hook. |
| beforeSwap / afterSwap | Only the manager; exact initialized PoolId; configured conversion route; nonzero bounded amount. Router identity and hookData do not grant privileges. |
| Returned deltas | Fixed 5% FWA fee only. Positive specified delta is smaller than a buy's gross input; exact-output sells gross up with a signed-range check. afterSwap charges only the FWA side. No LP-fee override or full-swap substitution. |
| Disabled callbacks | All seven reject direct callers and always revert even for the manager. Their address flags are off, so normal liquidity addition/removal and donations never invoke them. |
| Conversion settings | Only explicit immutable owner, with reentrancy guard; validates currency order, fee, tick spacing, hook address/code, existing pool and price bounds. Emits configuration event. Owner cannot directly transfer or burn claim balances, change the fee/recipient, mint DCA, or change code. |
| ETH redemption | Permissionless, but pays only the fixed creator. Opens manager unlock; callback checks manager and a one-use pending-redemption flag. |
| Ownership / upgrades | No transfer, renunciation, proxy, delegatecall, selfdestruct, pause or arbitrary execute path. Owner key availability is an operational dependency. |
| Token | Standard ERC20 with constructor-only mint; fixed 18 decimals and 10^27 minor-unit supply to factory. Transfers and approvals use OpenZeppelin behavior. |

All delta-changing operations are reached through the authenticated, guarded afterSwap or through the redemption callback while the guarded redemption entry point is active. beforeSwap returns only arithmetic deltas and does not move funds. The manager's AMM work between beforeSwap and afterSwap makes no call to an external market on the hook's behalf. afterSwap's nested conversion is protected against callback reentry.

The conversion pool may have another hook. It is an owner-chosen trust dependency: price limits do not constrain arbitrary extra charges or deliberate failure by that external hook. Incorrect-sign output and overspending are rejected. A reverting or otherwise unusable route blocks swaps until configuration is repaired. External reentry into either a launch swap or redemption is tested and rejected. Recipient reentry is tested both during swap payout and during claim redemption.

## Delta conservation

Let `F` be the new FWA fee, `O` the old FWA claims burned for this conversion, `S` FWA actually sold, and `E` native ETH returned. The maximum attempted input is signed-128-bit bounded.

| FWA operation | Hook's manager delta |
| --- | --- |
| Burn old claims | `+O` |
| Conversion sale | `-S` |
| Mint unsold claims | `-(F + O - S)` |
| Manager credits returned launch-hook fee after callback | `+F` |
| Total | **0** |

ETH output creates `+E`. The aggregate effect of paying ETH, burning affordable old ETH claims, and minting unavailable or rejected payouts is `-E`. A pure redemption burns `P` claims (`+P`) and takes `P` ETH (`-P`). If `take` reverts, its debit rolls back and the hook remints the claim. No token transfer or separate settlement is required for FWA conversion: all movements occur within the manager's accounting.

Tests assert zero remaining deltas across all participants after unlock, fee conservation, token supply/balance conservation, native payout/claim conservation, and no DCA/FWA held by the hook. The PoolManager's own nonzero-delta check remains active in every integration test.

## Arithmetic and execution limits

- Fee basis is gross FWA, rounded down; exact-output calculations use `net * 500 / 9500`. Since net is bounded to signed-128-bit magnitude, intermediate multiplication cannot overflow uint256.
- SafeCast checks narrowing/sign conversions. `type(int256).min`, zero amounts, out-of-range amounts and excessive exact-output gross-up are rejected.
- Partial FWA-specified fills revert atomically; charging an unfilled specified amount is never retained. DCA-specified partial fills use actual FWA deltas.
- No unbounded runtime loop in either launch contract. Claim conversion/redemption caps work to signed-128-bit values. The off-chain miner has a caller-bounded search.
- Fees and rates operate on raw currency units; no incorrect decimal rescaling is introduced. The 18-decimal DCA supply and FWA identity come from the assignment.
- Relative conversion price bound is rounded conservatively and combined with an explicit absolute price ceiling. Neither is represented as a fair-value oracle. LP fees, external hook fees and integer dust are separate execution costs.
- No allowances are granted by the hook. FWA is never transferred out of the manager to it. A mock that blocks exactly that transfer is used throughout integration tests.
- Native ETH currency zero is intentional. Direct native transfers to a funded hook are unsupported; fees go directly to the recipient or remain manager claims.

## Test evidence and limitations

The suite covers both directions, both exactness modes and both token orderings; successful and unauthorized initialization; actual CREATE2 deployment; owner configuration changes; invalid configuration and callback inputs; real nested swaps; relative and absolute price bounds; claim rollover; zero conversion liquidity; fresh token-only manager balances with delayed native settlement; partial/native-zero balances; rejected payouts; redemption replay prevention; recipient and external-hook reentry; negative conversion output; user slippage rollback; token success/failure cases; and liquidity withdrawal while conversion remains unset.

Stateful randomized sequences combine trades, limit changes, recipient refusal, native liquidity shortages and redemption. Ghost totals check FWA and ETH conservation independently of the hook's persistent storage. Fuzz tests vary swap direction, exactness, amounts, and token transfers. Runtime opcode scans skip PUSH data and verify no SELFDESTRUCT, DELEGATECALL or CALLCODE; deployed sizes remain below EIP-170. Creation and runtime artifacts have no library link references.

Foundry's lint reports guarded external-call/event patterns in the hook and test scaffolding. The redemption call runs while OpenZeppelin's guard is entered; only the expected manager callback can pass the pending flag, which is cleared before any payout. Post-call events report actual conversion/payout outcomes under the same guard. `unlock()` returns the callback's unused empty byte string. These diagnostics were reviewed against these paths; they are not claimed to be findings from Slither. The build and tests pass with them.

**Outstanding release work:** independent adversarial review; a recent Ethereum fork rehearsal using the real FWA transfer restrictions, manager, factory and chosen conversion market; owner-approved price limits; production gas/MEV and liquidity assessment; deployed bytecode/permission verification; explorer verification and monitoring. Slither, Mythril, formal verification and an independent external audit were not run here. Claims can remain pending indefinitely when no later trade occurs, limits remain adverse, the manager lacks native balance or the recipient permanently refuses payment. Owner configuration is therefore an ongoing responsibility.
