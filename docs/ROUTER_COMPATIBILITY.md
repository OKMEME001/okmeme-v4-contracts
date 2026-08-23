# Router compatibility

## Standard route

The hook accepts ordinary Uniswap v4 exact-input swaps with empty `hookData`. Tax collection is reflected in the return deltas, so quotes and settlement observe the user's actual input/output accounting.

The included tests cover native-payment and ERC20-payment pools, both swap directions, zero-tax pools, exempt system senders, and Universal Router-compatible pool semantics.

## Optional first-party marker

`POST_SELL_HOOK_DATA = bytes4(keccak256("OK_MEME_POST_SELL_V1"))` is an optional execution-policy marker. It does not authenticate the caller and is not required to quote or execute a swap.

When present on a sell, the hook requires enough remaining gas for the bounded settlement and liquidity-reflow attempts. This prevents a first-party transaction from being estimated on a cheap state and mined after work becomes ready without the promised budget. Empty-data third-party sells keep best-effort behavior.

## Explicit limitation

Exact-output swaps are rejected. All supported product and compatibility paths use exact input.

## Routing allowlist

Because the hook uses return-delta permission flags, its production address must be reviewed for the Uniswap routing allowlist. A production address is not published until deployment and on-chain verification are complete.
