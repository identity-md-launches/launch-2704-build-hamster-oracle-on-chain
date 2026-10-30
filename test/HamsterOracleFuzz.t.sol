// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HamsterTestBase, HamsterOracle} from "./HamsterTestBase.sol";

contract HamsterOracleFuzzTest is HamsterTestBase {
    function testFuzz_thresholdAndWorkClassification(uint64 workSeed, uint64 thresholdSeed, uint8 pickSeed)
        public
    {
        uint64 work = uint64(bound(workSeed, 0, 10_000));
        uint64 threshold = uint64(bound(thresholdSeed, 1, 10_000));
        HamsterOracle candidate = new HamsterOracle(threshold);
        HamsterOracle.Outcome pick = HamsterOracle.Outcome(pickSeed % 3);
        vm.prank(alice);
        candidate.predict(2, pick);
        _close(2);
        core.record(2, work);
        (uint64 read, HamsterOracle.Outcome actual) = candidate.settle(2);
        uint256 expected = work == 0 ? 0 : (work < threshold ? 1 : 2);
        assertEq(read, work);
        assertEq(uint256(actual), expected);
        candidate.checkpoint(alice, 1);
        uint256 points = uint256(pick) == expected ? (expected == 2 ? 3 : 1) : 0;
        assertEq(candidate.points(alice), points);
        assertEq(candidate.streak(alice), points > 0 ? 1 : 0);
        candidate.checkpoint(alice, 16);
        assertEq(candidate.points(alice), points, "repeated score");
    }

    function testFuzz_predictionBoundary(uint32 roundSeed, uint16 elapsedSeed) public {
        uint64 roundId = uint64(bound(roundSeed, 2, type(uint32).max));
        uint256 start = game.roundStart(roundId);
        vm.warp(start - 1);
        assertEq(game.currentRound(), roundId - 1);
        _pick(alice, roundId, HamsterOracle.Outcome.NAP);
        vm.warp(start + bound(elapsedSeed, 0, 599));
        assertEq(game.currentRound(), roundId);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotFuture.selector, roundId));
        _pick(bob, roundId, HamsterOracle.Outcome.NAP);
        _pick(bob, roundId + 1, HamsterOracle.Outcome.NAP);
    }

    /// @dev Independent chronological reference model, randomized insertion/settlement
    /// order, skipped rounds, outcomes, picks, and checkpoint batch boundaries.
    function testFuzz_scoringMatchesReferenceUnderPermutations(uint256 seed, uint8 lengthSeed) public {
        uint256 length = bound(lengthSeed, 1, 32);
        uint64[] memory order = new uint64[](length);
        uint64[] memory work = new uint64[](length);
        uint8[] memory picks = new uint8[](length);
        bool[] memory entered = new bool[](length);
        uint256 expectedCount;
        for (uint256 i; i < length; ++i) {
            order[i] = uint64(i + 2);
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            work[i] = random % 3 == 0 ? 0 : (random % 3 == 1 ? 99 : 100);
            picks[i] = uint8((random >> 16) % 3);
            entered[i] = (random >> 32) % 5 != 0;
            if (entered[i]) ++expectedCount;
        }
        _shuffle(order, seed);
        for (uint256 i; i < length; ++i) {
            uint64 r = order[i];
            if (entered[r - 2]) _pick(alice, r, HamsterOracle.Outcome(picks[r - 2]));
        }
        _close(uint64(length + 1));
        for (uint256 i; i < length; ++i) {
            core.record(uint64(i + 2), work[i]);
        }
        _shuffle(order, ~seed);
        for (uint256 i; i < length; ++i) {
            game.settle(order[i]);
        }

        uint256 processed;
        uint256 batch = seed % 16 + 1;
        while (processed < expectedCount) {
            uint256 progress = game.checkpoint(alice, batch);
            assertGt(progress, 0, "queue stalled");
            assertLe(progress, batch);
            processed += progress;
        }
        assertEq(processed, expectedCount);
        uint256 expectedPoints;
        uint64 expectedStreak;
        uint64 previousRound;
        for (uint256 i; i < length; ++i) {
            if (!entered[i]) continue;
            uint64 r = uint64(i + 2);
            uint8 outcome = work[i] == 0 ? 0 : (work[i] < 100 ? 1 : 2);
            uint8 awarded;
            if (picks[i] == outcome) {
                if (r == previousRound + 1) ++expectedStreak;
                else expectedStreak = 1;
                uint64 bonus = expectedStreak > 6 ? 5 : expectedStreak - 1;
                awarded = uint8((outcome == 2 ? 3 : 1) + bonus);
            } else {
                expectedStreak = 0;
            }
            expectedPoints += awarded;
            previousRound = r;
            _assertPrediction(alice, r, true, awarded);
        }
        assertEq(game.points(alice), expectedPoints);
        assertEq(game.streak(alice), expectedStreak);
        (,, uint64 last, uint64 count) = game.players(alice);
        assertEq(last, previousRound);
        assertEq(count, expectedCount);
        assertEq(game.checkpoint(alice, 16), 0);
        assertEq(game.points(alice), expectedPoints);
    }

    function testFuzz_historyPaginationNeverDuplicatesOrDrops(uint8 countSeed, uint8 pageSeed) public {
        uint256 count = bound(countSeed, 1, 128);
        uint256 page = bound(pageSeed, 1, 100);
        for (uint256 i; i < count; ++i) {
            _pick(alice, uint64(count - i + 1), HamsterOracle.Outcome.NAP);
        }
        uint256 offset;
        while (offset < count) {
            (HamsterOracle.HistoryEntry[] memory entries, uint256 next) =
                game.predictionHistory(alice, offset, page);
            assertLe(entries.length, page);
            for (uint256 i; i < entries.length; ++i) {
                assertEq(entries[i].roundId, count - offset - i + 1);
            }
            assertEq(next, offset + entries.length);
            offset = next;
        }
        assertEq(offset, count);
    }

    function _shuffle(uint64[] memory values, uint256 seed) private pure {
        for (uint256 i = values.length; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            (values[i - 1], values[j]) = (values[j], values[i - 1]);
        }
    }
}

