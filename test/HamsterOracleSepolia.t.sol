// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterOracle} from "src/HamsterOracle.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";
import {Preflight} from "../script/Preflight.s.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";

/// @notice Included by the default profile. Every test forks the assignment's
/// one pinned block; an unavailable configured endpoint must fail, not skip.
contract HamsterOracleSepoliaTest is Test {
    uint256 internal constant PINNED_BLOCK = 12_025_524;
    address internal constant CORE = 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44;
    address internal constant IMPLEMENTATION = 0x284747C4664AF2203E7A90a2Ee76f22b6B5e6889;
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    ISqueekCore internal constant core = ISqueekCore(CORE);

    modifier pinnedSepolia() {
        string memory url = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url, PINNED_BLOCK);
        assertEq(block.chainid, 11_155_111);
        assertEq(block.number, PINNED_BLOCK);
        assertGt(CORE.code.length, 0, "fork did not load the real proxy");
        _;
    }

    function testFork_readOnlyDeploymentPreflight() public pinnedSepolia {
        Preflight.Report memory report = new Preflight().run();
        assertEq(report.chainId, 11_155_111);
        assertEq(report.core, CORE);
        assertEq(report.defaultThreshold, 100);
        assertEq(report.implementation, IMPLEMENTATION);
        assertEq(address(uint160(uint256(vm.load(CORE, IMPLEMENTATION_SLOT)))), IMPLEMENTATION);
        assertEq(report.version, 3);
        assertLt(report.state.settledThroughRound, report.currentRound);
    }

    function testFork_verifiedAbiAndKnownActiveAndSparseRounds() public pinnedSepolia {
        ISqueekCore.CoreConfiguration memory config = core.configuration();
        assertEq(config.genesisTimestamp, 1_793_022_600);
        assertEq(config.roundDuration, 600);
        assertEq(config.maxWorkPerRound, 10_000);
        ISqueekCore.CoreState memory state = core.state();
        assertEq(state.settledThroughRound, 544);
        assertEq(state.cumulativeWork, 45_957);

        HamsterOracle game = new HamsterOracle(100);
        uint64[9] memory ids = [uint64(44), 45, 46, 54, 57, 501, 502, 503, 507];
        uint64[9] memory values = [uint64(0), 170, 694, 0, 65, 554, 336, 0, 0];
        for (uint256 i; i < ids.length; ++i) {
            assertEq(game.roundWork(ids[i]), values[i], "historical per-round work mismatch");
            (uint64 work, HamsterOracle.Outcome outcome) = game.settle(ids[i]);
            assertEq(work, values[i]);
            assertEq(uint256(outcome), values[i] == 0 ? 0 : (values[i] < 100 ? 1 : 2));
        }

        ISqueekCore.RoundPage memory page = core.roundPage(44, 46, 1);
        assertEq(page.certifiedThroughRound, 45, "record budget must truncate the certified interval");
        assertEq(page.rounds.length, 1);
        assertEq(page.rounds[0].roundId, 45);
        assertEq(page.end.cumulativeWork - page.start.cumulativeWork, 170);
        page = core.roundPage(56, 57, 1);
        assertEq(page.end.cumulativeWork - page.start.cumulativeWork, 65);
        assertGt(page.end.cumulativeWork, 65, "fixture must distinguish cumulative from round work");
    }

    /// @dev Reconstruct work from the real multi-round pages, then compare the
    /// game and its mock to that ledger for EVERY certified round. This exercises
    /// leading, interior and trailing implicit-zero spans and pagination progress.
    function testFork_entireCertifiedLedgerAgreesWithGameAndMock() public pinnedSepolia {
        ISqueekCore.CoreState memory state = core.state();
        assertGt(state.settledThroughRound, 507, "nonempty historical fixture required");
        MockSqueekCore replay = new MockSqueekCore();
        replay.initializeMock();
        uint64[] memory expected = new uint64[](uint256(state.settledThroughRound) + 1);
        uint64 cursor;
        uint64 cumulative;
        uint64 lastActive;
        uint256 active;
        while (cursor < state.settledThroughRound) {
            ISqueekCore.RoundPage memory page = core.roundPage(cursor, state.settledThroughRound, 16);
            assertGt(page.certifiedThroughRound, cursor, "pagination stalled");
            assertLe(page.certifiedThroughRound, state.settledThroughRound);
            assertEq(page.start.cumulativeWork, cumulative, "page discontinuity");
            assertLe(page.rounds.length, 16);
            for (uint256 i; i < page.rounds.length; ++i) {
                ISqueekCore.RoundCheckpoint memory record = page.rounds[i];
                assertGt(record.roundId, lastActive);
                assertGt(record.roundId, cursor);
                assertLe(record.roundId, page.certifiedThroughRound);
                uint64 value = record.cumulativeWork - cumulative;
                assertGt(value, 0);
                assertLe(value, 10_000);
                assertNotEq(record.dataHash, bytes32(0));
                expected[record.roundId] = value;
                replay.record(record.roundId, value);
                cumulative = record.cumulativeWork;
                lastActive = record.roundId;
                ++active;
            }
            assertEq(page.end.cumulativeWork, cumulative);
            cursor = page.certifiedThroughRound;
        }
        if (lastActive < state.settledThroughRound) replay.record(state.settledThroughRound, 0);
        assertEq(cumulative, state.cumulativeWork);
        assertGt(active, 16, "must traverse multiple active-record pages");

        HamsterOracle game = new HamsterOracle(100);
        uint256 naps;
        uint256 jogs;
        uint256 sprints;
        for (uint64 r = 1; r <= state.settledThroughRound; ++r) {
            ISqueekCore.RoundPage memory mockPage = replay.roundPage(r - 1, r, 1);
            assertEq(mockPage.certifiedThroughRound, r);
            assertEq(mockPage.end.cumulativeWork - mockPage.start.cumulativeWork, expected[r]);
            assertEq(mockPage.rounds.length, expected[r] == 0 ? 0 : 1);
            (uint64 work, HamsterOracle.Outcome outcome) = game.settle(r);
            assertEq(work, expected[r], "single-round game read disagrees with bulk ledger");
            if (expected[r] == 0) {
                assertEq(uint256(outcome), uint256(HamsterOracle.Outcome.NAP));
                ++naps;
            } else if (expected[r] < 100) {
                assertEq(uint256(outcome), uint256(HamsterOracle.Outcome.JOG));
                ++jogs;
            } else {
                assertEq(uint256(outcome), uint256(HamsterOracle.Outcome.SPRINT));
                ++sprints;
            }
        }
        assertGt(naps, 0);
        assertGt(jogs, 0);
        assertGt(sprints, 0);
        assertEq(naps + jogs + sprints, state.settledThroughRound);
    }

    function testFork_futurePredictionsCloseButElapsedTimeCannotInventResults() public pinnedSepolia {
        HamsterOracle game = new HamsterOracle(100);
        address player = makeAddr("sepolia-future-player");
        address observer = makeAddr("sepolia-permissionless-observer");
        uint64 frontier = core.state().settledThroughRound;
        uint64 future = game.currentRound() + 1;
        vm.prank(player);
        game.predict(future, HamsterOracle.Outcome.NAP);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotClosed.selector, future));
        game.settle(future);

        // Local time can advance; the oracle remains the genuine pinned state.
        vm.warp(game.roundStart(future));
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotFuture.selector, future));
        vm.prank(observer);
        game.predict(future, HamsterOracle.Outcome.NAP);
        vm.warp(game.roundEnd(future) + 30 days);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotRecorded.selector, future, frontier));
        game.settle(future);
        vm.expectRevert(abi.encodeWithSelector(HamsterOracle.RoundNotRecorded.selector, future, frontier));
        game.roundWork(future);
        vm.prank(observer);
        assertEq(game.checkpoint(player, 16), 0);
        assertEq(game.points(player), 0);
        assertEq(game.streak(player), 0);
        assertEq(game.leaderboard().length, 0);
        (, bool exists, bool scored, uint8 award) = game.predictions(player, future);
        assertTrue(exists);
        assertFalse(scored);
        assertEq(award, 0);
        (uint64 next, uint256 pending) = game.pendingStatus(player);
        assertEq(next, future);
        assertEq(pending, 1);
        (,, bool settled) = game.rounds(future);
        assertFalse(settled);
        assertEq(core.state().settledThroughRound, frontier);
        assertEq(block.number, PINNED_BLOCK);
    }

    function testFork_liveWorkUsesImmutableThresholdAndSettlementCannotReplay() public pinnedSepolia {
        HamsterOracle sprintGame = new HamsterOracle(1);
        HamsterOracle jogGame = new HamsterOracle(10_000);
        (uint64 work, HamsterOracle.Outcome outcome) = sprintGame.settle(57);
        assertEq(work, 65);
        assertEq(uint256(outcome), uint256(HamsterOracle.Outcome.SPRINT));
        (work, outcome) = jogGame.settle(57);
        assertEq(work, 65);
        assertEq(uint256(outcome), uint256(HamsterOracle.Outcome.JOG));
        vm.recordLogs();
        (work, outcome) = sprintGame.settle(57);
        assertEq(vm.getRecordedLogs().length, 0, "duplicate settlement emitted an event");
        assertEq(work, 65);
        assertEq(uint256(outcome), uint256(HamsterOracle.Outcome.SPRINT));
        assertEq(sprintGame.roundWork(57), 65);
        assertEq(sprintGame.leaderboard().length, 0);
    }
}
