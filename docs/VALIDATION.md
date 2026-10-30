# Validation record

Builder-run checks on 2026-10-30, using Foundry 1.8.3 and pinned solc 0.8.26.
These checks are reproducible evidence, not independent review or authority to
deploy.

## Commands and outcomes

| Check | Outcome |
| --- | --- |
| `forge build` | Pass, solc 0.8.26 |
| `forge test -vv` with the assignment's fuzz seed | Pass: 31 reported tests, 0 failed, 0 skipped |
| `forge test --profile fork -vv` | Pass: 4 live archival fork tests, 0 failed, 0 skipped |
| `forge fmt --check` | Pass |
| Read-only `forge script script/Preflight.s.sol:Preflight --rpc-url https://sepolia.gateway.tenderly.co` | Pass against current Sepolia state; no broadcast |
| Compiled interface compared with vendored verified ABI | Exact match for all 3 functions, including tuple field names/order/types |
| Application deployed runtime size | 10,475 bytes, below 24,576-byte EIP-170 limit |
| Application external library link references | None |
| Raw CREATE2 constructor rehearsal | Pass on Sepolia-ID chain with no SqueekCore code |

The fixed fuzz seed is
`0xe2a1b90ca5dafcc24a60afd0ba176327e8bef6600ab7b5802b985b2bdbb72138`.
Each of 6 fuzz tests ran 512 cases. The stateful campaign ran 128 sequences and
16,384 handler calls with **0 reverts**, testing three invariant functions.
Foundry 1.8.3 reports that invariant campaign as one test in its aggregate count.

The successful read-only current-state preflight observed current round 546 and
certified frontier 544. Those are point-in-time observations, not expected
permanent values or deployment parameters.

Compiler/linter warnings concern timestamp comparisons used for round timing,
range-checked casts, and source reads/reverts inside the bounded scoring loop.
They are discussed in the review handoff; no claim of a warning-free static
analysis or independent audit is made.

## Test coverage

- Unit tests: empty-chain constructor, fixed Sepolia dependency, threshold
  bounds, round numbering, exact start/end boundaries, late/duplicate/invalid
  picks, counts, sparse zero rounds, delayed reporting, pause semantics, no
  value/privileged entry points, bounded checkpoints and paginated history.
- Scoring: wrong-pick and skipped-round resets, bonus cap with uncapped run
  length, reverse entry/settlement order, permissionless credit, and replay.
- Fuzzing (512 cases each): threshold/work classification, prediction cutoff,
  reference scoring under permutations, history pagination, malformed pages,
  and full-population leaderboard comparison.
- Stateful invariants: randomized predict/advance/report/settle/checkpoint
  sequences against an independent chronological model, including history,
  counts, pending queues, points, streaks and unique leaderboard membership.
- Adversarial integration: unavailable/mismatched/malformed oracle, page
  inconsistency, truncated ABI, rollback, static-context reentry attempt,
  cached result immutability, and runtime size/opcode checks.
- Live archival fork: exact ABI/configuration and source implementation,
  active and implicit-zero round work, pagination truncation, real historical
  prediction-to-settlement lifecycle, unknown-frontier refusal and preflight.

The fork suite uses only read operations on Sepolia. Test transactions and
deployment occur inside the local fork EVM; nothing is broadcast.
