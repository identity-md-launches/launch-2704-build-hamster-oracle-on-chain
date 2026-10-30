# Security review handoff

**Release gate: independent adversarial review pending. Do not deploy until a
separate contributor has reviewed the final source, tests and deployment
manifest, and material findings have been resolved.** This assignment builds
the project; it neither deploys it nor claims that its builder's checks are an
independent audit. No independent reviewer tool was available in this session.

The network's subsequent manifest and independent review steps must record the
reviewer's identity, reviewed source revision, constructor argument, findings,
fixes and acceptance. No owner, signer, private key or new dependency address is
needed from the requester to build this application.

## Scope and authority

Production scope is `src/HamsterOracle.sol`, `src/interfaces/ISqueekCore.sol`,
`src/libraries/RoundHeap.sol`, `foundry.toml` and the eventual manifest.
`MockSqueekCore`, test helpers and `Preflight` are not launch applications.
The source interface, retrieved ABI and actual Sepolia fork should be compared.

The constructor takes one immutable threshold. Every mutation is permissionless
on Sepolia. Predictions are keyed to `msg.sender`; checkpoint callers cannot
redirect credit. The contract contains no owner/admin storage, setters,
initializers, payable entry points, delegatecall, upgradeability, external library
linking, token operations, or payouts. A read-only preflight separately checks
the live source because the constructor must work on an empty rehearsal chain.

## Builder's adversarial analysis (not independent review)

| Attack / failure | Defense and evidence |
| --- | --- |
| Late/current-round prediction or duplicate replacement | Strict round-ID comparison at inclusion, immutable prediction flag; boundary and duplicate tests |
| Score a round after time elapses but before reporting | Requires closed time and certified frontier; delayed and never-certified tests |
| Treat missing unknown data as NAP | Frontier plus complete single-round page required; sparse-gap and incomplete-page tests |
| Confuse cumulative work with individual work | Endpoint delta and checkpoint consistency checks; mock and live fork cases |
| Change settlement order to farm streak bonuses | Player min heap always scores earliest pending prediction; permutation fuzz and stateful model |
| Insert an earlier future prediction after later predictions | Min-heap insertion, not append-only chronological restriction; targeted and stateful tests |
| Replay settlement or scoring | Immutable result cache; each pending prediction removed exactly once; repeat-call tests |
| Skip a loss to preserve a streak | No prediction cancellation or caller-supplied score selection; earliest-first processing and consecutive round-ID checks |
| Block all users by creating many participants | Settlement never loops over players; checkpoint handles one wallet and <=16 predictions |
| Block a wallet with arbitrary distant predictions | Only that wallet may add predictions; min heap keeps the earliest accessible |
| Wrong/duplicated top-50 membership after promotion or eviction | Positive scores only, deterministic ties, bounded insertion; full-sort fuzz over 57 players and 60-player eviction/reentry test |
| Upstream callback/reentrancy | All source calls use typed view interfaces and thus STATICCALL; malicious fallback test attempts a valid future prediction and cannot write |
| Partial update on malformed second oracle response | EVM rollback of the entire call; explicit regression test, then smaller valid batch can progress |
| Oracle outage / changed ABI / bad page / work >10000 | New settlement fails closed without awarding NAP; prior cached results remain usable |
| Upstream wrong clock or future frontier | Configuration and frontier/time validation before using new source data |
| ETH, transfer hooks, token approvals | None in application; nonpayable/fallback rejection tests; forced ETH has no game effect |
| Escape opcodes or excessive runtime size | Runtime scanned using the supplied protected-check algorithm; runtime below EIP-170 |

### Accounting and bounds

At most one prediction exists per `(wallet, roundId)`. Every such prediction is
either pending in that wallet's heap or scored, and exactly one history entry
exists. Round prediction counts never decrement and are not outcome-win counts.
The stateful model checks these relationships after arbitrary action sequences.

The bonus is `min(streak - 1, 5)`, so a scored prediction contributes at most 8.
Points only increase; a wrong pick resets the streak but never removes points.
With unique nonzero uint64 round IDs, a wallet cannot score more than
`2^64 - 1` predictions, so its uint256 point total cannot overflow. The uint64
run/counter fields are bounded by the same number of distinct rounds. The only
score cast is to uint8 after capping at 8. Round-time arithmetic uses uint256.

Heap insertion/removal is O(log pending predictions), at most 64 levels for
unique uint64 IDs. `checkpoint` handles at most 16 predictions. Source
`roundPage` performs its own binary search; the game requests one record and
never scans all upstream history. The leaderboard has at most 50 members;
updates scan and shift only that fixed set. History copies at most 100 entries.
There are no external calls to players and no loops over the total player count.

All calls to SqueekCore are STATICCALLs, including calls before queue mutation.
The attack test's attempted callback targets a valid future round and has enough
gas to succeed if it were a normal writable CALL. Static context prevents its
storage changes. A malicious upstream can still revert or return unreasonable
data; liveness and truthful measurements cannot be defended against the selected
oracle's own governance.

### Residual trust and operational concerns

- **Source authority:** the hamster's measurements and the SqueekCore signer are
  outside this game. Hamster Oracle adds no signer but cannot make the physical
  measurement trustless. SqueekCore is an upgradeable proxy with its own powers.
- **Source upgrades:** caching prevents later changes through this game, but
  an upstream malicious upgrade could supply false data for uncached rounds.
  Semantic upgrades that preserve the ABI cannot be detected from types alone.
  Preflight pins the observed implementation; the game itself only enforces
  configuration/page consistency. A new incompatible integration needs a new
  reviewed game deployment, not an admin override.
- **Liveness:** uncertified history never scores. A permanently stalled reporter
  cannot be replaced by this application. Malformed history can block a wallet's
  chronological queue at that round; fail-closed behavior is intentional.
- **Crediting:** views/leaderboard show credited points, so a keeper or player
  must call checkpoint. There is no automatic execution or monetary incentive.
  Full run length is at the last credited round, not a live clock-based streak.
- **Identity and information:** wallets are not unique humans; ties can be
  influenced by choosing addresses. Public picks can be copied. Neither affects
  financial rights because there are no rewards, stakes or token claims.
- **Time:** block timestamp determines entry boundaries, never randomness.
  Inclusion delay near a boundary can close a prediction before it is mined.
- **ETH:** forced ETH is possible at EVM level despite nonpayable functions.
  It is not an owed balance; no recovery/sweep privilege exists.

The supplied eth-security material was consulted as background. No Slither or
Mythril run, human audit, or independent contributor sign-off is claimed.
Foundry's compiler/linter diagnostics about timestamp comparisons, bounded
external calls in loops, fail-closed reverts, and range-checked casts should be
reviewed in context, rather than treated as proof of a defect or an audit pass.

## Independent review instructions for the release operator

Give the reviewer the final source, pinned ABI/provenance, complete tests,
build configuration and generated manifest with `threshold_ = 100` (or the
explicitly selected alternative). Ask them to challenge, at minimum, the round
clock, sparse-zero handling, delayed/frontier behavior, score order and replay,
heap invariants, leaderboard completeness, absence of privileges/value flows,
upstream upgrade assumptions, and worst-case transaction gas.

The reviewer must independently run offline checks and the archival fork suite,
record concrete failing inputs for findings, and review fixes. Deployment is
conditional on that review and the deployment service's own checks. Publish the
confirmed deployment address only after the service supplies it.

