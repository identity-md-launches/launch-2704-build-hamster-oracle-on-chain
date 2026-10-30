// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterOracle} from "../../src/HamsterOracle.sol";
import {ISqueekCore} from "../../src/interfaces/ISqueekCore.sol";
import {Preflight} from "../../script/Preflight.s.sol";

/// @notice Opt-in live RPC integration: forge test --profile fork -vv
/// No environment variables, mocked responses, etching, or source-storage edits.
/// Default offline tests exclude this directory; failed RPC calls fail this suite.
contract HamsterOracleForkTest is Test {
    uint256 internal constant PREDICTION_BLOCK = 12_020_000;
    uint256 internal constant RECORDED_BLOCK = 12_025_393;
    address internal constant CORE = 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44;
    address internal constant IMPLEMENTATION = 0x284747C4664AF2203E7A90a2Ee76f22b6B5e6889;
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    ISqueekCore internal constant core = ISqueekCore(CORE);

    function testFork_readOnlyDeploymentPreflight() public {
        Preflight.Report memory report = new Preflight().run();
        assertEq(report.core, CORE);
        assertEq(report.defaultThreshold, 100);
        assertEq(report.implementation, IMPLEMENTATION);
    }

    function testFork_verifiedAbiAndSingleRoundPagesAgainstLiveProxy() public {
        vm.rollFork(RECORDED_BLOCK);
        assertEq(block.chainid, 11_155_111);
        assertGt(CORE.code.length, 0);
        assertEq(address(uint160(uint256(vm.load(CORE, IMPLEMENTATION_SLOT)))), IMPLEMENTATION);
        ISqueekCore.CoreConfiguration memory config = core.configuration();
        assertEq(config.genesisTimestamp, 1_793_022_600);
        assertEq(config.roundDuration, 600);
        assertEq(config.maxWorkPerRound, 10_000);
        ISqueekCore.CoreState memory state = core.state();
        assertEq(state.settledThroughRound, 542);
        assertEq(state.cumulativeWork, 45_957);
        HamsterOracle game = new HamsterOracle(100);
        assertEq(game.roundWork(44), 0);
        assertEq(game.roundWork(45), 170);
        assertEq(game.roundWork(46), 694);
        assertEq(game.roundWork(54), 0);
        assertEq(game.roundWork(57), 65);
        ISqueekCore.RoundPage memory page = core.roundPage(44, 46, 1);
        assertEq(page.certifiedThroughRound, 45, "truncated pages stop before the missing record");
        assertEq(page.rounds.length, 1);
        (uint64 work, HamsterOracle.Outcome outcome) = game.settle(57);
        assertEq(work, 65);
        assertEq(uint256(outcome), uint256(HamsterOracle.Outcome.JOG));
    }

    function testFork_predictionsSurviveRollToActualRecordedResultsAndScore() public {
        vm.rollFork(PREDICTION_BLOCK);
        assertEq(block.timestamp, 1_793_282_820);
        HamsterOracle game = new HamsterOracle(100);
        vm.makePersistent(address(game));
        address player = makeAddr("fork-player");
        assertEq(game.currentRound(), 434);
        vm.startPrank(player);
        game.predict(502, HamsterOracle.Outcome.SPRINT);
        game.predict(501, HamsterOracle.Outcome.SPRINT);
        game.predict(503, HamsterOracle.Outcome.NAP);
        game.predict(507, HamsterOracle.Outcome.NAP);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotClosed.selector, uint64(501)));
        game.settle(501);

        vm.rollFork(RECORDED_BLOCK);
        // Uses the real upstream state at both block heights. No manufactured reports.
        game.settle(502);
        game.settle(501);
        assertEq(game.checkpoint(player, 16), 4);
        assertEq(game.points(player), 11); // 3 + 4 + 3 + 1 (gap before round 507)
        assertEq(game.streak(player), 1);
        assertEq(game.checkpoint(player, 16), 0);
        assertEq(game.leaderboard()[0].player, player);
    }

    function testFork_certifiedFrontierIsDistinctFromWallClock() public {
        vm.rollFork(RECORDED_BLOCK);
        HamsterOracle game = new HamsterOracle(100);
        uint64 unknown = core.state().settledThroughRound + 1;
        // Advance local time only: the live pinned reporter frontier stays unchanged.
        vm.warp(game.roundEnd(unknown) + 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(HamsterOracle.RoundNotRecorded.selector, unknown, uint64(unknown - 1))
        );
        game.settle(unknown);
        (,, bool settled) = game.rounds(unknown);
        assertFalse(settled);
    }
}

