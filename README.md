# Democratizing Collectable Acquisitions (DCA)

This Foundry project implements a fixed-supply DCA token and a Uniswap v4 hook that charges **5% of the gross FWA side of each swap in its launch pool** for **0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d**. The hook sells collected FWA for native ETH within the same swap and pays that fixed recipient. Price-limited FWA and unavailable ETH payouts remain PoolManager ERC-6909 claims; they are never silently discarded.

## Contracts and build

- `src/DCAToken.sol`: standard OpenZeppelin ERC-20; name `Democratizing Collectable Acquisitions`, symbol `DCA`, 18 decimals, exactly **1,000,000,000 tokens / 10^27 minor units**, minted once to its deployer (the launch factory). No constructor arguments, additional minting, owner, transfer tax, pause, blacklist, or upgrade mechanism.
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

The hook uses positive specified deltas in `beforeSwap` only when FWA is the specified currency; otherwise it returns the FWA fee as an unspecified delta in `afterSwap`. It never charges DCA, substitutes for the full AMM swap, or accepts a caller-selected fee/recipient in hook data. Both token orderings work.

**Partial fills:** a buy with exact FWA input or a sell with exact FWA output must fill the adjusted FWA amount completely. Otherwise the entire transaction reverts with `PartialFillNotSupported`. v4 cannot refund an already specified fee using the unspecified-only after-swap delta. DCA-specified partial fills charge only the FWA actually exchanged. Routers must still enforce user minimum outputs, maximum inputs, deadlines and exact-output fulfillment. Successful swaps must fit the v4 signed 128-bit delta range, including any gross-up.

## Conversion and payout

The owner selects an **already initialized native-ETH/FWA pool on the same manager**. Native ETH is v4 currency address zero; this is the protocol's native-currency representation, not a placeholder address. WETH is not interchangeable with it. The key must have native ETH as currency0 and the specified FWA token as currency1. The conversion market may have its own hook and must accept swaps with empty hook data. Its implementation and liquidity must be reviewed by the owner.

Each `afterSwap` combines the new fee with existing FWA claims, burns those claims, and swaps FWA exact-input (`zeroForOne = false`). It never calls `take(FWA, hook, ...)` or requires a transfer from FWA to the hook. Unspent FWA is minted back as ERC-6909 claims. Large accumulated balances are processed in bounded chunks of at most `2^127 - 1` minor units per swap.

The conversion's `sqrtPriceLimitX96` is the smaller of:

1. current square-root price multiplied by `sqrt(1 + maxPriceMoveBps / 10000)`; and
2. the owner's absolute `maxConversionSqrtPriceX96` ceiling.

The relative factor uses 1e9 precision and rounds down. `maxPriceMoveBps` is between 1 and 1000, inclusive. Price here means **FWA per ETH**, because ETH is currency0: selling FWA raises that price. A higher ceiling permits a worse FWA sale price. The absolute bound provides a minimum acceptable market price for FWA even when spot was moved before the transaction. The relative bound alone is not a fair-value oracle or complete MEV protection. Conversion LP/hook fees are additional to these price bounds.

If spot is already at/above the ceiling, or liquidity is exhausted within the bound, FWA remains as claims and is retried alongside the next swap's fee. There is no separate conversion transaction or token withdrawal function. Without another trade, those unsold claims remain pending. A broken/reverting conversion market reverts the launch swap atomically until the owner repairs the configuration.

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

**The owner must call `setConversionPool(key, priceMoveBps, sqrtPriceCeilingX96)` before trading.** Until then, swaps clearly revert with `ConversionNotConfigured`. Pool initialization and liquidity deposits do not require conversion configuration. No real ETH/FWA market key or acceptable sale-price limit was supplied, so there is deliberately no invented default or constructor-only dead end.

Obtain the exact native ETH/FWA `PoolKey` (currencies, fee, tick spacing, hook) from the pool's verified v4 `Initialize` event and the launch chain's PoolManager records. Verify it is initialized, inspect its hooks, and check available liquidity and FWA's actual transfer restrictions. Choose `priceMoveBps` and an absolute price ceiling using an independently checked market price and the creator's execution tolerance; do not copy test values or blindly track a manipulated spot price. The owner can call the same setter again to replace the pool and/or limits; it emits `ConversionConfigured` and preserves accumulated claims.

Monitor `FeeCharged`, `FeeConverted`, `EthPaid`, `EthDeferred`, the conversion pool's liquidity/price, and manager claim balances for this hook (id `uint160(FWA)` and native id `0`). Refresh price limits as needed, repair an unusable conversion route, and call permissionless `redeemEth()` for pending native claims after the manager is funded. No keeper can redirect funds, set the fee, or sell FWA claims outside a launch swap. Native ETH sent directly to the hook is not part of the fee mechanism and has no rescue path.

## Assumptions and review boundary

“Every swap” refers to the DCA/FWA pool attached to this hook. ERC-20 transfers, liquidity changes, donations and independently created pools are not taxed. The owner is trusted to choose a sound conversion market and limits; it can impair fee conversion or trading by choosing an unusable route. External market hooks/fees and FWA's production behavior remain deployment dependencies. Rebasing or fee-on-transfer substitutes are unsupported. Test-specific addresses and local market parameters are never production settings.

Local tests use the real vendored PoolManager, including a manager initially funded with tokens only and a FWA mock that refuses transfers to the hook. They prove local accounting properties, not production market liquidity or compatibility. See [docs/SECURITY.md](docs/SECURITY.md) and [docs/VALIDATION.md](docs/VALIDATION.md). Before release, the launch operator must rehearse against recent Ethereum state, verify the supplied manager/factory/market and recipient, and obtain the independent adversarial review. No transaction was broadcast and no production deployment, fork rehearsal, external audit, Slither or Mythril run is claimed.
