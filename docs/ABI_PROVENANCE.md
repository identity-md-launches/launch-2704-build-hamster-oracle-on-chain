# SqueekCore ABI and chain observations

Retrieved and checked on 2026-10-30. The requester-specified proxy is used even
though current public developer documentation advertises another deployment.
No alternative proxy from documentation was substituted.

## Sources

- Requested proxy:
  https://eth-sepolia.blockscout.com/api/v2/smart-contracts/0x980b4424c007caf7a1f3670b48c8eaef7ebc3d44
- Implementation identified through the proxy, and checked in its EIP-1967 slot:
  https://eth-sepolia.blockscout.com/api/v2/smart-contracts/0x284747c4664af2203e7a90a2ee76f22b6b5e6889
- Human-readable explorer:
  https://eth-sepolia.blockscout.com/address/0x284747c4664af2203e7a90a2ee76f22b6b5e6889?tab=contract
- Upstream semantic cross-check:
  https://docs.squeekchain.com/developers/core/

Blockscout reports `name: SqueekCore`, `is_verified: true`,
`is_verified_via_eth_bytecode_db: true`, `is_partially_verified: true`,
`is_fully_verified: false`, and `verified_at: 2026-10-25T16:23:52.457421Z`.
The reported compiler is `0.8.36+commit.8a079791`. This is the **external**
implementation's compiler, not this project's compiler. Etherscan's proxy page
identified the implementation but labeled it unverified there; the verified ABI
and source were obtained from Blockscout. This is an explorer partial-match
verification, not a claim of independent source recompilation or full metadata
verification by this assignment.

The full ABI returned by Blockscout is saved as `abi/SqueekCore.json`, serialized
as indented JSON plus a trailing newline. Its SHA-256 is:

```text
46fd8234cc344ecb5b40f0c56afa63b7c7dbfc36fbf0c77972e61111b0c117a4
```

The read subset in `src/interfaces/ISqueekCore.sol` retains exact tuple field
order and integer widths for `state()`, `configuration()` and
`roundPage(uint64,uint64,uint256)`. In particular, there is no separate
`settledThroughRound()` method and no direct `rounds(roundId)` work getter in
this ABI. The frontier is `state().settledThroughRound`.

## Pinned chain observations

| Item | Observed value |
| --- | --- |
| Chain | Sepolia, 11155111 |
| Proxy | `0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44` |
| Implementation | `0x284747C4664AF2203E7A90a2Ee76f22b6B5e6889` |
| Implementation version | 3 |
| Implementation runtime keccak256 | `0xd8f2fb3c7dcf63e6dc0378ce5f85ceea52a876ae1f0cd66ac8631c3103371f8a` |
| Prediction block | 12020000 |
| Prediction block hash | `0x3c50f17dd1d99aa0c480ad77a9e004c7b43aad77d3456349c26edba82eb40a22` |
| Prediction timestamp / current round / frontier | 1793282820 / 434 / 433 |
| Recorded block | 12025393 |
| Recorded block hash | `0x8886f2c1572d385e84abb1c7830f083b66179314fff4781f643d980489f49dd3` |
| Recorded timestamp / frontier | 1793347872 / 542 |
| Cumulative work at recorded block | 45957 |
| Genesis / duration / maximum work | 1793022600 / 600 / 10000 |

The implementation slot checked in the fork is
`0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`.

Selected work values at block 12025393:

| Round | Work | Interpretation with threshold 100 |
| --- | --- | --- |
| 44 | 0 | NAP, implicitly certified |
| 45 | 170 | SPRINT |
| 46 | 694 | SPRINT |
| 54 | 0 | NAP, implicitly certified |
| 57 | 65 | JOG |
| 501 | 554 | SPRINT |
| 502 | 336 | SPRINT |
| 503 | 0 | NAP, implicitly certified |
| 507 | 0 | NAP, implicitly certified |

`roundPage(44, 46, 1)` stops at certified round 45 because its one-record budget
cannot include round 46. The game instead requests exactly one round per page
and rejects an incomplete certified endpoint. Active checkpoints contain
**cumulative work**, so using a checkpoint field directly as round work would
misclassify results. The tests explicitly exercise this distinction.

PublicNode returned pruned/inconsistently available historical account state for
the rolling fork during validation. The archival Tenderly public endpoint
completed the suite; it is the fork profile's default. Historical data access is
an operational RPC dependency, and can be overridden with `--fork-url` without
changing tests or using environment-variable cheatcodes. An RPC outage fails the
opt-in suite, rather than turning it into a passing/skipped test.

