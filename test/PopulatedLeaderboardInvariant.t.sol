// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterTestBase, HamsterOracle} from "./HamsterTestBase.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";

/// @dev All 56 actors start with a credited point and eight pending picks. The
/// cutoff, outsider exclusion, promotions and eviction are reachable from the
/// first randomized call, rather than depending on a mostly empty campaign.
contract PopulatedLeaderboardHandler is Test {
    HamsterOracle public immutable game;
    MockSqueekCore public immutable core;
    address[56] public actors;
    mapping(address => uint256) private _actorIndexPlusOne;
    mapping(address => uint64[]) private _history;
    mapping(address => mapping(uint64 => uint8)) private _pickPlusOne;
    mapping(uint64 => uint64) private _work;
    mapping(uint64 => bool) private _cached;
    uint64 public frontier;

    constructor(HamsterOracle game_, MockSqueekCore core_) {
        game = game_;
        core = core_;
        for (uint256 i; i < actors.length; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encode("population actor", i)))));
            actors[i] = actor;
            _actorIndexPlusOne[actor] = i + 1;
            for (uint64 r = 10; r >= 3; --r) _predict(actor, r, uint8((i + r) % 3));
            _predict(actor, 2, 0);
        }
        vm.warp(1_793_022_600 + 10 * 600);
        for (uint64 r = 2; r <= 10; ++r) {
            uint64 work = r == 2 ? 0 : (r % 3 == 0 ? 0 : (r % 3 == 1 ? 99 : 100));
            _work[r] = work;
            core.record(r, work);
        }
        frontier = 10;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(game.checkpoint(actors[i], 1), 1);
            assertEq(game.points(actors[i]), 1);
        }
    }

    function predict(uint8 who, uint8 ahead, uint8 pickSeed) external {
        address actor = actors[who % actors.length];
        uint64 r = game.currentRound() + 1 + uint64(ahead % 6);
        if (_pickPlusOne[actor][r] != 0) return;
        _predict(actor, r, pickSeed % 3);
        _assertAccount(actor);
    }

    function advanceAndReport(uint8 delaySeed, uint8 distanceSeed, uint16 workSeed) external {
        uint64 closed = game.currentRound() + uint64(delaySeed % 3);
        vm.warp(1_793_022_600 + uint256(closed) * 600);
        uint64 next = frontier + 1 + uint64(distanceSeed) % (closed - frontier);
        uint64[6] memory edges = [uint64(0), 1, 99, 100, 10_000, uint64(workSeed % 10_001)];
        uint64 work = edges[workSeed % edges.length];
        core.record(next, work);
        _work[next] = work;
        frontier = next;
    }

    function checkpoint(uint8 who, uint8 batchSeed) external {
        address actor = actors[who % actors.length];
        uint256 beforePoints = game.points(actor);
        uint256 batch = 1 + batchSeed % 16;
        uint256 processed = game.checkpoint(actor, batch);
        assertLe(processed, batch);
        assertGe(game.points(actor), beforePoints, "points decreased");
        _assertAccount(actor);
    }

    function checkpointDuringOutage(uint8 who, uint8 batchSeed) external {
        address actor = actors[who % actors.length];
        bytes32 beforeState = _snapshot(actor);
        core.setUnavailable(true);
        (bool ok, bytes memory result) = address(game).call(
            abi.encodeCall(HamsterOracle.checkpoint, (actor, uint256(1 + batchSeed % 16)))
        );
        core.setUnavailable(false);
        if (!ok) {
            assertEq(result, abi.encodeWithSignature("Error(string)", "core unavailable"));
            assertEq(_snapshot(actor), beforeState, "failed checkpoint partially committed");
        } else {
            assertLe(abi.decode(result, (uint256)), 1 + batchSeed % 16);
        }
        _assertAccount(actor);
    }

    function settleAndReplay(uint16 roundSeed) external {
        uint64 r = 1 + uint64(roundSeed) % frontier;
        uint64 expectedWork = _work[r];
        (uint64 work, HamsterOracle.Outcome outcome) = game.settle(r);
        assertEq(work, expectedWork);
        assertEq(uint256(outcome), _outcome(r));
        _cached[r] = true;
        // The cached read and settlement must continue to work without any
        // successful oracle call, and cannot emit a second settlement event.
        core.setUnavailable(true);
        vm.recordLogs();
        (work, outcome) = game.settle(r);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(game.roundWork(r), expectedWork);
        assertEq(work, expectedWork);
        assertEq(uint256(outcome), _outcome(r));
        core.setUnavailable(false);
    }

    function assertLeaderboard() external view {
        HamsterOracle.LeaderboardEntry[] memory leaders = game.leaderboard();
        assertEq(leaders.length, 50, "populated top-50 changed size");
        bool[56] memory included;
        for (uint256 i; i < leaders.length; ++i) {
            address actor = leaders[i].player;
            uint256 actorIndex = _actorIndexPlusOne[actor];
            assertGt(actorIndex, 0, "unknown player entered leaderboard");
            assertFalse(included[actorIndex - 1], "duplicate member");
            included[actorIndex - 1] = true;
            assertEq(leaders[i].points, game.points(actor), "stale leaderboard score");
            assertGt(leaders[i].points, 0);
            if (i != 0) {
                assertTrue(_ahead(leaders[i - 1].points, leaders[i - 1].player, leaders[i].points, actor),
                    "leaderboard unsorted or contains duplicates");
            }
        }
        HamsterOracle.LeaderboardEntry memory cutoff = leaders[49];
        uint256 outsiders;
        for (uint256 i; i < actors.length; ++i) {
            assertGe(game.points(actors[i]), 1, "seeded score disappeared");
            if (!included[i]) {
                ++outsiders;
                assertTrue(_ahead(cutoff.points, cutoff.player, game.points(actors[i]), actors[i]),
                    "an omitted player outranks the cutoff");
            }
        }
        assertEq(outsiders, 6);
    }

    function assertCachedResults() external view {
        for (uint64 r = 1; r <= frontier; ++r) {
            (uint64 work, HamsterOracle.Outcome outcome, bool settled) = game.rounds(r);
            if (_cached[r]) assertTrue(settled, "cached result reopened");
            if (settled) {
                assertEq(work, _work[r]);
                assertEq(uint256(outcome), _outcome(r));
            }
        }
    }

    /// @dev At sequence end certify the remaining time span and drain all
    /// wallets. This tests liveness even if the random sequence never selected
    /// a particular wallet for credit, and audits every prediction's accounting.
    function finishAndAssert() external {
        uint64 closed = game.currentRound() + 7;
        vm.warp(1_793_022_600 + uint256(closed) * 600);
        core.record(closed, 0);
        frontier = closed;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            (, uint256 pending) = game.pendingStatus(actor);
            while (pending != 0) {
                uint256 processed = game.checkpoint(actor, 16);
                assertGt(processed, 0, "certified pending queue cannot make progress");
                assertLe(processed, 16);
                assertLe(processed, pending);
                pending -= processed;
            }
            _assertAccount(actor);
            (uint64 next, uint256 count) = game.pendingStatus(actor);
            assertEq(next, 0);
            assertEq(count, 0);
        }
    }

    function _predict(address actor, uint64 r, uint8 pick) private {
        vm.prank(actor);
        game.predict(r, HamsterOracle.Outcome(pick));
        _pickPlusOne[actor][r] = pick + 1;
        _history[actor].push(r);
    }

    function _assertAccount(address actor) private view {
        uint64[] storage history = _history[actor];
        uint256 total;
        uint64 scoredCount;
        uint64 last;
        uint64 earliest;
        for (uint256 i; i < history.length; ++i) {
            uint64 r = history[i];
            (HamsterOracle.Outcome pick, bool exists, bool scored, uint8 award) = game.predictions(actor, r);
            assertTrue(exists);
            assertEq(uint256(pick) + 1, _pickPlusOne[actor][r]);
            if (!scored) {
                assertEq(award, 0);
                if (earliest == 0 || r < earliest) earliest = r;
                continue;
            }
            assertLe(r, frontier, "uncertified prediction scored");
            (,, bool settled) = game.rounds(r);
            assertTrue(settled, "scored prediction has no cached result");
            uint256 expected;
            if (_correct(actor, r)) {
                expected = _outcome(r) == 2 ? 3 : 1;
                // Count up to five immediately preceding winning round IDs.
                // This oracle uses historical facts, not the game's running streak.
                for (uint64 distance = 1; distance <= 5 && distance < r; ++distance) {
                    if (!_correct(actor, r - distance)) break;
                    ++expected;
                }
            }
            assertEq(award, expected, "individual award disagrees with preceding winning rounds");
            total += award;
            ++scoredCount;
            if (r > last) last = r;
        }
        (uint256 points, uint64 streak, uint64 actualLast, uint64 actualScored) = game.players(actor);
        assertEq(points, total, "points do not equal the sum of individual awards");
        assertEq(actualScored, scoredCount);
        assertEq(actualLast, last);
        uint64 run;
        for (uint64 r = last; r != 0 && _correct(actor, r); --r) ++run;
        assertEq(streak, run);
        (uint64 next, uint256 pending) = game.pendingStatus(actor);
        assertEq(next, earliest);
        assertEq(pending + scoredCount, history.length, "lost or duplicated pending prediction");
        if (earliest != 0) assertGt(earliest, last, "checkpoint skipped an older pending round");
        assertEq(game.historyLength(actor), history.length);
    }

    function _correct(address actor, uint64 r) private view returns (bool) {
        return _pickPlusOne[actor][r] == _outcome(r) + 1;
    }

    function _outcome(uint64 r) private view returns (uint8) {
        uint64 work = _work[r];
        return work == 0 ? 0 : (work < 100 ? 1 : 2);
    }

    function _ahead(uint256 aPoints, address a, uint256 bPoints, address b) private pure returns (bool) {
        return aPoints > bPoints || (aPoints == bPoints && uint160(a) < uint160(b));
    }

    function _snapshot(address actor) private view returns (bytes32) {
        (uint256 points, uint64 streak, uint64 last, uint64 count) = game.players(actor);
        (uint64 next, uint256 pending) = game.pendingStatus(actor);
        (HamsterOracle.HistoryEntry[] memory history,) = game.predictionHistory(actor, 0, 100);
        return keccak256(abi.encode(points, streak, last, count, next, pending, history, game.leaderboard()));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PopulatedLeaderboardInvariantTest is HamsterTestBase {
    PopulatedLeaderboardHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new PopulatedLeaderboardHandler(game, core);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = PopulatedLeaderboardHandler.predict.selector;
        selectors[1] = PopulatedLeaderboardHandler.advanceAndReport.selector;
        selectors[2] = PopulatedLeaderboardHandler.checkpoint.selector;
        selectors[3] = PopulatedLeaderboardHandler.checkpointDuringOutage.selector;
        selectors[4] = PopulatedLeaderboardHandler.settleAndReplay.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_top50IsCompleteSortedUniqueAndCurrent() public view {
        handler.assertLeaderboard();
    }

    function invariant_settledRoundsNeverReopenOrChange() public view {
        handler.assertCachedResults();
    }

    function afterInvariant() public {
        handler.finishAndAssert();
        handler.assertLeaderboard();
        handler.assertCachedResults();
    }
}
