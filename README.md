# Democratizing Collectable Acquisions (DCA)

This Foundry project implements a fixed-supply DCA token and a Uniswap v4 hook that charges **5% of the gross FWA side of each swap in its launch pool** for **0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d**. The hook sells collected FWA for native ETH within the same swap, under price bounds anchored to an earlier block, and pays that fixed recipient. Price-limited or unsellable FWA and unavailable ETH payouts remain PoolManager ERC-6909 claims; they are never silently discarded, and the fee is charged on every swap whether or not a conversion market is configured or usable.

## Contracts and build

- `src/DCAToken.sol`: standard OpenZeppelin ERC-20; name `Democratizing Collectable Acquisions` (the brief's exact spelling, kept verbatim rather than corrected; the manifest's token name must match it), symbol `DCA`, 18 decimals, exactly **1,000,000,000 tokens / 10^27 minor units**, minted once to its deployer (the launch factory). No constructor arguments, additional minting, owner, transfer tax, pause, blacklist, or upgrade mechanism.
- `src/DCAHook.sol`: immutable 500 bps fee and recipient; authenticates the manager, factory initialization, and exact launch pool. Configuration authority is the explicit immutable `initialOwner`, never the constructor caller or transaction origin.
- `src/HookBase.sol`: manager-only disabled callbacks that always revert.
- `src/HookFlags.sol`: permission-bit definitions and matching helpers.
- `script/MineHook.s.sol`: salt finder with explicit arguments; does not broadcast or use a wallet.
- `test/`: token, deployment, real PoolManager integration, adversarial, fuzz, and stateful invariant tests. The router and token mocks are test scaffolding, not launch contracts.

```sh
forge build
forge test
forge fmt --check
```

Solidity **0.8.26**, Cancun, optimizer 200 runs, and `bytecode_hash = "none"` are pinned in `foundry.toml`. Dependencies are ordinary files in `lib/`; no network downloads, submodules, FFI, filesystem permissions, RPC, or environment variables are needed by the build or tests. Foundry and the pinned compiler must already be installed. See [DEPENDENCIES.md](DEPENDENCIES.md) for source revisions and licenses.

## Fee accounting

A buy spends FWA for DCA; a sell spends DCA for FWA. Let `G` be gross FWA, `N` be a requested net FWA output, and `R` be the FWA input required by the AMM before this hook's charge. All division rounds down in minor units.

| Swap | Fee | AMM / trader behavior |
| --- | --- | --- |
| Buy, exact FWA input `G` | `floor(G / 20)` | AMM receives `G - fee`; trader pays exactly `G` |
| Buy, exact DCA output | `floor(R / 19)` | Trader pays `R + fee`; requested DCA output is unchanged |
| Sell, exact DCA input | `floor(G / 20)` on actual AMM FWA output | Trader receives `G - fee` |
| Sell, exact FWA output `N` | `floor(N / 19)` | AMM produces `N + fee`; trader receives exactly `N` |

In all four cases `fee = floor(gross FWA / 20)`. The gross-up in the exact-output cases keeps the fee at 5% of gross, rather than taking 5% of an already net amount. Rounding is at most one FWA minor unit; gross amounts below 20 minor units can pay zero fee. The separate **1.25% LP fee (12500)** remains enabled and is never overridden. Conversion-market fees, rounding and price impact reduce the ETH ultimately received for the collected FWA.

The hook uses positive specified deltas in `beforeSwap` only when FWA is the specified currency; otherwise it returns the FWA fee as an unspecified delta in `afterSwap`. It never charges DCA, substitutes for the full AMM swap, or accepts a caller-selected fee/recipient in hook data. Both token orderings work at the hook level; see "FWA transfer restrictions" below for who can actually move FWA through the manager.

**Partial fills:** a buy with exact FWA input or a sell with exact FWA output must fill the adjusted FWA amount completely. Otherwise the entire transaction reverts with `PartialFillNotSupported`. v4 cannot refund an already specified fee using the unspecified-only after-swap delta. DCA-specified partial fills charge only the FWA actually exchanged. **Integrators: send FWA-specified orders (exact-input buys, exact-output sells) with `sqrtPriceLimitX96` at `MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1` and protect them with min-output / max-input checks**, not with a tight price limit; a price limit that stops the fill reverts the order instead of partially filling it. Routers must still enforce user minimum outputs, maximum inputs, deadlines and exact-output fulfillment. Successful swaps must fit the v4 signed 128-bit delta range, including any gross-up.

## Conversion and payout

The owner selects an **already initialized native-ETH/FWA pool on the same manager**. Native ETH is v4 currency address zero; this is the protocol's native-currency representation, not a placeholder address. WETH is not interchangeable with it. The key must have native ETH as currency0 and the specified FWA token as currency1. The conversion market may have its own hook and must accept swaps with empty hook data. Its implementation and liquidity must be reviewed by the owner.

Each `afterSwap` that charged a nonzero fee, while a market is configured, combines that fee with part of the existing FWA claim backlog, burns those claims, and swaps FWA exact-input (`zeroForOne = false`). It never calls `take(FWA, hook, ...)` or requires a transfer from FWA to the hook. Unspent FWA is minted back as ERC-6909 claims. Three rules keep a trader from using the conversion against the creator:

- **No sale on a fee-free swap.** A swap whose fee rounds to zero (gross FWA below 20 minor units) mints nothing and sells nothing; it cannot move the backlog. `ConversionSkipped` is emitted.
- **Backlog cap.** Old claims sold beside a new fee are at most `BACKLOG_MULTIPLE` (4) times that fee, so each swap sells at most five times its own fee. Moving the backlog therefore costs the trader a real 5% fee that goes to the creator, which exceeds what a bounded price move could return. A large backlog drains over several fee-bearing swaps.
- **Prior-block anchor.** The relative bound is measured from `anchorSqrtPriceX96`, the market price observed by the last sale attempt in an *earlier* block (promoted from `observedSqrtPriceX96` / `observedBlock` on the first attempt of a new block). The base price is the lower of the anchor and current spot, so lowering spot only tightens the bound. If spot is already more than the bound above the anchor, the market moved this block and the sale is deferred to claims. Every sale attempt in one block shares the same anchor, so one block's conversions together move the market by at most `maxPriceMoveBps`. `setConversionPool` resets the anchor, so sales resume in the block after configuration.

The conversion's `sqrtPriceLimitX96` is the smaller of:

1. the base price (min of anchor and spot) multiplied by `sqrt(1 + maxPriceMoveBps / 10000)`; and
2. the owner's absolute `maxConversionSqrtPriceX96` ceiling.

The relative factor uses 1e9 precision and rounds down. `maxPriceMoveBps` is between 1 and 1000, inclusive. Price here means **FWA per ETH**, because ETH is currency0: selling FWA raises that price. A higher ceiling permits a worse FWA sale price. The absolute bound provides a minimum acceptable market price for FWA even when the anchor has drifted. Neither bound is a fair-value oracle: a manipulation held across two blocks (exposed to arbitrage in between) can still shift the anchor by at most `maxPriceMoveBps` per block. Conversion LP/hook fees are additional to these price bounds.

The market sale runs inside `try`/`catch` with a fixed `CONVERSION_GAS` stipend (2,000,000). A market whose hook reverts, that is uninitialized for the configured key, or that burns more gas than the stipend (for example dust positions seeded on every tick of a spacing-1 market) only defers the fee to claims; it never reverts the launch swap, and the cost of a launch swap is bounded by the stipend. A market hook that returns an impossible delta (ETH owed by the hook, or more FWA spent than offered) still reverts the swap atomically, because the manager's accounting cannot be unwound after a successful call.

If no market is configured, spot is at/above the ceiling, the sale is deferred, or liquidity is exhausted within the bound, FWA remains as claims and is retried alongside the next fee-bearing swap. Without another trade, those unsold claims remain pending. The owner can call `redeemPair()` to burn all FWA claims and take the FWA from the manager straight to the fixed recipient (never to the hook); FWA's transfer guard must allow the manager-to-recipient transfer, otherwise the call reverts and the claims are preserved. That exit bypasses ETH settlement and is meant for a route that cannot be repaired.

ETH output is paid immediately to the fixed creator, up to the manager's available native balance. Any excess becomes ETH claims. A rejecting recipient also causes the payout to become claims instead of blocking a normally gas-bounded swap. Later swaps automatically retry ETH payouts. Anyone can call `redeemEth()` while the manager is locked; it opens an unlock, burns affordable ETH claims and sends only to the fixed recipient. A failed redemption preserves the claims. Repeated calls cannot double-pay. The manager must hold actual native ETH to redeem; claims are not new ETH, and a wallet cannot redeem directly without the hook's callback. If the recipient permanently refuses ETH, those payouts remain pending until it can receive again. As with any external call, a recipient or conversion hook deliberately exhausting gas can still cause a transaction to fail.

## Deployment parameters

Only **DCAToken** and **DCAHook** are launch contracts. Do not deploy test helpers. No launch manifest is supplied; the launch's separate manifest step owns it.

| DCAHook constructor argument | Manifest binding / required value |
| --- | --- |
| `IPoolManager manager` | `$poolManager`, supplied by the launch; never hardcoded |
| `address launchToken` | `$token`, the just-deployed DCAToken |
| `address launchFactory` | `$factory`, the contract that will call `PoolManager.initialize` |
| `address initialOwner` | `$owner`, **0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d** for this launch |

The constructor checks nonzero arguments and address permissions but performs no external calls or code-existence checks. A constructor argument is a real launch-resolved address, never a guessed address. Owner authority cannot be transferred or renounced; losing its key loses the ability to update conversion settings. The recipient remains fixed even if an incorrect owner were supplied, so the deployer must verify `owner()` before launch.

The launch parameters provided with this assignment are Ethereum chain 1; pair **FWA at 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845** (18 decimals); fee **12500**; tick spacing **60**. The factory derives the opening price from its 2,000,000 FWA opening market-cap policy and token address ordering. The hook deliberately does not enforce the reference's one-to-one placeholder price; it accepts the factory's valid initialization price. Supply allocation (10% distributor, 88% pool, 2% launch payer/treasury) is entirely the factory's responsibility. Neither contract reserves or redirects any launch allocation.

Deploy DCA first, then mine the hook's CREATE2 salt against its exact creation bytecode and constructor arguments. Required low 14 address bits are **0x20cc (8396)**: beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta and afterSwapReturnDelta. All other permissions are false. Changing compiler settings, constructor arguments, bytecode or CREATE2 deployer changes the address; re-mine after any change.

`MineHook.run(create2Deployer, manager, token, factory, owner, startSalt, attempts)` returns `(salt, predicted, initCodeHash)`. Invoke with `forge script script/MineHook.s.sol --sig 'run(address,address,address,address,address,uint256,uint256)'` followed by the seven actual arguments, without `--broadcast`. Use up to 1,000,000 attempts per search and continue with a higher `startSalt` if needed. The CREATE2 deployer is the contract executing CREATE2; it may differ from the factory argument that initializes the pool. Confirm the candidate is unoccupied on the launch chain. `Deployment.t.sol` exercises this function, actual CREATE2 deployment and pool initialization directly with explicit parameters.

The factory must deploy the hook and initialize its pool atomically. `beforeInitialize` accepts only that factory, the launch token/FWA pair, fee 12500, spacing 60, and this hook; it returns the correct selector. A callback is required before initialization, so initialization before the hook has code cannot silently succeed. Subsequent attempts to initialize this hook for another pool are refused.

## After launch

**Trading works from the launch block.** Until the owner calls `setConversionPool(key, priceMoveBps, sqrtPriceCeilingX96)`, every swap is still charged its 5% and the FWA fee accumulates as ERC-6909 claims owned by the hook (`conversionConfigured()` is false, `ConversionSkipped` is emitted). Nothing is sold and no ETH is paid until a market is configured; the backlog then converts over later swaps. No real ETH/FWA market key or acceptable sale-price limit was supplied, so there is deliberately no invented default. Sales begin in the block after configuration.

Obtain the exact native ETH/FWA `PoolKey` (currencies, fee, tick spacing, hook) from the pool's verified v4 `Initialize` event and the launch chain's PoolManager records. Verify it is initialized, inspect its hooks, and check available liquidity and FWA's actual transfer restrictions. Choose `priceMoveBps` and an absolute price ceiling using an independently checked market price and the creator's execution tolerance; do not copy test values or blindly track a manipulated spot price. The owner can call the same setter again to replace the pool and/or limits; it emits `ConversionConfigured` and preserves accumulated claims.

Monitor `FeeCharged`, `FeeConverted`, `ConversionSkipped`, `EthPaid`, `EthDeferred`, `PairPaid`, the conversion pool's liquidity/price, the anchor (`anchorSqrtPriceX96`), and manager claim balances for this hook (id `uint160(FWA)` and native id `0`). A backlog that keeps growing means the route is unusable, the ceiling is below spot, or the market moves more than `maxPriceMoveBps` per block: refresh price limits, repoint the market, or as a last resort call owner-only `redeemPair()` to take the FWA to the recipient. Call permissionless `redeemEth()` for pending native claims after the manager is funded. No keeper can redirect funds, set the fee, or sell FWA claims outside a launch swap; the owner can halt conversion (not trading) by pointing at an unusable market. Native ETH sent directly to the hook is not part of the fee mechanism and has no rescue path.

## Assumptions and review boundary

“Every swap” refers to the DCA/FWA pool attached to this hook. ERC-20 transfers, liquidity changes, donations and independently created pools are not taxed. The owner is trusted to choose a sound conversion market and limits; it can impair fee conversion, but not trading, by choosing an unusable route.

**FWA transfer restrictions.** The real FWA token on Ethereum (`FWAToken`, hook `FWATokenHook` at 0x2c67eba8a50af0db5fba55f725247a75cbda6444) allows a transfer only when it is a mint/burn, one side is an FWA distributor, one side is FWA's owner, or one side is the v4 PoolManager and a transient allowance that only FWA's own hook grants, for its own ETH/FWA pool, covers the amount. The DCA/FWA launch pool is hooked by this contract, so that allowance is never granted for it: an ordinary router (including the Universal Router through Permit2) cannot pay FWA into the manager for a buy, and the manager cannot pay FWA out to it on a sell. **Trading the launch pool therefore requires a router or front-end that is an FWA distributor, or one that keeps the FWA leg as ERC-6909 claims** (buy FWA claims on FWA's pool, spend them on the launch pool in the same unlock, take sell proceeds as claims). This hook's own fee path is unaffected: it holds FWA only as claims and sells it on FWA's canonical pool, whose hook permits sells. The launch operator must obtain evidence of that router arrangement before launch; this repository cannot change FWA. The test fixture models the real guard (`test/mocks/MockERC20.sol`): the test contract is FWA's exempt owner, the test router is a distributor, and `test/ConversionBounds.t.sol` shows a non-distributor router failing both directions. External market hooks/fees and FWA's production behavior remain deployment dependencies. Rebasing or fee-on-transfer substitutes are unsupported. Test-specific addresses and local market parameters are never production settings.

Local tests use the real vendored PoolManager, including a manager initially funded with tokens only and a FWA mock that implements the real transfer guard (so any withdrawal to the hook, or any trade by a non-distributor router, fails). They prove local accounting properties, not production market liquidity or compatibility. See [docs/SECURITY.md](docs/SECURITY.md) and [docs/VALIDATION.md](docs/VALIDATION.md). Before release, the launch operator must rehearse against recent Ethereum state, verify the supplied manager/factory/market and recipient, and obtain the independent adversarial review. No transaction was broadcast and no production deployment, fork rehearsal, external audit, Slither or Mythril run is claimed.
