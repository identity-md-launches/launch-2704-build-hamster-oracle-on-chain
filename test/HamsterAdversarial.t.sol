// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HamsterTestBase, HamsterOracle, ISqueekCore} from "./HamsterTestBase.sol";

contract RejectingPlayerWallet {
    function predict(HamsterOracle game, uint64 roundId, HamsterOracle.Outcome pick) external {
        game.predict(roundId, pick);
    }

    fallback() external payable {
        revert("wallet rejects callbacks and payments");
    }

    receive() external payable {
        revert("wallet rejects payments");
    }
}

contract HamsterAdversarialTest is HamsterTestBase {
    event RoundSettled(uint64 indexed roundId, uint64 work, HamsterOracle.Outcome outcome);
    event PredictionScored(
        address indexed player, uint64 indexed roundId, bool correct, uint8 awarded,
        uint256 totalPoints, uint64 streak
    );

    function test_wrongPickEmitsScoreAndCannotBeSkippedByKeeper() public {
        _pick(alice, 4, HamsterOracle.Outcome.JOG);
        _pick(alice, 3, HamsterOracle.Outcome.SPRINT);
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        _pick(bob, 2, HamsterOracle.Outcome.NAP);
        _close(4);
        core.record(2, 100);
        core.record(4, 99);

        vm.expectEmit(true, false, false, true, address(game));
        emit RoundSettled(2, 100, HamsterOracle.Outcome.SPRINT);
        vm.expectEmit(true, true, false, true, address(game));
        emit PredictionScored(alice, 2, true, 3, 3, 1);
        vm.expectEmit(true, false, false, true, address(game));
        emit RoundSettled(3, 0, HamsterOracle.Outcome.NAP);
        vm.expectEmit(true, true, false, true, address(game));
        emit PredictionScored(alice, 3, false, 0, 3, 0);
        vm.expectEmit(true, false, false, true, address(game));
        emit RoundSettled(4, 99, HamsterOracle.Outcome.JOG);
        vm.expectEmit(true, true, false, true, address(game));
        emit PredictionScored(alice, 4, true, 1, 4, 1);
        vm.prank(keeper);
        assertEq(game.checkpoint(alice, 16), 3);
        assertEq(game.points(alice), 4);
        assertEq(game.streak(alice), 1);
        assertEq(game.points(keeper), 0, "keeper redirected credit");
        assertEq(game.historyLength(keeper), 0);
        _assertPrediction(bob, 2, false, 0);
        assertEq(game.points(bob), 0, "another player's checkpoint scored Bob");
        vm.recordLogs();
        assertEq(game.checkpoint(alice, 16), 0);
        game.settle(3);
        assertEq(vm.getRecordedLogs().length, 0, "replay produced duplicate events");
    }

    function test_contractWalletOwnsPickAndRejectingCallbacksCannotBlockCredit() public {
        RejectingPlayerWallet wallet = new RejectingPlayerWallet();
        vm.prank(alice, alice);
        wallet.predict(game, 2, HamsterOracle.Outcome.SPRINT);
        assertEq(game.historyLength(alice), 0, "prediction was attributed to tx.origin");
        assertEq(game.historyLength(address(wallet)), 1);
        _close(2);
        core.record(2, 100);
        vm.prank(bob, alice);
        assertEq(game.checkpoint(address(wallet), 1), 1);
        assertEq(game.points(address(wallet)), 3);
        assertEq(game.points(alice), 0);
        assertEq(game.points(bob), 0);
        assertEq(game.leaderboard()[0].player, address(wallet));
    }

    function test_valueBearingCallsRejectWithoutConsumingPredictionOrQueue() public {
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        vm.deal(alice, 1 ether);
        bytes32 beforeState = _snapshot(alice);
        vm.prank(alice);
        (bool ok,) = address(game).call{value: 1}(
            abi.encodeCall(HamsterOracle.predict, (3, HamsterOracle.Outcome.NAP))
        );
        assertFalse(ok);
        assertEq(_snapshot(alice), beforeState);
        _close(2);
        core.record(2, 100);
        beforeState = _snapshot(alice);
        vm.prank(alice);
        (ok,) = address(game).call{value: 1}(abi.encodeCall(HamsterOracle.settle, (2)));
        assertFalse(ok);
        vm.prank(alice);
        (ok,) = address(game).call{value: 1}(abi.encodeCall(HamsterOracle.checkpoint, (alice, 16)));
        assertFalse(ok);
        assertEq(_snapshot(alice), beforeState);
        assertEq(address(game).balance, 0);
        assertEq(alice.balance, 1 ether);
        assertEq(_credit(alice), 1);
        assertEq(game.points(alice), 3);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_rejectedDuplicateLeavesEveryObservableUnchanged(uint8 replacementSeed) public {
        _pick(alice, 3, HamsterOracle.Outcome.JOG);
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        bytes32 beforeState = _snapshot(alice);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.AlreadyPredicted.selector, uint64(2)));
        _pick(alice, 2, HamsterOracle.Outcome(replacementSeed % 3));
        assertEq(_snapshot(alice), beforeState);
        _close(3);
        core.record(2, 100);
        core.record(3, 99);
        assertEq(_credit(alice), 2);
        assertEq(game.points(alice), 5, "failed replacement changed the original pick");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_invalidEnumEncodingCannotCreateOrCorruptPrediction(uint256 invalidSeed) public {
        _pick(alice, 2, HamsterOracle.Outcome.JOG);
        uint256 invalid = bound(invalidSeed, 3, type(uint256).max);
        bytes32 beforeState = _snapshot(alice);
        vm.prank(alice);
        (bool ok,) = address(game).call(
            abi.encodeWithSelector(HamsterOracle.predict.selector, uint256(3), invalid)
        );
        assertFalse(ok, "out-of-range outcome accepted");
        assertEq(_snapshot(alice), beforeState);
        (, bool exists,,) = game.predictions(alice, 3);
        assertFalse(exists);
    }

    function test_roundIdAbiOverflowIsRejectedRatherThanTruncatedToFutureRound() public {
        uint256 overflowing = (uint256(1) << 64) + 2;
        vm.prank(alice);
        (bool ok,) = address(game).call(
            abi.encodeWithSelector(HamsterOracle.predict.selector, overflowing, uint256(0))
        );
        assertFalse(ok);
        assertEq(game.historyLength(alice), 0);
        (uint256 nap, uint256 jog, uint256 sprint) = game.roundCounts(2);
        assertEq(nap + jog + sprint, 0);
        _pick(alice, 2, HamsterOracle.Outcome.NAP);
        assertEq(game.historyLength(alice), 1);
    }

    /// @dev An outage must not make future-only or empty queues need the oracle.
    function test_emptyAndFutureQueuesDoNotCallUnavailableOracle() public {
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        core.setUnavailable(true);
        assertEq(game.checkpoint(alice, 16), 0);
        assertEq(game.checkpoint(bob, 16), 0);
        _pick(bob, 3, HamsterOracle.Outcome.NAP);
        assertEq(game.checkpoint(bob, 16), 0);
        (uint64 next, uint256 pending) = game.pendingStatus(alice);
        assertEq(next, 2);
        assertEq(pending, 1);
    }

    /// @dev Start with a real positive score, then corrupt a later batch's second
    /// page. All tentative credits, cached rounds, history and ranking must roll back.
    function test_failedLaterBatchPreservesExistingScoreLeaderboardAndQueue() public {
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        _pick(alice, 3, HamsterOracle.Outcome.NAP);
        _pick(alice, 4, HamsterOracle.Outcome.JOG);
        _close(4);
        core.record(2, 100);
        core.record(4, 99);
        assertEq(game.checkpoint(alice, 1), 1);
        bytes32 beforeState = _snapshot(alice);
        ISqueekCore.RoundPage memory bad = core.roundPage(3, 4, 1);
        bad.rounds[0].dataHash = bytes32(0);
        vm.mockCall(CORE, abi.encodeCall(ISqueekCore.roundPage, (3, 4, 1)), abi.encode(bad));
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.InvalidCorePage.selector, uint64(4)));
        game.checkpoint(alice, 16);
        assertEq(_snapshot(alice), beforeState, "partial batch leaked state");
        vm.clearMockedCalls();
        assertEq(game.checkpoint(alice, 16), 2);
        assertEq(game.points(alice), 8);
        assertEq(game.streak(alice), 3);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_allThreeOracleReadAbisRejectTruncationAndRecover(uint8 targetSeed, uint16 cutSeed)
        public
    {
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        _close(2);
        core.record(2, 100);
        uint256 target = targetSeed % 3;
        bytes memory callData;
        bytes memory result;
        if (target == 0) {
            callData = abi.encodeCall(ISqueekCore.configuration, ());
            result = abi.encode(core.configuration());
        } else if (target == 1) {
            callData = abi.encodeCall(ISqueekCore.state, ());
            result = abi.encode(core.state());
        } else {
            callData = abi.encodeCall(ISqueekCore.roundPage, (1, 2, 1));
            result = abi.encode(core.roundPage(1, 2, 1));
        }
        uint256 cut = bound(cutSeed, 0, result.length - 1);
        assembly ("memory-safe") { mstore(result, cut) }
        bytes32 beforeState = _snapshot(alice);
        vm.mockCall(CORE, callData, result);
        vm.expectRevert();
        game.roundWork(2);
        vm.expectRevert();
        game.settle(2);
        vm.expectRevert();
        game.checkpoint(alice, 16);
        assertEq(_snapshot(alice), beforeState);
        vm.clearMockedCalls();
        assertEq(_credit(alice), 1);
        assertEq(game.points(alice), 3);
    }

    function test_uncertifiedEmptyPageCannotBeUsedAsEvidenceOfNap() public {
        _pick(alice, 2, HamsterOracle.Outcome.NAP);
        _close(2);
        ISqueekCore.RoundPage memory fake;
        fake.certifiedThroughRound = 2;
        fake.rounds = new ISqueekCore.RoundCheckpoint[](0);
        vm.mockCall(CORE, abi.encodeCall(ISqueekCore.roundPage, (1, 2, 1)), abi.encode(fake));
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotRecorded.selector, uint64(2), uint64(0)));
        game.settle(2);
        assertEq(game.checkpoint(alice, 16), 0);
        _assertPrediction(alice, 2, false, 0);
        assertEq(game.points(alice), 0);
        vm.clearMockedCalls();
        core.record(2, 0);
        assertEq(_credit(alice), 1);
        assertEq(game.points(alice), 1);
    }

    function _snapshot(address player) private view returns (bytes32) {
        bytes memory data = abi.encode(
            _read(abi.encodeCall(game.players, (player))),
            _read(abi.encodeCall(HamsterOracle.predictionHistory, (player, 0, 100))),
            _read(abi.encodeCall(HamsterOracle.pendingStatus, (player))),
            game.leaderboard()
        );
        for (uint64 r = 2; r <= 4; ++r) {
            data = abi.encode(data, _read(abi.encodeCall(HamsterOracle.roundCounts, (r))),
                _read(abi.encodeCall(game.rounds, (r))));
        }
        return keccak256(data);
    }

    function _read(bytes memory callData) private view returns (bytes memory result) {
        bool ok;
        (ok, result) = address(game).staticcall(callData);
        require(ok, "snapshot view failed");
    }
}
