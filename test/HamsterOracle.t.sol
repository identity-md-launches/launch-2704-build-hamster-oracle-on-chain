// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HamsterTestBase, HamsterOracle, ISqueekCore} from "./HamsterTestBase.sol";

contract HamsterOracleTest is HamsterTestBase {
    event PredictionPlaced(address indexed player, uint64 indexed roundId, HamsterOracle.Outcome pick);
    event RoundSettled(uint64 indexed roundId, uint64 work, HamsterOracle.Outcome outcome);
    event PredictionScored(
        address indexed player,
        uint64 indexed roundId,
        bool correct,
        uint8 awarded,
        uint256 totalPoints,
        uint64 streak
    );

    function test_constructorRequiresSepoliaAndValidThresholdButNoDependency() public {
        vm.etch(CORE, hex"");
        HamsterOracle isolated = new HamsterOracle(100);
        assertEq(isolated.SQUEEK_CORE(), CORE);
        assertEq(isolated.threshold(), 100);
        assertEq(address(isolated).balance, 0);
        assertEq(new HamsterOracle(1).threshold(), 1);
        assertEq(new HamsterOracle(10_000).threshold(), 10_000);
        vm.expectRevert(HamsterOracle.InvalidThreshold.selector);
        new HamsterOracle(0);
        vm.expectRevert(HamsterOracle.InvalidThreshold.selector);
        new HamsterOracle(10_001);
        vm.chainId(1);
        vm.expectRevert(HamsterOracle.WrongChain.selector);
        new HamsterOracle(100);
    }

    function test_roundNumberingAndExactStartCutoff() public {
        vm.warp(GENESIS - 1);
        assertEq(game.currentRound(), 0);
        _pick(alice, 1, HamsterOracle.Outcome.NAP);
        vm.warp(GENESIS);
        assertEq(game.currentRound(), 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotFuture.selector, uint64(1)));
        _pick(bob, 1, HamsterOracle.Outcome.NAP);
        vm.warp(GENESIS + 599);
        _pick(bob, 2, HamsterOracle.Outcome.JOG);
        vm.warp(GENESIS + 600);
        assertEq(game.currentRound(), 2);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotFuture.selector, uint64(2)));
        _pick(alice, 2, HamsterOracle.Outcome.JOG);
        assertEq(game.roundStart(1), GENESIS);
        assertEq(game.roundEnd(1), GENESIS + 600);
        assertEq(game.roundStart(2), GENESIS + 600);
        vm.expectRevert(HamsterOracle.InvalidRound.selector);
        game.roundStart(0);
    }

    function test_predictDuplicateAndInvalidInputsAndCounts() public {
        vm.expectEmit(true, true, false, true, address(game));
        emit PredictionPlaced(alice, 2, HamsterOracle.Outcome.SPRINT);
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.AlreadyPredicted.selector, uint64(2)));
        _pick(alice, 2, HamsterOracle.Outcome.NAP);
        _pick(bob, 2, HamsterOracle.Outcome.NAP);
        _pick(keeper, 2, HamsterOracle.Outcome.JOG);
        (uint256 nap, uint256 jog, uint256 sprint) = game.roundCounts(2);
        assertEq(nap, 1);
        assertEq(jog, 1);
        assertEq(sprint, 1);
        vm.expectRevert(HamsterOracle.InvalidRound.selector);
        game.predict(0, HamsterOracle.Outcome.NAP);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotFuture.selector, uint64(1)));
        game.predict(1, HamsterOracle.Outcome.NAP);
        (bool ok,) = address(game).call(abi.encodeWithSignature("predict(uint64,uint8)", uint64(3), uint8(3)));
        assertFalse(ok, "invalid enum accepted");
        assertEq(game.historyLength(address(this)), 0);
        _pick(alice, type(uint64).max, HamsterOracle.Outcome.NAP);
        assertEq(game.historyLength(alice), 2);
    }

    function test_settlementWaitsForCloseAndCertificationEvenAfterLongDelay() public {
        _pick(alice, 2, HamsterOracle.Outcome.NAP);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotClosed.selector, uint64(2)));
        game.settle(2);
        vm.warp(game.roundEnd(2) - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotClosed.selector, uint64(2)));
        game.settle(2);
        vm.warp(game.roundEnd(2) + 7 days);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotRecorded.selector, uint64(2), uint64(0)));
        game.settle(2);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotRecorded.selector, uint64(2), uint64(0)));
        game.roundWork(2);
        assertEq(_credit(alice), 0);
        assertEq(game.points(alice), 0);
        _assertPrediction(alice, 2, false, 0);
        core.record(2, 0);
        vm.expectEmit(true, false, false, true, address(game));
        emit RoundSettled(2, 0, HamsterOracle.Outcome.NAP);
        vm.prank(keeper);
        game.settle(2);
        assertEq(game.points(alice), 0, "settling only caches result");
        vm.expectEmit(true, true, false, true, address(game));
        emit PredictionScored(alice, 2, true, 1, 1, 1);
        assertEq(_credit(alice), 1);
        assertEq(game.points(alice), 1);
        assertEq(game.streak(alice), 1);
    }

    function test_sparseCertifiedGapsAreNapsAndCumulativeWorkIsNotRoundWork() public {
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        _pick(alice, 3, HamsterOracle.Outcome.NAP);
        _pick(alice, 4, HamsterOracle.Outcome.JOG);
        _close(5);
        core.record(2, 9000);
        core.record(4, 99);
        core.record(5, 0);
        assertEq(game.roundWork(2), 9000);
        assertEq(game.roundWork(3), 0);
        assertEq(game.roundWork(4), 99);
        assertEq(game.roundWork(5), 0);
        assertEq(_credit(alice), 3);
        assertEq(game.points(alice), 8); // 3 + (1+1) + (1+2)
        assertEq(game.streak(alice), 3);
    }

    function test_settlementAndScoringCannotReplayAndCachedResultsSurviveOutage() public {
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        _close(2);
        core.record(2, 100);
        game.settle(2);
        core.setUnavailable(true);
        vm.recordLogs();
        (uint64 work, HamsterOracle.Outcome outcome) = game.settle(2);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(work, 100);
        assertEq(uint256(outcome), 2);
        assertEq(game.roundWork(2), 100);
        assertEq(_credit(alice), 1);
        assertEq(_credit(alice), 0);
        assertEq(game.points(alice), 3);
        assertEq(game.streak(alice), 1);
        _assertPrediction(alice, 2, true, 3);
    }

    function test_chronologicalScoringForReversePlacedAndReverseSettledRounds() public {
        for (uint64 r = 10; r >= 2; --r) {
            _pick(alice, r, HamsterOracle.Outcome.SPRINT);
        }
        _close(10);
        for (uint64 r = 2; r <= 10; ++r) {
            core.record(r, 100);
        }
        for (uint64 r = 10; r >= 2; --r) {
            game.settle(r);
        }
        assertEq(game.checkpoint(alice, 2), 2);
        assertEq(game.points(alice), 7);
        assertEq(game.streak(alice), 2);
        (uint64 next, uint256 count) = game.pendingStatus(alice);
        assertEq(next, 4);
        assertEq(count, 7);
        assertEq(_credit(alice), 7);
        assertEq(game.points(alice), 57); // 3,4,5,6,7,8,8,8,8
        assertEq(game.streak(alice), 9);
        _assertPrediction(alice, 2, true, 3);
        _assertPrediction(alice, 10, true, 8);
        (, uint64 run, uint64 last, uint64 scoredCount) = game.players(alice);
        assertEq(run, 9);
        assertEq(last, 10);
        assertEq(scoredCount, 9);
    }

    function test_wrongPicksAndSkippedRoundIdsBreakStreak() public {
        _pick(alice, 2, HamsterOracle.Outcome.JOG);
        _pick(alice, 3, HamsterOracle.Outcome.SPRINT);
        _pick(alice, 4, HamsterOracle.Outcome.JOG);
        _pick(alice, 6, HamsterOracle.Outcome.SPRINT);
        _pick(alice, 7, HamsterOracle.Outcome.NAP);
        _close(7);
        core.record(2, 1);
        core.record(3, 99); // wrong
        core.record(4, 1);
        core.record(6, 10_000); // skipped round 5 resets the run
        core.record(7, 0);
        _credit(alice);
        _assertPrediction(alice, 2, true, 1);
        _assertPrediction(alice, 3, true, 0);
        _assertPrediction(alice, 4, true, 1);
        _assertPrediction(alice, 6, true, 3);
        _assertPrediction(alice, 7, true, 2);
        assertEq(game.points(alice), 7);
        assertEq(game.streak(alice), 2);
    }

    function test_lateInsertionOfEarlierFutureRoundCannotBeSkipped() public {
        _pick(alice, 4, HamsterOracle.Outcome.NAP);
        _pick(alice, 6, HamsterOracle.Outcome.NAP);
        _close(2);
        _pick(alice, 5, HamsterOracle.Outcome.NAP);
        _close(6);
        core.record(6, 0);
        _credit(alice);
        assertEq(game.points(alice), 6);
        assertEq(game.streak(alice), 3);
    }

    function test_checkpointIsBoundedStopsAtFrontierAndResumes() public {
        for (uint64 r = 2; r <= 35; ++r) {
            _pick(alice, r, HamsterOracle.Outcome.NAP);
        }
        assertEq(_credit(alice), 0);
        _close(35);
        core.record(10, 0);
        assertEq(_credit(alice), 9);
        assertEq(_credit(alice), 0);
        core.record(35, 0);
        assertEq(_credit(alice), 16);
        assertEq(_credit(alice), 9);
        assertEq(_credit(alice), 0);
        assertEq(game.points(alice), 189); // 1+2+3+4+5 + 29*6
        assertEq(game.streak(alice), 34);
        (uint64 next, uint256 count) = game.pendingStatus(alice);
        assertEq(next, 0);
        assertEq(count, 0);
        vm.expectRevert(HamsterOracle.InvalidBatchSize.selector);
        game.checkpoint(alice, 0);
        vm.expectRevert(HamsterOracle.InvalidBatchSize.selector);
        game.checkpoint(alice, 17);
        assertEq(_credit(bob), 0);
    }

    function test_pauseDoesNotInvalidateRecordedHistory() public {
        _pick(alice, 2, HamsterOracle.Outcome.NAP);
        _close(2);
        core.record(2, 0);
        core.setPaused(true);
        assertEq(_credit(alice), 1);
        assertEq(game.points(alice), 1);
    }

    function test_historyPaginationIncludesPicksSettlementAndScoringStatus() public {
        _pick(alice, 5, HamsterOracle.Outcome.JOG);
        _pick(alice, 2, HamsterOracle.Outcome.NAP);
        _pick(alice, 3, HamsterOracle.Outcome.SPRINT);
        _close(3);
        core.record(3, 100);
        game.settle(3);
        game.checkpoint(alice, 1);
        (HamsterOracle.HistoryEntry[] memory entries, uint256 next) = game.predictionHistory(alice, 0, 2);
        assertEq(next, 2);
        assertEq(entries.length, 2);
        assertEq(entries[0].roundId, 5);
        assertFalse(entries[0].prediction.scored);
        assertFalse(entries[0].result.settled);
        assertEq(entries[1].roundId, 2);
        assertTrue(entries[1].prediction.scored);
        assertTrue(entries[1].result.settled);
        (entries, next) = game.predictionHistory(alice, next, 100);
        assertEq(entries.length, 1);
        assertEq(next, 3);
        assertEq(entries[0].roundId, 3);
        assertTrue(entries[0].result.settled);
        assertFalse(entries[0].prediction.scored);
        (entries, next) = game.predictionHistory(alice, type(uint256).max, 100);
        assertEq(entries.length, 0);
        assertEq(next, 3);
        (entries, next) = game.predictionHistory(alice, 1, 0);
        assertEq(entries.length, 0);
        assertEq(next, 1);
        vm.expectRevert(HamsterOracle.InvalidHistoryPage.selector);
        game.predictionHistory(alice, 0, 101);
    }

    function test_paymentsAndAdministrativeSelectorsAreRejected() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool paid,) =
            address(game).call{value: 1}(abi.encodeCall(game.predict, (2, HamsterOracle.Outcome.NAP)));
        assertFalse(paid);
        vm.prank(alice);
        (bool sent,) = address(game).call{value: 1}("");
        assertFalse(sent);
        (bool owner,) = address(game).call(abi.encodeWithSignature("owner()"));
        (bool upgrade,) = address(game).call(abi.encodeWithSignature("upgradeTo(address)", alice));
        (bool overrideResult,) =
            address(game).call(abi.encodeWithSignature("setResult(uint64,uint64)", 2, 100));
        assertFalse(owner);
        assertFalse(upgrade);
        assertFalse(overrideResult);
        assertEq(address(game).balance, 0);
    }

    function test_chainGateAppliesToEveryMutationAndOracleRead() public {
        vm.chainId(1);
        vm.expectRevert(HamsterOracle.WrongChain.selector);
        game.predict(2, HamsterOracle.Outcome.NAP);
        vm.expectRevert(HamsterOracle.WrongChain.selector);
        game.settle(2);
        vm.expectRevert(HamsterOracle.WrongChain.selector);
        game.checkpoint(alice, 1);
        vm.expectRevert(HamsterOracle.WrongChain.selector);
        game.roundWork(2);
    }

    function test_zeroRoundAndUnrepresentableTimestampFailClearly() public {
        vm.expectRevert(HamsterOracle.InvalidRound.selector);
        game.settle(0);
        vm.expectRevert(HamsterOracle.InvalidRound.selector);
        game.roundWork(0);
        vm.warp(type(uint256).max);
        vm.expectRevert(HamsterOracle.UnsupportedTimestamp.selector);
        game.currentRound();
    }
}
