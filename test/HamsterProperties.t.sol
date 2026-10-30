// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HamsterTestBase, HamsterOracle} from "./HamsterTestBase.sol";

contract HamsterPropertiesTest is HamsterTestBase {
    struct PlannedRound {
        uint64 work;
        HamsterOracle.Outcome pick;
        bool entered;
    }

    /// @dev Same predictions and real mock ledger, two different transaction
    /// schedules: reverse placement with incremental reporting/credit, versus
    /// shuffled placement, reverse settlement and delayed batched credit.
    /// This is a schedule-equivalence property, not a second copy of _score.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_scoresDoNotDependOnPlacementSettlementOrCheckpointSchedule(
        uint256 seed, uint16 thresholdSeed, uint8 sizeSeed, uint8 batchSeed
    ) public {
        uint64 threshold = uint64(bound(thresholdSeed, 1, 10_000));
        HamsterOracle eager = new HamsterOracle(threshold);
        HamsterOracle delayed = new HamsterOracle(threshold);
        uint256 length = bound(sizeSeed, 33, 48);
        PlannedRound[] memory plan = new PlannedRound[](length);
        uint64[] memory shuffled = new uint64[](length);
        uint256 entered;
        for (uint256 i; i < length; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            uint64[5] memory workEdges = [uint64(0), 1, threshold - 1, threshold, 10_000];
            plan[i] = PlannedRound(workEdges[random % 5], HamsterOracle.Outcome((random >> 32) % 3), i % 7 != 4);
            // Every case contains at least one correct prediction and one loss.
            if (i == 0) plan[i] = PlannedRound(0, HamsterOracle.Outcome.NAP, true);
            if (i == 1) plan[i] = PlannedRound(0, HamsterOracle.Outcome.SPRINT, true);
            if (plan[i].entered) ++entered;
            shuffled[i] = uint64(i + 2);
        }
        for (uint256 i = length; i > 0; --i) {
            if (plan[i - 1].entered) {
                vm.prank(alice);
                eager.predict(uint64(i + 1), plan[i - 1].pick);
            }
        }
        for (uint256 i = length; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i, "placement"))) % i;
            (shuffled[i - 1], shuffled[j]) = (shuffled[j], shuffled[i - 1]);
        }
        for (uint256 i; i < length; ++i) {
            uint64 r = shuffled[i];
            if (plan[r - 2].entered) {
                vm.prank(alice);
                delayed.predict(r, plan[r - 2].pick);
            }
        }
        assertEq(eager.checkpoint(alice, 16), 0);
        assertEq(delayed.checkpoint(alice, 16), 0);
        uint256 batch = bound(batchSeed, 1, 16);
        for (uint256 i; i < length; ++i) {
            uint64 r = uint64(i + 2);
            _close(r);
            // Being closed is insufficient even with the preceding round certified.
            vm.expectRevert(abi.encodeWithSelector(
                HamsterOracle.RoundNotRecorded.selector, r, uint64(i == 0 ? 0 : r - 1)
            ));
            eager.roundWork(r);
            core.record(r, plan[i].work);
            if ((seed >> (i % 256)) & 1 != 0) eager.settle(r);
            vm.prank(bob);
            assertLe(eager.checkpoint(alice, batch), batch);
        }
        for (uint256 i = length; i > 0; --i) delayed.settle(uint64(i + 1));
        _drain(eager, alice, 16);
        _drain(delayed, alice, batch);
        _assertSamePlayer(eager, delayed, alice);
        assertGt(eager.points(alice), 0);
        assertEq(eager.points(bob), 0);
        assertEq(delayed.points(bob), 0);
        (,,, uint64 scored) = eager.players(alice);
        assertEq(scored, entered);
        assertGt(scored, 16, "must cross a checkpoint batch boundary");
        assertEq(keccak256(abi.encode(eager.leaderboard())), keccak256(abi.encode(delayed.leaderboard())));
        for (uint64 r = 2; r < length + 2; ++r) {
            (HamsterOracle.Outcome pickA, bool existsA, bool scoredA, uint8 awardA) = eager.predictions(alice, r);
            (HamsterOracle.Outcome pickB, bool existsB, bool scoredB, uint8 awardB) = delayed.predictions(alice, r);
            assertEq(uint256(pickA), uint256(pickB));
            assertEq(existsA, plan[r - 2].entered);
            assertEq(existsA, existsB);
            assertEq(scoredA, existsA);
            assertEq(scoredA, scoredB);
            assertEq(awardA, awardB, "schedule changed an individual award");
            assertLe(awardA, 8);
        }
    }

    function test_thresholdEdgesCoverAllPicksIncludingEmptyJogCategory() public {
        uint64[3] memory thresholds = [uint64(1), 100, 10_000];
        uint64[5] memory works = [uint64(0), 1, 99, 100, 10_000];
        HamsterOracle[3] memory games;
        for (uint256 t; t < thresholds.length; ++t) {
            games[t] = new HamsterOracle(thresholds[t]);
            for (uint256 w; w < works.length; ++w) {
                for (uint8 pick; pick < 3; ++pick) {
                    address player = _matrixPlayer(t, w, pick);
                    vm.prank(player);
                    games[t].predict(uint64(w + 2), HamsterOracle.Outcome(pick));
                }
            }
        }
        _close(6);
        for (uint256 w; w < works.length; ++w) core.record(uint64(w + 2), works[w]);
        uint8[5][3] memory expectedOutcomes = [
            [uint8(0), 2, 2, 2, 2],
            [uint8(0), 1, 1, 2, 2],
            [uint8(0), 1, 1, 1, 2]
        ];
        for (uint256 t; t < thresholds.length; ++t) {
            for (uint256 w; w < works.length; ++w) {
                (uint64 work, HamsterOracle.Outcome outcome) = games[t].settle(uint64(w + 2));
                assertEq(work, works[w]);
                assertEq(uint256(outcome), expectedOutcomes[t][w]);
                for (uint8 pick; pick < 3; ++pick) {
                    address player = _matrixPlayer(t, w, pick);
                    assertEq(games[t].checkpoint(player, 1), 1);
                    uint256 expected = pick == expectedOutcomes[t][w] ? (pick == 2 ? 3 : 1) : 0;
                    assertEq(games[t].points(player), expected);
                    assertEq(games[t].streak(player), expected == 0 ? 0 : 1);
                }
            }
        }
    }

    function test_firstRoundAndMaximumRepresentableClockEdges() public {
        vm.warp(GENESIS - 1);
        _pick(alice, 1, HamsterOracle.Outcome.NAP);
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        _close(2);
        core.record(2, 100);
        assertEq(_credit(alice), 2);
        _assertPrediction(alice, 1, true, 1);
        _assertPrediction(alice, 2, true, 4);
        assertEq(game.points(alice), 5);
        assertEq(game.streak(alice), 2);

        uint64 last = type(uint64).max;
        _pick(bob, last, HamsterOracle.Outcome.NAP);
        _pick(bob, last - 1, HamsterOracle.Outcome.SPRINT);
        _pick(bob, last - 2, HamsterOracle.Outcome.SPRINT);
        vm.warp(game.roundStart(last));
        assertEq(game.currentRound(), last);
        core.record(last - 2, 100);
        core.record(last - 1, 100);
        assertEq(_credit(bob), 2);
        assertEq(game.points(bob), 7);
        assertEq(game.streak(bob), 2);
        (uint64 next, uint256 count) = game.pendingStatus(bob);
        assertEq(next, last);
        assertEq(count, 1);
        vm.warp(game.roundEnd(last) - 1);
        assertEq(game.currentRound(), last);
        vm.warp(game.roundEnd(last));
        vm.expectRevert(HamsterOracle.UnsupportedTimestamp.selector);
        game.currentRound();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_roundClockRoundTripsAcrossFullUint64Domain(uint64 seed, uint16 offsetSeed) public {
        uint64 r = uint64(bound(seed, 1, type(uint64).max));
        uint256 start = game.roundStart(r);
        uint256 end = game.roundEnd(r);
        assertEq(end - start, 600);
        vm.warp(start - 1);
        assertEq(game.currentRound(), r - 1);
        vm.warp(start + bound(offsetSeed, 0, 599));
        assertEq(game.currentRound(), r);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotFuture.selector, r));
        _pick(alice, r, HamsterOracle.Outcome.NAP);
        vm.warp(end - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotClosed.selector, r));
        game.settle(r);
    }

    function test_saturatedStreakBonusAcrossMixedOutcomesAndAfterLoss() public {
        // NAP, JOG and SPRINT all advance the same streak. Base points differ.
        uint64[9] memory works = [uint64(100), 0, 1, 100, 0, 1, 100, 0, 100];
        HamsterOracle.Outcome[9] memory picks = [
            HamsterOracle.Outcome.SPRINT, HamsterOracle.Outcome.NAP, HamsterOracle.Outcome.JOG,
            HamsterOracle.Outcome.SPRINT, HamsterOracle.Outcome.NAP, HamsterOracle.Outcome.JOG,
            HamsterOracle.Outcome.SPRINT, HamsterOracle.Outcome.JOG, HamsterOracle.Outcome.SPRINT
        ];
        uint8[9] memory awards = [uint8(3), 2, 3, 6, 5, 6, 8, 0, 3];
        for (uint256 i; i < works.length; ++i) _pick(alice, uint64(i + 2), picks[i]);
        _close(10);
        for (uint256 i; i < works.length; ++i) core.record(uint64(i + 2), works[i]);
        assertEq(game.checkpoint(alice, 7), 7);
        assertEq(game.streak(alice), 7, "full streak must not be capped at the bonus cap");
        assertEq(game.points(alice), 33);
        assertEq(game.checkpoint(alice, 1), 1);
        assertEq(game.streak(alice), 0);
        assertEq(game.points(alice), 33, "loss must not remove earned points");
        assertEq(game.checkpoint(alice, 1), 1);
        assertEq(game.streak(alice), 1);
        assertEq(game.points(alice), 36);
        for (uint256 i; i < awards.length; ++i) _assertPrediction(alice, uint64(i + 2), true, awards[i]);
    }

    function _matrixPlayer(uint256 t, uint256 w, uint8 pick) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("threshold matrix player", t, w, pick)))));
    }

    function _drain(HamsterOracle candidate, address player, uint256 batch) private {
        (, uint256 pending) = candidate.pendingStatus(player);
        while (pending != 0) {
            uint256 processed = candidate.checkpoint(player, batch);
            assertGt(processed, 0, "certified queue stalled");
            assertLe(processed, batch);
            assertLe(processed, pending);
            pending -= processed;
        }
        (uint64 next, uint256 count) = candidate.pendingStatus(player);
        assertEq(next, 0);
        assertEq(count, 0);
        assertEq(candidate.checkpoint(player, batch), 0);
    }

    function _assertSamePlayer(HamsterOracle a, HamsterOracle b, address player) private view {
        (uint256 pointsA, uint64 streakA, uint64 lastA, uint64 countA) = a.players(player);
        (uint256 pointsB, uint64 streakB, uint64 lastB, uint64 countB) = b.players(player);
        assertEq(pointsA, pointsB, "schedule changed total points");
        assertEq(streakA, streakB, "schedule changed streak");
        assertEq(lastA, lastB);
        assertEq(countA, countB);
    }
}
