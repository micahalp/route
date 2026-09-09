# Validation

## Standalone contract candidate

- Fresh `npm ci --ignore-scripts`: passed; one dependency installed from the pinned lock. npm reported zero known vulnerabilities for this two-package contract workspace, not for the full app.
- `npm run verify:snapshot`: passed, 66 copied source/evidence files match SHA-256 values.
- `npm test`: 608 local Solidity tests passed, zero failures, fork files deliberately excluded. Fresh compilation used Foundry 1.5.1, Solidity 0.8.30, Cancun, optimizer 200, via IR. Raw output: `evidence/local-tests.txt`.
- Gitleaks 8.30.1 candidate scan: passed after classifying four public EVM-address matches. `.gitleaks.toml` permits exactly 20-byte public addresses only; 32-byte private keys and other credentials remain subject to default detection. Raw summary: `evidence/secret-scan.txt`.
- Deployment read: all four active swap executors plus RouteFeeFlywheel72h matched compiled runtime after masking compiler-declared immutable regions, with metadata included. All had code at one stable Robinhood Chain block. Raw result: `evidence/runtime-check.json`.

This runtime comparison does not validate immutable values, storage state, constructor side effects, adapters, pool/router code, feed behavior or operator permissions. Those remain explicit audit/deployment checks. No transaction was signed or sent.

## Broader source workspace

305 application unit tests passed. `npm run lint:route` failed with 452 diagnostics, including 436 no-floating-promises diagnostics, predominantly in JavaScript tests. Other issues include unused values, a synchronous script warning elevated to error, a React compiler diagnostic and an unbound-method check. They are outside this provisional contract-only package and must be resolved or reviewed before claiming full-product readiness. No broad linter rule was disabled to hide them.

The original Git history scan reported 1,368 generic-pattern findings across 244 commits; many are token fields and benchmark records, but the full set has not been classified. Original history is not included in this fresh snapshot. A clean exported package does not certify the old repository history.

## Remaining handoff decisions

The owner confirmed the private GitHub repository under micahalp. Agree the final auditor scope before review begins. CI is configured with pinned action revisions and a pinned Foundry release; consult [the Actions runs](https://github.com/micahalp/route-contract-audit/actions) for the exact reviewed commit. Optional historical fork tests and live third-party integrations were not rerun. Unit tests and preparation checks are not an independent security audit.
