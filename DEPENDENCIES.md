# Vendored dependencies

All dependencies are checked into `lib/` as ordinary source files. No submodules or package installation is required. Upstream source files are unchanged; only the indicated directories and license files are included. Foundry remappings select these local copies.

| Directory | Upstream revision | Included paths | License |
| --- | --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core, 46c6834698c48bc4a463a86d8420f4eb1d7f3b75](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `src/`, `licenses/` | Per-file MIT / BUSL-1.1; complete license texts in `licenses/` |
| `lib/forge-std` | [foundry-rs/forge-std v1.9.7, 77041d2ce690e692d6e03cc812b57d1ddaa4d505](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | `src/`, license files | MIT / Apache-2.0 |
| `lib/openzeppelin-contracts` | [OpenZeppelin/openzeppelin-contracts v5.4.0, c64a1edb67b6e3f4a15cca8909c9482ad33a02b0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/c64a1edb67b6e3f4a15cca8909c9482ad33a02b0) | `contracts/`, `LICENSE` | MIT |
| `lib/solmate` | [transmissions11/solmate, 89365b880c4f3c786bdd453d4b8e8fe410344a69](https://github.com/transmissions11/solmate/tree/89365b880c4f3c786bdd453d4b8e8fe410344a69) | `src/`, `LICENSE` | See per-file SPDX identifiers and included license |

The production token uses OpenZeppelin ERC20. The hook uses OpenZeppelin Math, SafeCast and ReentrancyGuard plus v4 interfaces, types and internal libraries. PoolManager and its Solmate ownership dependency are instantiated by the tests. No external Solidity library linking is required for DCAToken or DCAHook.
