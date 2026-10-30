// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterTestBase, HamsterOracle} from "./HamsterTestBase.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";

contract GameHandler is Test {
    struct ModelPrediction {
        bool exists;
        uint8 pick;
        bool scored;
        uint8 awarded;
    }

    HamsterOracle public immutable game;
    MockSqueekCore public immutable core;
    address[4] public wallets;
    uint64 public frontier;
    mapping(uint64 => uint64) public work;
    mapping(address => uint64[]) private _rounds;
    mapping(address => mapping(uint64 => ModelPrediction)) public model;
    mapping(address => uint256) public expectedPoints;
    mapping(address => uint64) public expectedStreak;
    mapping(address => uint64) public expectedLast;
    mapping(address => uint64) public expectedScored;
    mapping(uint64 => uint256[3]) public counts;

    constructor(HamsterOracle game_, MockSqueekCore core_) {
        game = game_;
        core = core_;
        for (uint256 i; i < wallets.length; ++i) {
            wallets[i] = address(uint160(10_000 + i));
        }
    }

    function predict(uint8 who, uint8 ahead, uint8 pickSeed) external {
        address player = wallets[who % 4];
        uint64 r = game.currentRound() + 1 + ahead % 8;
        if (model[player][r].exists) return;
        uint8 pick = pickSeed % 3;
        vm.prank(player);
        game.predict(r, HamsterOracle.Outcome(pick));
        model[player][r] = ModelPrediction(true, pick, false, 0);
        _rounds[player].push(r);
        ++counts[r][pick];
    }

    function advance(uint16 elapsed) external {
        vm.warp(block.timestamp + elapsed % 1801);
    }

    function report(uint8 distance, uint16 workSeed) external {
        uint64 closed = game.currentRound() - 1;
        if (closed <= frontier) return;
        uint64 next = frontier + 1 + uint64(distance) % (closed - frontier);
        uint64 value = workSeed % 4 == 0 ? 0 : uint64(workSeed % 10_001);
        core.record(next, value);
        work[next] = value;
        frontier = next;
    }

    function settle(uint64 roundSeed) external {
        if (frontier == 0) return;
        uint64 r = 1 + roundSeed % frontier;
        game.settle(r);
    }

    function checkpoint(uint8 who, uint8 size) external {
        address player = wallets[who % 4];
        uint256 batch = 1 + size % 16;
        uint256 expected;
        for (; expected < batch; ++expected) {
            uint64 next = _next(player);
            if (next == 0 || next > frontier) break;
            ModelPrediction storage prediction = model[player][next];
            uint8 result = work[next] == 0 ? 0 : (work[next] < 100 ? 1 : 2);
            if (prediction.pick == result) {
                uint64 run = next == expectedLast[player] + 1 ? expectedStreak[player] + 1 : 1;
                expectedStreak[player] = run;
                prediction.awarded = uint8((result == 2 ? 3 : 1) + (run > 6 ? 5 : run - 1));
                expectedPoints[player] += prediction.awarded;
            } else {
                expectedStreak[player] = 0;
            }
            prediction.scored = true;
            expectedLast[player] = next;
            ++expectedScored[player];
        }
        assertEq(game.checkpoint(player, batch), expected, "model progress mismatch");
    }

    function _next(address player) private view returns (uint64 next) {
        uint64[] storage rounds = _rounds[player];
        for (uint256 i; i < rounds.length; ++i) {
            uint64 r = rounds[i];
            if (!model[player][r].scored && (next == 0 || r < next)) next = r;
        }
    }

    function assertAccounting() external view {
        for (uint256 i; i < wallets.length; ++i) {
            address player = wallets[i];
            (uint256 points, uint64 streak, uint64 last, uint64 scored) = game.players(player);
            assertEq(points, expectedPoints[player], "points mismatch");
            assertEq(streak, expectedStreak[player], "streak mismatch");
            assertEq(last, expectedLast[player], "last scored mismatch");
            assertEq(scored, expectedScored[player], "scored count mismatch");
            assertLe(points, uint256(scored) * 8, "excess points");
            assertEq(game.historyLength(player), _rounds[player].length);
            (uint64 next, uint256 pending) = game.pendingStatus(player);
            assertEq(next, _next(player), "heap minimum mismatch");
            assertEq(pending + scored, _rounds[player].length, "lost prediction");
            for (uint256 j; j < _rounds[player].length; ++j) {
                uint64 r = _rounds[player][j];
                ModelPrediction memory expected = model[player][r];
                (HamsterOracle.Outcome pick, bool exists, bool done, uint8 awarded) =
                    game.predictions(player, r);
                assertTrue(exists);
                assertEq(uint256(pick), expected.pick);
                assertEq(done, expected.scored);
                assertEq(awarded, expected.awarded);
                (uint256 nap, uint256 jog, uint256 sprint) = game.roundCounts(r);
                assertEq(nap, counts[r][0]);
                assertEq(jog, counts[r][1]);
                assertEq(sprint, counts[r][2]);
            }
        }
    }

    function assertLeaderboard() external view {
        HamsterOracle.LeaderboardEntry[] memory entries = game.leaderboard();
        uint256 positive;
        for (uint256 i; i < 4; ++i) {
            if (expectedPoints[wallets[i]] > 0) ++positive;
        }
        assertEq(entries.length, positive);
        for (uint256 i; i < entries.length; ++i) {
            assertEq(entries[i].points, expectedPoints[entries[i].player]);
            assertGt(entries[i].points, 0);
            if (i > 0) {
                assertGe(entries[i - 1].points, entries[i].points);
                if (entries[i - 1].points == entries[i].points) {
                    assertLt(uint160(entries[i - 1].player), uint160(entries[i].player));
                }
            }
            for (uint256 j = i + 1; j < entries.length; ++j) {
                assertNotEq(entries[i].player, entries[j].player);
            }
        }
    }
}

contract HamsterOracleInvariantTest is HamsterTestBase {
    GameHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new GameHandler(game, core);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = GameHandler.predict.selector;
        selectors[1] = GameHandler.advance.selector;
        selectors[2] = GameHandler.report.selector;
        selectors[3] = GameHandler.settle.selector;
        selectors[4] = GameHandler.checkpoint.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_scoringCountsHistoryAndQueueAgreeWithReference() public view {
        handler.assertAccounting();
    }

    function invariant_leaderboardReflectsUniquePositiveCreditedScores() public view {
        handler.assertLeaderboard();
    }

    function invariant_gameNeverHoldsValue() public view {
        assertEq(address(game).balance, 0);
    }
}
