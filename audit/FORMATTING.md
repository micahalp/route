# Source formatting

The September 9 cleanup expands compressed declarations, control-flow blocks and calls in all 61 Solidity files. Repeated comments were shortened and outdated deployment-status comments were corrected. Foundry formatting is configured in `foundry.toml` and checked in CI.

## Original source

Commit `1bc96e1a1e1737195a84747cca262785b7757b73` preserves the exact original audit snapshot. `ORIGINAL_SNAPSHOT.json` is copied unchanged from that commit. `SNAPSHOT.json` hashes the current formatted source; the verifier checks both current files and the original files retrieved from Git history.

Use the original commit to reproduce the earlier metadata-inclusive on-chain comparison. Formatting changes Solidity source hashes and compiler metadata, even when runtime instructions do not change. No deployment or on-chain configuration changed during this cleanup.

## Validation

- Foundry v1.5.1; Solidity 0.8.30; Cancun; optimizer 200; via IR. Compilation settings are unchanged.
- 608 local Solidity tests passed; fork tests excluded. Output: [formatting-tests.txt](evidence/formatting-tests.txt).
- All 104 non-test contract/interface/dependency artifacts have identical ABIs and identical compiled runtime after removing the trailing Solidity CBOR metadata. Of those, 27 have changed metadata. Interfaces and abstract contracts can have empty runtime. Results: [formatting-bytecode.json](evidence/formatting-bytecode.json).
- Snapshot verification checks 66 current files and 66 original files. `forge fmt --check` passes.

The bytecode check compares local compilations before and after formatting. It does not verify deployed immutable values, constructor side effects, current storage, dependencies at deployed addresses or economic safety. Earlier deployment evidence remains historical and is not replaced by this comparison.
