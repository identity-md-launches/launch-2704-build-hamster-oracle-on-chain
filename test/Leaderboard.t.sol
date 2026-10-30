// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HamsterTestBase, HamsterOracle} from "./HamsterTestBase.sol";

contract LeaderboardTest is HamsterTestBase {
    function _wallet(uint256 i) private pure returns (address) {
        return address(uint160(1000 + i));
    }

    function test_top50TieBreakEvictionReentryAndExistingMemberPromotion() public {
        assertEq(game.leaderboard().length, 0);
        for (uint256 i; i < 60; ++i) {
            _pick(_wallet(i), 2, HamsterOracle.Outcome.NAP);
            _pick(_wallet(i), 3, HamsterOracle.Outcome.SPRINT);
        }
        _close(3);
        core.record(3, 100);
        for (uint256 i = 60; i != 0; --i) {
            game.checkpoint(_wallet(i - 1), 1);
        }
        HamsterOracle.LeaderboardEntry[] memory entries = game.leaderboard();
        assertEq(entries.length, 50);
        for (uint256 i; i < 50; ++i) {
            assertEq(entries[i].player, _wallet(i));
            assertEq(entries[i].points, 1);
        }

        // An outsider becomes first; the former last member is evicted.
        game.checkpoint(_wallet(59), 1);
        entries = game.leaderboard();
        assertEq(entries[0].player, _wallet(59));
        assertEq(entries[0].points, 5);
        assertEq(entries[49].player, _wallet(48));

        // The evicted member can reenter and wins the tied score by address.
        game.checkpoint(_wallet(49), 1);
        entries = game.leaderboard();
        assertEq(entries[0].player, _wallet(49));
        assertEq(entries[1].player, _wallet(59));
        // A member's increase moves it upward without creating a duplicate.
        game.checkpoint(_wallet(10), 1);
        entries = game.leaderboard();
        assertEq(entries[0].player, _wallet(10));
        assertEq(entries[1].player, _wallet(49));
        assertEq(entries[2].player, _wallet(59));
        for (uint256 i; i < entries.length; ++i) {
            for (uint256 j = i + 1; j < entries.length; ++j) {
                assertNotEq(entries[i].player, entries[j].player);
            }
        }
    }

    /// @dev Compare the bounded maintained list with an independent sort of ALL
    /// players, including outsiders, after random scoring order and varied totals.
    function testFuzz_leaderboardMatchesFullSort(uint256 seed) public {
        uint256 count = 57;
        uint256[] memory totals = new uint256[](count);
        uint256[] memory order = new uint256[](count);
        uint256 positiveCount;
        for (uint256 i; i < count; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            bool first = random % 2 == 0;
            bool second = (random >> 8) % 2 == 0;
            _pick(_wallet(i), 2, first ? HamsterOracle.Outcome.NAP : HamsterOracle.Outcome.JOG);
            _pick(_wallet(i), 3, second ? HamsterOracle.Outcome.SPRINT : HamsterOracle.Outcome.NAP);
            totals[i] = (first ? 1 : 0) + (second ? (first ? 4 : 3) : 0);
            if (totals[i] != 0) ++positiveCount;
            order[i] = i;
        }
        _close(3);
        core.record(3, 100);
        for (uint256 i = count; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i, "order"))) % i;
            (order[i - 1], order[j]) = (order[j], order[i - 1]);
        }
        // Alternate partial and full scoring so existing members get updated too.
        for (uint256 i; i < count; ++i) {
            game.checkpoint(_wallet(order[i]), 1 + i % 2);
        }
        for (uint256 i = count; i > 0; --i) {
            game.checkpoint(_wallet(order[i - 1]), 16);
        }
        for (uint256 i; i < count; ++i) {
            assertEq(game.points(_wallet(i)), totals[i]);
            order[i] = i;
        }
        for (uint256 i; i < count; ++i) {
            for (uint256 j = i + 1; j < count; ++j) {
                if (
                    totals[order[j]] > totals[order[i]]
                        || (totals[order[j]] == totals[order[i]] && order[j] < order[i])
                ) {
                    (order[i], order[j]) = (order[j], order[i]);
                }
            }
        }
        HamsterOracle.LeaderboardEntry[] memory entries = game.leaderboard();
        uint256 size = positiveCount < 50 ? positiveCount : 50;
        assertEq(entries.length, size);
        for (uint256 i; i < size; ++i) {
            assertEq(entries[i].player, _wallet(order[i]));
            assertEq(entries[i].points, totals[order[i]]);
        }
    }
}

