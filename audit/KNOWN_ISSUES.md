# Known issues and handoff limits

1. No independent security audit has been completed. Passing tests do not establish absence of exploitable bugs.
2. Historical NatSpec in RoutePoolExecutor, RouteLeanMetaExecutor and RouteFeeFlywheel72h still says experimental/not deployed. It is preserved byte-for-byte for source provenance. Consult SCOPE.md and runtime evidence rather than using those comments as current deployment status.
3. The original application README names RouteExecutor for direct settlement, while the active registry selects RoutePoolExecutor. This candidate's scope table corrects the handoff description without rewriting compiled Solidity metadata.
4. The source working tree contains uncommitted work. SNAPSHOT.json records exact file hashes; the source commit alone is not this snapshot.
5. Local unit tests use mocks and test harnesses, including injected factories and simplified pools. Historical fork tests are excluded from the default command. Real state, third-party hooks and production execution remain separate checks.
6. Optional order/USD modules have mixed preview and local status. Their feeds, deployment configuration and worker integration must be reviewed before release; this audit package does not authorize deployment.
7. Broader application lint is failing and the frontend/API/workers are excluded from this provisional contract package. Full-product audit readiness requires resolving and documenting those findings rather than presenting this package as the whole system.
8. The original history secret scan reports generic-pattern matches, many in token-address and benchmark fields. Original-history findings have not all been classified; original history is omitted. The exported candidate's four default-rule matches were public EVM addresses. Its narrow scanner allowlist accepts only exactly 20-byte EVM addresses; no file, directory, private-key format or general API-key rule is excluded. The candidate scan then passed.
9. Source license identifiers are preserved. Third-party OpenZeppelin code remains under its upstream license. Repository ownership and the auditor's final file list remain to be confirmed.
