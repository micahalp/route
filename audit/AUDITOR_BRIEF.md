# Proposed auditor brief

We would like an audit proposal for Route on Robinhood Chain (4663). The immediate priority is the contracts already handling live swap and treasury funds.

## Initial contract scope

- RoutePoolExecutor and its adapters/interfaces: route validation, pool identity, callbacks, native wrapping, exact input/output accounting, recipient, minimum output, expiry, donation isolation and approvals.
- RouteMetaExecutor and RouteLeanMetaExecutor: constrained Kyber/0x execution, opaque calldata boundaries, fixed targets/selectors and balance/allowance guarantees.
- RouteFeeFlywheel72h: treasury/operator permissions, 65/35 allocation, expiring policy, floor and budget enforcement, pause/recovery and external fee-recipient handover.

The candidate initial scope contains 11 Route source files, excluding OpenZeppelin. Formatting expanded previously compressed statements; physical line counts should be measured on the agreed review commit. The final scope and price should be agreed on exact files and commit. Supporting historical source and all tests are retained for reproducibility and are not automatically part of the paid scope.

## Please quote separately

1. A focused integration review of quote-to-transaction construction, upstream payload validation, wallet spender/minimum/recipient binding, and flywheel worker signing/journaling. These off-chain files are not yet in this contract-only candidate.
2. Order vaults, stop-loss/OCO logic, USD conversion and oracle/feed contracts, plus their keeper. These require a separate agreed release scope before broader deployment or acceptance of user deposits.
3. Third-party deployment/immutable checks and the extent of review of external routers, pools, tokens and feeds.

## Deliverables requested

An exact scope/commit, findings with severity and reproducible cases, remediation review, final report with clear exclusions, and permission terms for publishing the report. Please confirm supported chain/tooling requirements and whether runtime/constructor verification is included.

## Current readiness

The clean candidate installs one pinned OpenZeppelin dependency and passes 608 local Solidity tests. Source hashes are preserved. The four swap executors and flywheel match compiled deployed runtime with constructor-set regions excluded; immutable values and external dependencies need separate verification. This is audit preparation, not a completed independent audit. The broader application still has lint findings documented in VALIDATION.md.

No original Git history, production credentials, wallet keys or deployment utilities are included. The private repository is micahalp/route. The final auditor scope remains to be agreed.
