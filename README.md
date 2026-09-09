# Route contract audit candidate

Standalone, private-by-default audit handoff for Route on Robinhood Chain (chain ID 4663). **Unaudited. Scope is provisional until agreed with the owner and auditor.** This repository contains formatted contract source, audit documentation and a minimal reproducible dependency lock.

Repository: [micahalp/route-contract-audit](https://github.com/micahalp/route-contract-audit). Start with the [proposed auditor brief](audit/AUDITOR_BRIEF.md). The recommended initial review is live swap settlement and the flywheel; off-chain integrations and order systems are separately scoped. Check [GitHub Actions](https://github.com/micahalp/route-contract-audit/actions) for validation of the exact commit being reviewed.

## Start here

1. Read [scope and status](audit/SCOPE.md), [architecture and trust boundaries](audit/ARCHITECTURE.md), and [known issues](audit/KNOWN_ISSUES.md).
2. Install Node.js 22+ (26 validated), npm, and Foundry v1.5.1. Solidity is pinned to 0.8.30; EVM target Cancun; optimizer 200 runs; via IR.
3. Run `npm ci --ignore-scripts`, `npm run verify:snapshot`, and `npm test`.
4. Agree the reviewed commit and file list before the audit starts. An audit of this package does not cover the whole application.

The default tests run locally without a wallet, signing key, funded account or RPC. Files named `*Fork*` are excluded because they require historical RPC state or explicit environment values. They remain available for optional integration work.

The exact source used for the original runtime comparison remains at commit [`1bc96e1`](https://github.com/micahalp/route-contract-audit/tree/1bc96e1a1e1737195a84747cca262785b7757b73). Current source has expanded formatting and shorter comments. Solidity metadata changes with source bytes: use that original commit for exact deployed-source reproduction. `audit/ORIGINAL_SNAPSHOT.json` preserves its hashes, while `audit/SNAPSHOT.json` records the formatted files. `npm run verify:snapshot` verifies both versions; use a full Git clone. See [formatting validation](audit/FORMATTING.md) for the executable-bytecode comparison.

Run `npm run format` before committing, or `npm run format:check` to check without writing. CI enforces the shared Foundry formatting rules.

## Layout

- `contracts/`: settlement, supporting historical source and adapters.
- `contracts/experimental/`: optional order, flywheel and research modules; path name alone does not establish deployed status.
- `contracts/test/`: local tests plus optional fork harnesses.
- `audit/`: scope, trust model, exact source hashes and readiness results.
- `deployments/` and `lib/route/fee-free-deployment.json`: selected public deployment evidence.

No original Git history, operational secrets, signing utilities, deployment scripts, private research conversations or production database files are included. OpenZeppelin Contracts 5.6.1 is locked to the original npm integrity value. This package does not deploy anything or alter active approval targets.
