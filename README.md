# Hamster Oracle

A Sepolia prediction game using the work recorded by Squeekchain's hamster wheel.
Players earn nontransferable, nonredeemable points. There is no token, wager,
entry fee, prize pool, owner, oracle signer, result override, or upgrade path in
this application. Transactions still consume Sepolia gas.

The deliverable is the Solidity application, Foundry tests, pinned dependency
ABI, and deployment/review documentation. No contracts have been deployed by
this assignment. **Independent adversarial review is required before deployment**;
the builder's tests and review notes are not that review. See
[the review handoff](docs/SECURITY_REVIEW.md).

## Build and check

Solidity **0.8.26** is pinned in `foundry.toml`, with the optimizer enabled and
`bytecode_hash = "none"`. The only dependency is a vendored copy of forge-std
(test support), present as ordinary files in `lib/forge-std`. No submodules,
package installation, FFI, filesystem cheatcodes, secrets, or network access are
needed for the default build and tests once the pinned compiler is installed.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xe2a1b90ca5dafcc24a60afd0ba176327e8bef6600ab7b5802b985b2bdbb72138 forge test
forge fmt --check
```

The configured fuzz seed is also the assignment's required seed. Fuzz tests run
512 cases each. The stateful invariant suite runs 128 sequences of 128 actions,
checking accounting, queues, histories, counts and the leaderboard against a
separate model. Tests do not read or mutate environment variables.

The separate fork profile requires a Sepolia archival RPC:

```sh
forge test --profile fork -vv
# Override the public endpoint if its historical state is unavailable:
forge test --profile fork --fork-url https://YOUR_SEPOLIA_ARCHIVE_RPC -vv
```

The default suite excludes `test/fork/**`; fork tests are never silently skipped
on RPC errors. The fork profile pins block 12,025,393. Its end-to-end test places
predictions at block 12,020,000 and rolls forward to actual recorded results,
without changing SqueekCore's code or storage. See
[ABI provenance and chain observations](docs/ABI_PROVENANCE.md) and
[validation evidence](docs/VALIDATION.md).

## Rules and explicit assumptions

Round IDs start at **1**, not 0. Round `r` covers:

```text
start = 1793022600 + (r - 1) * 600
end   = 1793022600 + r * 600
interval = [start, end)
```

Before genesis, `currentRound()` returns 0. Otherwise it returns
`floor((block.timestamp - genesis) / 600) + 1`. A prediction must target
`roundId > currentRound()`: the immediately following round qualifies. This is
a round-ID lead, not a requirement to submit 600 seconds before its start.
Predictions for round 1 are allowed before genesis. Round 0 is invalid.

One wallet may place one immutable prediction per round, in any order and as
far into the future as a `uint64` round ID permits. Contract wallets are allowed.
The exact start timestamp closes entry. Past/current rounds, duplicates, and
out-of-range enum values revert. The implementation rejects timestamps whose
current round no longer fits `uint64`, far beyond any practical chain lifetime.

| Pick / ABI value | Recorded work | Base points if correct |
| --- | --- | --- |
| NAP / 0 | 0 | 1 |
| JOG / 1 | 1 through `threshold - 1` | 1 |
| SPRINT / 2 | `threshold` through 10,000 | 3 |

An incorrect prediction earns 0 and resets the streak. A skipped round ID also
breaks the streak, even if the player's next prediction is correct. A run's
first correct prediction receives **no streak bonus**; every additional
consecutive correct round adds 1 bonus point, capped at +5. The stored streak
is the full run length, not capped. This resolves the brief's initial-bonus
ambiguity explicitly:

| Consecutive correct round in run | 1 | 2 | 3 | 4 | 5 | 6 | 7+ |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Correct NAP/JOG award | 1 | 2 | 3 | 4 | 5 | 6 | 6 |
| Correct SPRINT award | 3 | 4 | 5 | 6 | 7 | 8 | 8 |

`threshold` is immutable, with allowed values 1..10,000. Deploy with **100** by
default. A threshold of 1 intentionally leaves the JOG category empty.

## Reading SqueekCore correctly

The fixed dependency is the requester-specified Sepolia proxy
[`0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44`](https://eth-sepolia.blockscout.com/address/0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44).
The application cannot replace it. [ISqueekCore](src/interfaces/ISqueekCore.sol)
matches the verified implementation's tuple layouts; the full retrieved ABI is
vendored in [docs/abi/SqueekCore.json](docs/abi/SqueekCore.json).

`settledThroughRound` is a field of the `state()` tuple, **not a separate getter**
in this verified ABI. Only rounds at or below that frontier have certified work.
The reporter may be late by hours or may never report. Passing a wall-clock
deadline alone never creates a result or awards points.

For a closed, certified round `r`, the game requests
`roundPage(r - 1, r, 1)` and computes
`page.end.cumulativeWork - page.start.cumulativeWork`. It checks the page's
certified endpoint, monotonic cumulative work, consistency with the state and
active checkpoint, and the 10,000 work cap. A single-round request can contain
at most one active checkpoint, so there is no history scan in the game.

SqueekCore's sparse ledger certifies **omitted rounds within a settled span as
zero work**. Those are valid NAP results, even without a `RoundRecorded` event.
Rounds beyond the frontier are unknown and never score until certified. This
distinction comes from the verified implementation, not an assumption that an
absent record means rest. A paused reporter does not invalidate existing history.

## Settlement, scoring and views

Result settlement and player accounting are separate to keep every transaction
bounded regardless of the player count:

1. Anyone may call `settle(roundId)` after the round closes and is certified.
   This caches the work/outcome once and emits `RoundSettled`. Repeated calls
   return the cached result without emitting another settlement or changing it.
2. Anyone may call `checkpoint(player, maxRounds)`, with `maxRounds` from 1 to
   16. This credits that player's earliest pending predictions in round order,
   settling missing results itself. It stops at the first future/uncertified
   round and returns the number processed. Call it again to continue.
3. Points, streaks and leaderboard positions reflect **credited predictions**.
   Calling `settle` alone does not update every player. Wallets or a permissionless
   keeper should call `checkpoint` to make those views current.

There is no keeper role or keeper reward. A third party cannot redirect points;
it only pays gas to credit the named player. Submission order, settlement order,
the caller and checkpoint batch size cannot change the eventual score.
`PredictionScored` is emitted for each scored prediction, including wrong picks.
An unavailable/incompatible oracle reverts an uncached settlement, preserving
the queue. Results already cached remain usable during an upstream outage.

| API | Meaning |
| --- | --- |
| `predict(uint64, Outcome)` | Place caller's one prediction; emits `PredictionPlaced` |
| `settle(uint64)` | Cache certified result; returns `(work, outcome)` |
| `checkpoint(address, uint256)` | Credit up to 16 earliest pending predictions |
| `currentRound()`, `roundStart(r)`, `roundEnd(r)` | Round timing |
| `roundWork(r)` | Cached or live certified work; unknown rounds revert |
| `rounds(r)` | Cached `(work, outcome, settled)`; check the flag before using the enum |
| `predictions(player, r)` | `(pick, exists, scored, awarded)`; check `exists` |
| `points(player)`, `streak(player)` | Credited total and run ending at the last credited round |
| `players(player)` | Points, streak, last scored round, number scored |
| `pendingStatus(player)` | Earliest pending round (0 if none) and pending count |
| `roundCounts(r)` | Numbers of **predictions** for NAP, JOG, SPRINT, including wrong/pending picks |
| `historyLength(player)` | Number of predictions ever placed |
| `predictionHistory(player, offset, limit)` | Placement-order history, at most 100 entries, with next offset |
| `leaderboard()` | Up to 50 positive-score wallets, with their credited points |

History is in **placement order**, and includes prediction and cached-result
status. Offsets at/beyond the end return an empty page and the history length.
Limit 0 is valid; clients must choose a positive limit to advance. Empty/default
storage is not evidence of a NAP prediction or settlement.

The leaderboard sorts points descending, then numeric wallet address ascending
for ties. Zero-score players are omitted. Membership has no cap on entrants;
outsiders can enter when their score improves. A player's streak view does not
decay with time: it describes the run at `players(player).lastScoredRound`.
A skipped round is reflected when the next prediction is credited.

## Deployment and operations

Deploy **one application**, `HamsterOracle`, directly from the build output.
It is not a proxy. Its sole constructor argument is `uint64 threshold_`, default
decimal **100**, and constructor value is **0**. There is no owner argument and
no initialization call. The constructor validates Sepolia and the threshold,
but makes no dependency calls, so factory rehearsal on an otherwise empty
Sepolia-ID chain works. No `launch.json` is provided; the network's subsequent
manifest step owns it.

| Fixed parameter | Value |
| --- | --- |
| Chain ID | 11155111 (Sepolia), enforced at construction and every mutation |
| SqueekCore proxy | `0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44` |
| Genesis / round duration | 1793022600 / 600 seconds |
| Work cap / default threshold | 10000 / 100 |
| Checkpoint / history / leaderboard limits | 16 / 100 / 50 |
| Maximum bonus | 5 points |

Before launch, the deployment operator must obtain independent adversarial
review and resolve its findings. Run the fork suite and the read-only preflight
against current Sepolia state. The preflight pins the observed implementation
and runtime hash, so an upstream upgrade requires a fresh integration review:

```sh
forge script script/Preflight.s.sol:Preflight --rpc-url https://sepolia.gateway.tenderly.co
```

This script reads public state and does not broadcast or use a key. It does not
substitute for independent review, source verification or a deployment service's
simulation. The game checks clock/work-cap compatibility on new settlements;
it does not pin SqueekCore's implementation hash in its own runtime.

### After launch

There are **no settings or setters**. Use the confirmed address from the launch
handoff, publish/verify the exact source and constructor argument, and display
the chain, threshold and pending-versus-credited state to players.

Any operator may watch `PredictionPlaced`, and SqueekCore's `BatchSettled` and
`RoundRecorded`, call `settle` if useful, then call `checkpoint(player, 16)` for
affected wallets until the eligible queue is drained. Watching only
`RoundRecorded` misses certified zero-work gaps; use the certified frontier.
An indexer must handle chain reorgs, resume from durable block/log cursors and
query contract views to reconcile. No off-chain component supplies a result.
Operators pay gas and should monitor reporter lag, RPC failures and upgrades to
the external SqueekCore proxy. Players can always perform the same maintenance.

## Trust and limitations

Hamster Oracle's scoring has no privileged actor. It still relies on the chosen
SqueekCore reporter and proxy governance for truthful, available, immutable-in-
practice source history. The game cannot prove the hamster's physical actions.
An upstream upgrade can break the ABI, change future results or halt new scoring;
this game has no bypass, migration setter or recovery administrator. Cached
results cannot be overwritten through the application.

If a round remains beyond SqueekCore's frontier forever, it never scores. With
this contiguous frontier, later rounds also cannot be certified without settling
that span. There is no timeout that invents a result. No anti-Sybil identity is
claimed: one wallet is one account, and points confer no financial rights.
Picks are public and copyable until entry closes. Near-boundary transactions
may miss the cutoff if included late; submit with time to spare.

Normal ETH transfers and payable calls revert. Forced ETH, if any, is unrelated
to game accounting and cannot be withdrawn. There are no token transfers,
approvals, callbacks to players or payout obligations.

## Project files

- [src/HamsterOracle.sol](src/HamsterOracle.sol): the only deployable application.
- [src/interfaces/ISqueekCore.sol](src/interfaces/ISqueekCore.sol): exact read ABI subset.
- [src/libraries/RoundHeap.sol](src/libraries/RoundHeap.sol): internal-only min heap for chronological scoring.
- [test/](test/): unit, fuzz, adversarial, stateful and opt-in fork tests.
- [script/Preflight.s.sol](script/Preflight.s.sol): read-only dependency checks.
- [docs/SECURITY_REVIEW.md](docs/SECURITY_REVIEW.md): review status, threats and release gate.
- [DEPENDENCIES.md](DEPENDENCIES.md): vendored dependency and license provenance.

