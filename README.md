# Route contract audit candidate

Standalone, private-by-default audit handoff for Route on Robinhood Chain (chain ID 4663). **Unaudited. Scope is provisional until agreed with the owner and auditor.** This repository is an exact source snapshot, including local work, with new audit documentation and a minimal reproducible dependency lock.

## Start here

1. Read [scope and status](audit/SCOPE.md), [architecture and trust boundaries](audit/ARCHITECTURE.md), and [known issues](audit/KNOWN_ISSUES.md).
2. Install Node.js 22+ (26 validated), npm, and Foundry v1.5.1. Solidity is pinned to 0.8.30; EVM target Cancun; optimizer 200 runs; via IR.
3. Run `npm ci --ignore-scripts`, `npm run verify:snapshot`, and `npm test`.
4. Agree the reviewed commit and file list before the audit starts. An audit of this package does not cover the whole application.

The default tests run locally without a wallet, signing key, funded account or RPC. Files named `*Fork*` are excluded because they require historical RPC state or explicit environment values. They remain available for optional integration work.

Original source paths and bytes are preserved, including historical comments. Reformatting a verified Solidity file can change its metadata and verification output. Current scope/deployment interpretation lives in the audit documentation, rather than silently rewriting historical source.

## Layout

- `contracts/`: settlement, supporting historical source and adapters.
- `contracts/experimental/`: optional order, flywheel and research modules; path name alone does not establish deployed status.
- `contracts/test/`: local tests plus optional fork harnesses.
- `audit/`: scope, trust model, exact source hashes and readiness results.
- `deployments/` and `lib/route/fee-free-deployment.json`: selected public deployment evidence.

No original Git history, operational secrets, signing utilities, deployment scripts, private research conversations or production database files are included. OpenZeppelin Contracts 5.6.1 is locked to the original npm integrity value. This package does not deploy anything or alter active approval targets.
