// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HamsterTestBase, HamsterOracle, ISqueekCore} from "./HamsterTestBase.sol";

contract OracleFailuresTest is HamsterTestBase {
    function test_unavailableOracleRollsBackWithoutInventingNap() public {
        _pick(alice, 2, HamsterOracle.Outcome.NAP);
        _close(2);
        core.setUnavailable(true);
        vm.expectRevert("core unavailable");
        game.settle(2);
        vm.expectRevert("core unavailable");
        game.checkpoint(alice, 1);
        (,, bool settled) = game.rounds(2);
        assertFalse(settled);
        assertEq(game.points(alice), 0);
        _assertPrediction(alice, 2, false, 0);
        (uint64 next, uint256 count) = game.pendingStatus(alice);
        assertEq(next, 2);
        assertEq(count, 1);
        core.setUnavailable(false);
        core.record(2, 0);
        assertEq(_credit(alice), 1);
    }

    function test_mismatchedClockOrCapAndFutureFrontierRejected() public {
        _close(2);
        core.record(2, 100);
        ISqueekCore.CoreConfiguration memory original = core.configuration();
        ISqueekCore.CoreConfiguration memory bad = core.configuration();
        bad.genesisTimestamp += 1;
        core.setConfiguration(bad);
        _expectIncompatible();
        bad.genesisTimestamp = original.genesisTimestamp;
        bad.roundDuration = 601;
        core.setConfiguration(bad);
        _expectIncompatible();
        bad.roundDuration = original.roundDuration;
        bad.maxWorkPerRound = 10_001;
        core.setConfiguration(bad);
        _expectIncompatible();
        core.setConfiguration(original);
        ISqueekCore.CoreState memory state = core.state();
        state.settledThroughRound = 3;
        core.setState(state);
        _expectIncompatible();
    }

    function testFuzz_rejectMalformedPageWithoutPartialSettlement(uint8 modeSeed) public {
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        _close(2);
        core.record(2, 100);
        ISqueekCore.RoundPage memory page = core.roundPage(1, 2, 1);
        uint256 mode = modeSeed % 10;
        if (mode == 0) page.certifiedThroughRound = 1;
        if (mode == 1) page.start.cumulativeWork = page.end.cumulativeWork + 1;
        if (mode == 2) page.end.cumulativeWork = 101;
        if (mode == 3) page.rounds = new ISqueekCore.RoundCheckpoint[](2);
        if (mode == 4) page.rounds = new ISqueekCore.RoundCheckpoint[](0);
        if (mode == 5) page.rounds[0].roundId = 1;
        if (mode == 6) page.rounds[0].cumulativeWork = 99;
        if (mode == 7) page.rounds[0].dataHash = bytes32(0);
        if (mode == 8) page.start.cumulativeWork = page.end.cumulativeWork;
        if (mode == 9) {
            page.end.cumulativeWork = 10_001;
            page.rounds[0].cumulativeWork = 10_001;
            ISqueekCore.CoreState memory state = core.state();
            state.cumulativeWork = 10_001;
            core.setState(state);
        }
        vm.mockCall(CORE, abi.encodeCall(ISqueekCore.roundPage, (1, 2, 1)), abi.encode(page));
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.InvalidCorePage.selector, uint64(2)));
        game.checkpoint(alice, 1);
        assertEq(game.points(alice), 0);
        _assertPrediction(alice, 2, false, 0);
        (,, bool settled) = game.rounds(2);
        assertFalse(settled);
    }

    function test_badSecondPageRollsBackWholeBatchAndSmallBatchCanStillProgress() public {
        _pick(alice, 2, HamsterOracle.Outcome.NAP);
        _pick(alice, 3, HamsterOracle.Outcome.NAP);
        _close(3);
        core.record(3, 0);
        ISqueekCore.RoundPage memory page = core.roundPage(2, 3, 1);
        page.certifiedThroughRound = 2;
        vm.mockCall(CORE, abi.encodeCall(ISqueekCore.roundPage, (2, 3, 1)), abi.encode(page));
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.InvalidCorePage.selector, uint64(3)));
        game.checkpoint(alice, 2);
        assertEq(game.points(alice), 0);
        _assertPrediction(alice, 2, false, 0);
        (,, bool settled) = game.rounds(2);
        assertFalse(settled);
        assertEq(game.checkpoint(alice, 1), 1);
        assertEq(game.points(alice), 1);
        vm.clearMockedCalls();
        assertEq(game.checkpoint(alice, 1), 1);
        assertEq(game.points(alice), 3);
    }

    function test_truncatedAbiResponseAndMissingCodeFailClosed() public {
        _close(2);
        core.record(2, 100);
        vm.mockCall(CORE, abi.encodeCall(ISqueekCore.roundPage, (1, 2, 1)), hex"01");
        vm.expectRevert();
        game.settle(2);
        vm.clearMockedCalls();
        vm.etch(CORE, hex"");
        vm.expectRevert();
        game.settle(2);
        (,, bool settled) = game.rounds(2);
        assertFalse(settled);
    }

    function test_cachedResultCannotBeChangedBySubsequentOracleResponse() public {
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        _close(2);
        core.record(2, 100);
        game.settle(2);
        ISqueekCore.RoundPage memory empty;
        empty.certifiedThroughRound = 2;
        empty.rounds = new ISqueekCore.RoundCheckpoint[](0);
        vm.mockCall(CORE, abi.encodeCall(ISqueekCore.roundPage, (1, 2, 1)), abi.encode(empty));
        assertEq(game.roundWork(2), 100);
        _credit(alice);
        assertEq(game.points(alice), 3);
    }

    function _expectIncompatible() private {
        vm.expectRevert(HamsterOracle.IncompatibleCore.selector);
        game.settle(2);
    }
}
