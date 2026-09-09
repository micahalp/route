# Scope and deployment status

## Proposed primary audit

Review RoutePoolExecutor, RouteMetaExecutor, RouteLeanMetaExecutor, their adapters and interfaces. The explicit candidate file list is in SCOPE.json. Historical sources are retained because tests import their shared fixtures; inclusion is not a claim that every contract is active.

The active zero-fee registry records:

| Role | Contract | Address |
| --- | --- | --- |
| Direct settlement | RoutePoolExecutor | 0x22c1Bba36Ba220964D029Eb4B1eF7c6ed167E32E |
| Kyber guard | RouteMetaExecutor | 0xd8f7171886F8476ECE2E51CFFE8C4c637815a815 |
| Kyber direct-recipient guard | RouteLeanMetaExecutor | 0x70656A2B4A401DeF17c55687c19C536C0FAD4DB1 |
| 0x guard | RouteMetaExecutor | 0x201a935146E1283F35bB54b8Fe7a4C584265B7E8 |

This table is derived from local configuration and deployment records. A fresh deployed-runtime comparison passed for all four executors, including compiler metadata and excluding constructor-set immutable regions. Immutable values, storage and third-party dependencies require separate checks; see VALIDATION.md. Historical manifests may say deployed-not-activated because they record status at deployment time.

Route charges zero settlement fee. Historical RouteFeeExecutor/RouteExecutionHub deployments must not be reactivated by changing frontend configuration. Distinct active spenders require explicit wallet review.

## Optional scope requiring agreement

- RouteFeeFlywheel72h: local worker configuration identifies 0xAdA939f2f1482a13e3c0c612bCB14f2615221E9d. Review separately from swap-fee policy: this claims external creator fees, uses 65% for a purchase and sends purchased tokens and the remaining native amount to a fixed Safe.
- Order vaults, settlement helpers and USD feeds: mixed preview/local status. Do not infer release readiness from successful unit tests. USD terms and feed integration have outstanding deployment and operational gates.
- Quote API, frontend and signing workers are outside this contract-only candidate. If the auditor is assessing the complete product, expand the scope and include those components before freezing the final commit.

No original repository history is copied. SNAPSHOT.json records the source commit and hashes every copied file, including uncommitted local files. The new audit repository commit will be the review reference once the destination is chosen.
