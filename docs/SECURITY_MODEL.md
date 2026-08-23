# Security model

## Trust boundaries

- The hook bytecode is not proxy-upgradeable.
- `venue` and `settler` coordinates are configured once.
- Only the configured venue can register a pool.
- The owner can transfer ownership and manage sender-level swap exemptions; these powers are explicit and observable on-chain.
- Per-token tax and operating values are snapshotted at creation and registered with the graduated pool.
- The settler holds separate marketing, dividend, and liquidity buckets per token.

## Swap behavior

- Exact-input direction and actual V4 deltas determine which asset is taxed.
- Payment-side taxes are never represented as token burns.
- The explicit burn leg is the only tax path that sends launched tokens to the burn address.
- External settlement and reflow attempts are gas-bounded and their failures are isolated from an otherwise valid best-effort sell.
- A first-party committed sell reverts early if it does not carry its declared post-sell gas budget.

## Liquidity reflow

- Each execution is capped by a per-token payment budget.
- Tick movement is bounded from the execution-time pool tick.
- A cooldown prevents composing many individually bounded reflows into one transaction window.
- Real token/payment deltas and PositionManager results are reconciled; unused assets remain in their corresponding reserve buckets.

## Known product limitation

The execution-time spot tick is the price reference for reflow protection. The protocol does not claim TWAP/oracle manipulation resistance.
