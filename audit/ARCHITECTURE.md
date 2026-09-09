# Architecture and trust boundaries

## Swap settlement

An off-chain service discovers liquidity and constructs a candidate. The user reviews chain, spender, input, minimum output, recipient and expiry. The wallet approves the selected executor for the intended input and submits the swap. The contract must enforce the user's limits independently of the quote service.

RoutePoolExecutor uses an immutable adapter allowlist and fixed direct-pool paths. Canonical V3 callback payment is bound to verified factory/pool configuration, transient callback state and a bounded input amount. Fallback adapters must preserve the same accounting protections. Ramses and Uniswap router/factory bindings are external trust dependencies.

RouteMetaExecutor permits one fixed upstream target and selector, approves the caller's exact input, revokes the approval and measures received output. RouteLeanMetaExecutor instead measures output at the final recipient and requires donated executor balances to remain unchanged. Opaque upstream payloads are not equivalent to arbitrary target execution; review nested envelope behavior and how an upstream router's own privileges or upgrades affect assumptions.

## Properties to examine

- No amount, recipient, minimum output, expiry or spender substitution after approval.
- Exact input consumption; rejected partial fills and unsupported transfer behavior.
- Donation isolation and correct native/wrapped-native accounting.
- Callback authentication, reentrancy protection and clearing of transient callback state.
- Temporary approvals revoked, including unusual ERC-20 approve behavior.
- Recipient balance changes measured correctly, including malicious/reentrant recipients and tokens.
- Branch totals, hop constraints, integer rounding, direct pool fees and pool identity.
- Third-party revert behavior and upstream token/native balance manipulation.

## Optional flywheel

The fixed treasury sets a bounded policy and can pause, recover to itself or hand fee receipts to itself. The operator can execute within that policy; the deployer has no administrative role. Policies last at most 72 hours. The price floor is an owner-authorized limit, not a market oracle. Failure to claim, buy or deliver the remainder reverts the complete transaction. Inspect policy races, floor rounding, budget/sequence accounting and fixed-recipient recovery.

## Optional orders and feeds

Owners escrow assets and retain cancellation rights under each vault's state machine. Execution uses a configured swap adapter and enforces the order's limits. Different vault generations use different rate/USD semantics. Review trigger direction, stale feed rejection, decimals, settlement conversion, post-swap checks, OCO exclusivity and output delivery. Keeper reliability and off-chain stop observations are separate from on-chain enforcement.

## External assumptions

OpenZeppelin Contracts 5.6.1; chain support for the selected EVM and EIP-1153 where transient storage is used; external pool/router/factory correctness; supported token behavior; Safe authority for flywheel policy; oracle freshness/semantics for USD modules. A unit test suite does not validate deployed third-party implementations or operational key management.
