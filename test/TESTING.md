# Contributor test coverage

These additions test the accepted implementation without changing application
code, dependencies or Foundry configuration. The original offline suite remains.
No new packages, submodules, FFI or filesystem cheatcodes are required.

## Running

Use the default profile:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xe2a1b90ca5dafcc24a60afd0ba176327e8bef6600ab7b5802b985b2bdbb72138 forge test -vv
```

`HamsterOracleSepolia.t.sol` reads `SEPOLIA_RPC_URL` using `vm.envOr` and
forks **Sepolia block 12025524 only**. The value is passed unchanged, so an IPC
socket is also supported. Only an empty variable skips these five tests;
connection, ABI and assertion failures fail the suite. No test changes the
environment, rolls the fork to another block, or contains an RPC address.

The earlier rolling fork test under `test/fork/` has been replaced by this suite
in `test/`, which the default profile includes. The repository's existing
`fork` profile and older documentation refer to other blocks and are not used
for this assignment. They were outside the allowed edit scope.

For checks whose generated artifacts must also remain under `test/`, prefix the
commands with `FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache`.
To check the missing-RPC path in an isolated shell process:

```sh
env -u SEPOLIA_RPC_URL forge test --match-path test/HamsterOracleSepolia.t.sol -vv
```

## Added tests

| File | Coverage |
| --- | --- |
| `HamsterAdversarial.t.sol` | Exact settlement/scoring events including losses and replay; contract-wallet attribution rather than `tx.origin`; third-party credit isolation; rejected payments; duplicate and malformed pick rollback; invalid uint64 calldata; unavailable oracle with empty/future queues; rollback of a later batch after an existing score; truncated configuration, state and page ABI replies; uncertified zero-work claims. |
| `HamsterProperties.t.sol` | 1,000 cases each for full uint64 clock boundaries and schedule equivalence. Two games receive the same ledger/picks with different placement, settlement and checkpoint orders, crossing the 16-round batch boundary. Explicit threshold/work matrices include threshold 1, default 100, maximum 10000, empty JOG range and every pick. Mixed-outcome streaks test saturation, losses and resumption; round 1 and the supported timestamp boundary are pinned examples. |
| `PopulatedLeaderboardInvariant.t.sol` | 256 sequences of 96 calls, with 56 already-scored actors and eight pending picks each. Random prediction, reporting, settlement/replay, checkpoint and outage actions check a full top-50 list, including all six outsiders against the cutoff. Per-player checks use prior winning round IDs to calculate bonuses, reconcile individual awards with total points, and enforce chronological scoring and queue conservation. After every sequence, reporting catches up and every queue must drain. |
| `HamsterOracleSepolia.t.sol` | Five guarded live tests: deployment preflight; exact ABI/configuration and known round values; all certified rounds checked against independently traversed bulk pages and a replay into the existing mock; future entry cutoff and refusal to score an unchanged reporter frontier despite elapsed time; threshold-dependent classification and settlement replay. |

The fork fixture observed frontier **544** and cumulative work **45957** at the
pinned block. The bulk-ledger check traverses multiple pages and requires at
least one NAP, JOG and SPRINT. It compares all 544 individual round reads with
the reconstructed ledger. The live SqueekCore's code, storage and responses are
never replaced. The mock is deployed separately and receives the observed work
sequence through its ordinary test reporting method.

The positive prediction-to-score lifecycle runs offline against the matching
mock. The live fork deliberately uses historical rounds for settlement and a
future round for the unrecorded path. It does not fabricate future reports or
backdate predictions into already-known live results.

## Property review

The supplied Pashov invariant-discovery guides, Trail of Bits property-testing
reference and Foundry testing reference informed five passes over the code:

| Pass | Application locations | Properties exercised |
| --- | --- | --- |
| Conservation | `HamsterOracle.sol:134`, `:183`, `:302` | Pending plus scored equals placed; points equal individual awards; no duplicate prediction or credit; round counts remain tied to placed picks. |
| State transitions | `HamsterOracle.sol:128`, `:144`, `:163`, `:291` | Entry closes exactly at start; closed is distinct from certified; settlement is immutable; scoring is one-way; a revert preserves queue, score and leaderboard. |
| Round trips and boundaries | `HamsterOracle.sol:108`, `:116`, `:296`, `:309` | Timestamp-to-round inverse bounds; threshold endpoints; first-round behavior; capped bonus with uncapped streak; identical inputs converge across transaction schedules. |
| Adversarial sequences | `HamsterOracle.sol:252`, `:265`, `:325` | ABI truncation, malformed pages, source outage and static-call callbacks; caller cannot redirect credit; replay cannot farm points; omitted positive players cannot outrank the cutoff. |
| Queue and ranking properties | `RoundHeap.sol`, `HamsterOracle.sol:171`, `:331` | Reverse and shuffled entry still scores chronologically; bounded progress; future entries cannot prevent older certified entries from draining; deterministic ranking, eviction and reentry. |

The contract has no ETH/token custody or redeemable balances. Its points and
queues nevertheless receive stateful invariant coverage. The inherited
four-player campaign remains alongside the populated campaign. Invariant targets
are explicit handler selectors; expected oracle failures are checked for their
exact error and rollback, while unexpected handler reverts fail the campaign.

No application defect was reproduced by these checks. Failures encountered while
developing the tests were harness issues, including selecting the first active
round for an assertion that required earlier cumulative work. That fixture was
replaced with round 57, whose preceding cumulative work is nonzero.

## Local validation

Checked with Foundry 1.8.3, Solidity 0.8.26 and the seed above:

- `forge build`: passed; application lint warnings remain unchanged.
- Complete default `forge test -vv`: **52 reported tests passed, 0 failed,
  0 skipped**, across 11 suites. All five fork tests reached the pinned chain.
- New fuzz properties: **1,000 runs each**; the six inherited fuzz tests retain
  their existing 512-run setting.
- Invariant campaigns: **40,960 calls**, comprising the inherited 128 x 128
  campaign and the new 256 x 96 campaign; no unexpected handler reverts.
  Foundry reports each campaign as one aggregate test despite multiple named
  invariant functions.
- Fork suite with the RPC variable removed in a separate process and `--offline`:
  **5 skipped, 0 failed**.
- Compiled `ISqueekCore` ABI compared against `docs/abi/SqueekCore.json`: exact
  matches for `configuration`, `state` and `roundPage`, including tuple field
  names, order, integer widths and mutability (ignoring only `internalType`).

This is bounded contributor test evidence, not a deployment authorization or a
formal proof. The application still depends on SqueekCore's reporting and proxy
governance; compatibility at one pinned block cannot guarantee future upgrades.
Points require a permissionless checkpoint after settlement. The pre-deployment
independent review required by the brief must assess the final deployment and
arguments as well as these tests.
