# Sherlock findings 11 and 12 — local remediation candidate

September 17, 2026. These are fixes for the deprecated audit snapshot, not a production release or auditor-approved resolution.

Audited source: `micahalp/route` commit `d9958f70d024955bfb1446ea4f62c403e4c1dabf`. Sherlock repository snapshot: `6d77f7504851a8e6e112c42edb9288f6853d9d30`, under `route/`. The audit repository is private and the source repository is public. This package has not been pushed, posted, or submitted. Account micahalp can read but cannot push or triage the Sherlock repository. Confirm the private remediation submission channel before publishing a PR.

## Findings and proposed responses

| Finding | Local conclusion | Suggested dashboard disposition |
| --- | --- | --- |
| [12: recipient inflows bypass minOut](https://github.com/sherlock-audit2/2026-09-route-fun-sep-10th-2026/issues/12) | Reproduced with an existing funded reward entitlement; zero genuine swap output can pass the old guard | Acknowledged / Will Fix; pending Sherlock review |
| [11: residual router ETH blocks WETH input](https://github.com/sherlock-audit2/2026-09-route-fun-sep-10th-2026/issues/11) | Reproduced against a model of Uniswap's native-first payment branch, both adapter and pool-executor fallback | Acknowledged / Will Fix; pending Sherlock review |

The tests reproduce the contract-level accounting flaws. They do not demonstrate a working malicious payload on a particular live aggregator or establish affected production funds. Deprecated source does not invalidate a finding within the agreed audit scope. Neither finding is marked resolved by this work.

## Changes

Finding 12: RouteLeanMetaExecutor now measures output at itself, checks minOut, then delivers to the final recipient. It preserves donated balances, exact input consumption, temporary approval revocation, recipient validation, deadline and reentrancy protection. ERC20 delivery verifies the actual recipient credit. Native recipients may forward funds. Existing ABI is unchanged, but upstream payloads MUST send output to the executor; old direct-recipient calldata is intentionally rejected. Order integration fixtures have been updated to demonstrate this migration.

Finding 11: V3Adapter checks residual native balance before executing WETH-input swaps. It calls the fixed router's refundETH, wraps only the refunded delta, and returns that WETH to the same router. This preserves customer input and pre-existing adapter donations, avoids unsolicited input refunds to an outer executor, and leaves the router's returned WETH publicly recoverable through standard sweepToken. Native receipt is restricted to the fixed router. This requires the pinned router's WETH9/refundETH/sweepToken semantics and a conventional WETH implementation; deployment compatibility is not proven by mocks. Uniswap reference: https://github.com/Uniswap/v3-periphery/blob/main/contracts/base/PeripheryPayments.sol .

RoutePoolExecutor's WETH router fallback routes through the adapter when residual ETH exists, so it cannot bypass normalization. Its direct pool-callback path is unchanged. Three out-of-scope historical executors (RouteFastExecutor, RouteRamsesExecutor, experimental/RouteOrvexExecutor) receive only Solidity payable-cast compatibility edits; their direct router branches are NOT remediated here. Do not describe those old executors as fixed.

Original audit manifests, deployment records and historical evidence are preserved. REMEDIATION-SNAPSHOT.json overlays explicit file hashes; verify-snapshot verifies both the audited revision and the new bytes. No app/API payload builders, active contracts, spender configurations, fee rates, workers or journals were modified.

## Verification

- `npm ci --ignore-scripts`: pinned OpenZeppelin 5.6.1 installed.
- Four security assertions fail on the pristine Sherlock snapshot: zero-output claim masking, partial-output claim masking, WETH adapter denial, and pool-fallback denial. See `evidence/sherlock-pristine-reproduction.txt` and its exact fixture `evidence/sherlock-pristine-reproduction-test.sol.txt`.
- `forge test --no-match-path '*Fork*' --summary`: **618 passed, zero failed** after fixes (608 historical tests, nine dedicated regression tests, one additional taxed-delivery test). Fuzz tests use 256 runs. Raw output: `evidence/sherlock-fixed-tests.txt`.
- `forge fmt --check` and `git diff --check`: pass.
- Initial baseline/fix logs are retained. The initial fixed suite exposed three order-fixture failures because they still sent output straight to the vault; updating their payload receivers resolved them without weakening assertions.
- No live fork tests, deployed runtime comparison, wallet signing, gas benchmark, or production exploitation claim. Sherlock fix review remains outstanding.

## Lessons and newer-source inventory

This is a static comparison of local source, not a live deployment inventory. API checkout inspected at `113d741c8503ca2e33964fe733cd90bee58ad4db`; builder at `9b19eca508b098155d5a23c32c03b4089534b364`; Premium checkout at `ffa69f0863997ec2d02529e01ec6bd933e8e867a`. Newer source is outside this audit's original scope.

| Source/path examined | Observation and follow-up |
| --- | --- |
| API contracts/RouteLeanMetaExecutor.sol; lib/route/hybrid/registry.ts; lib/route/orders/live-route.ts | Old recipient-delta source and recorded address 0x70656A2B4A401DeF17c55687c19C536C0FAD4DB1 remain referenced. Deprecation of the snapshot alone does not prove the contract is unreachable. Verify actual service call graphs and deployed bindings separately. |
| API contracts/experimental/RouteTieredFeeExecutor.sol | swapMeta sets the engine recipient to itself, and _finish measures its own output before paying fees/user. A payout owed to the final user is not included in that wrapper's output. This does not remove direct access to the old engine or prove every caller uses the wrapper. |
| API RouteIntegratedMetaFeeExecutor and RouteNordsternFeeExecutor | Measure settlement contract output before payment; recipient checks occur around their own transfer, not the entire upstream call. Do not flag these merely because beforeRecipient appears in source. |
| Builder RouteBuilderExecutor | Measures its own gross output around the allowed engine call, then checks net and pays recipient. Existing signature/engine trust requirements remain. |
| PremiumDirectExecutor | Final recipient delta is a transfer-delivery check. This bounded read is not a full Premium review. |
| DirectV3Adapter; RoutePoolExecutor direct callback branch | Direct pool callbacks do not use the upstream router's native-first payment branch. Callback authentication and exact spend still require their own coverage. |
| Historical router fast paths and Ramses/CL-like routers | Check actual upstream payment semantics and reachable fallback branches. The adapter fix must not be assumed to fix calls that bypass it. No equivalent live exploit established here. |

Core lessons: count swap proceeds in controlled settlement custody; distinguish delivery checks from untrusted-call accounting; test pre-existing entitlements rather than only donations made before a swap; fuzz external router balances; preserve all outer exact-input invariants when handling refunds; test optimized and fallback execution separately. Simulation and trusted quote builders do not replace onchain enforcement under the audited threat model.

## Submission steps

1. Mark both findings Acknowledged / Will Fix; dashboard changes have not been performed here.
2. Ask Sherlock where to submit private remediation, because the existing source repository is public.
3. Submit this exact candidate/PR through that channel and link it on both findings. Use the committed remediation revision as the fix-review hash, not the original audit SHA or an uncommitted working tree.
4. Obtain Sherlock review, address feedback, and only then resolve findings/finalize the report. Retain the original severity and limitations unless Sherlock changes them.
5. Any production follow-up needs a fresh reachable-path/runtime inventory and separately reviewed release. This package is not a deployment plan.
