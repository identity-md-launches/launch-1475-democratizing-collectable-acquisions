# Local validation — 2026-10-12

These results are the implementer's local checks, not independent admission evidence or a security audit.

Toolchain: Foundry 1.8.3 (`cae51ad458f6abb64852b7709eb784352429825d`), Solidity 0.8.26 (`0.8.26+commit.8a97fa7a`), Cancun, optimizer enabled with 200 runs, metadata bytecode hash disabled. The compiler version is pinned by version in the root configuration; no compiler binary is included.

| Check | Result |
| --- | --- |
| `forge build` | Pass. Foundry lint diagnostics about guarded callbacks/events and the unused empty unlock response were reviewed in SECURITY.md. |
| `forge test` | **58 reported passes**, zero failures, zero skips, across seven suites (plus the reviewer's proof `Proof_dfa2af182d0a.t.sol`, which passes when copied under `test/scratch/`). |
| `forge fmt --check` | Pass, no formatting diff. |
| Clean offline copy, `forge build --offline` | Pass with only src/test/script/lib and root configuration, no read inputs, scratch files, existing cache or artifacts. |
| Clean-copy `forge test --offline` | **58 reported passes**, zero failures, zero skips, with an empty environment apart from PATH. |
| Production bytecode artifacts | No creation/runtime library link references. DCAHook: **12,864 runtime bytes**; DCAToken: **1,723 runtime bytes**. Both below 24,576 bytes. |
| Runtime opcode tests | Neither launch contract contains DELEGATECALL, SELFDESTRUCT or CALLCODE outside PUSH data. |
| Dependency tree inspection | Ordinary files only; no symlinks, submodules, environment files, node_modules or Git/GitHub directories were added under source/dependency paths. |

The default fuzz campaign runs 256 cases for swap fee/conservation and 256 for token transfer conservation. The stateful suite checks three invariants together over 64 runs of 32 calls (2,048 handler calls, zero unexpected reverts). Foundry reports the grouped invariant campaign as one of its 58 passing entries. Its random actions include trades in either direction and exactness, temporary native shortages, recipient failures, price-limit changes and ETH claim redemption.

Tests deploy an actual PoolManager and a mined, constructor-validated hook. The CREATE2 utility is tested by deploying its returned address and initializing through the designated factory. No test reads or sets environment variables, uses RPC/fork state, enables FFI, or grants filesystem access. The clean offline copy excludes `.imd/reads` and `test/scratch`, confirming no build or test depends on inputs removed before submission.

The protected input tests were read and their applicable behavior is covered by local tests, but their separate environment-driven verifier harness was not executed here. Nothing in this report substitutes for that verifier, the production fork rehearsal, or independent review. No production transaction, mainnet fork, Slither/Mythril analysis or external audit was performed.
