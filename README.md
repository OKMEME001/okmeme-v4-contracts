# OK.MEME V4 Contracts

Public, reproducible Solidity source for the Uniswap v4 hook trust path used by OK.MEME on X Layer.

This repository intentionally contains only the on-chain contracts, their direct protocol dependencies, and focused behavioral tests. The private product repository, frontend, backend, operator tooling, credentials, and live-fund scripts are not included.

## Status

The production X Layer stack was deployed on chain ID `196` from this source snapshot and read back on-chain. The production hook is `0xd5EbD05d63fDEb7ef3f91ddC387121623b51a8cc`.

See [`deployments/xlayer-mainnet.json`](deployments/xlayer-mainnet.json) for the component addresses, runtime code hashes, deployment transactions, and a live review pool using the production hook. Local test fixtures do not define production addresses.

## Hook behavior

`OkMemeTaxHook` is a shared, non-proxy Uniswap v4 hook for graduated OK.MEME pools:

- exact-input swaps only; exact-output swaps are explicitly rejected;
- payment-currency fees are accounted separately for marketing, holder dividends, and bounded liquidity reflow;
- an optional burn leg is charged in the launched token;
- `beforeSwapReturnDelta` and `afterSwapReturnDelta` implement the swap accounting;
- standard third-party swaps support empty `hookData`;
- a versioned four-byte marker is optional and only commits sufficient gas for the first-party post-sell settlement/reflow path;
- pool registration is restricted to the one-time configured graduation venue;
- liquidity reflow is bounded by per-token budget, tick movement, and cooldown rules.

See [Router compatibility](docs/ROUTER_COMPATIBILITY.md) and [Security model](docs/SECURITY_MODEL.md) for the exact boundaries.

## Reproduce

Requires Node.js 20+.

```bash
npm ci
npm run compile
npm run test:hook
```

Compiler settings are fixed in `hardhat.config.ts`: Solidity `0.8.26`, optimizer `10` runs, `viaIR`, Cancun EVM target.

## Included scope

- `contracts/core/tax`: hook and settlement accounting
- `contracts/core/dex`: graduation venue and permanently controlled position locker
- `contracts/core/token`: launched-token accounting
- `contracts/core/launchpad`: pool registration and per-token economic snapshots
- `contracts/shared/dividend`: holder-dividend accounting
- `test`: focused hook, graduation, reflow, access-control, and dividend tests

## Excluded scope

The web application, indexer, deployment credentials, private operational procedures, atomic launch console, and internal test reports are deliberately outside this repository.

## Security

See [SECURITY.md](SECURITY.md). No third-party audit is claimed until a report covering the exact production commit is published here.
