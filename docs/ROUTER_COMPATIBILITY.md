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

Because the hook uses return-delta permission flags, its production address requires a separate Uniswap Labs routing review. The deployed, [explorer-verified production hook](https://web3.okx.com/zh-hans/explorer/x-layer/evm/address/0xd5EbD05d63fDEb7ef3f91ddC387121623b51a8cc) is `0xd5EbD05d63fDEb7ef3f91ddC387121623b51a8cc`; its example pool ID and code hash are in the [deployment manifest](../deployments/xlayer-mainnet.json). An earlier approval for `0xabc55c84a854E0E9A65ABd29F40F49B280b440cC` covered a different, retired test deployment and does not approve this hook. Routing review is not a security audit or endorsement.
