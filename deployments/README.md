# Deployments

This directory contains the sanitized, read-back X Layer production manifest. It records:

- chain ID and deployment block;
- production hook and directly trusted contract addresses;
- deployment transaction hashes and runtime code hashes;
- the pinned source commit and compiler settings;
- one reviewable example pool ID using the production hook;
- the verified hook-source link. No third-party audit is claimed.

No private key, RPC credential, wallet balance, internal operator address, or live-fund script belongs in this directory. The repository is the reproducible source reference; the production hook source is also verified on the X Layer explorer.
