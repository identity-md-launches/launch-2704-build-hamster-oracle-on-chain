// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterOracle} from "../src/HamsterOracle.sol";
import {ISqueekCore} from "../src/interfaces/ISqueekCore.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";

abstract contract HamsterTestBase is Test {
    HamsterOracle internal game;
    MockSqueekCore internal core;
    address internal alice;
    address internal bob;
    address internal keeper;
    uint64 internal constant GENESIS = 1_793_022_600;
    address internal constant CORE = 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44;

    function setUp() public virtual {
        vm.chainId(11_155_111);
        vm.warp(GENESIS + 37);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        keeper = makeAddr("keeper");
        MockSqueekCore implementation = new MockSqueekCore();
        vm.etch(CORE, address(implementation).code);
        core = MockSqueekCore(CORE);
        core.initializeMock();
        game = new HamsterOracle(100);
    }

    function _pick(address player, uint64 roundId, HamsterOracle.Outcome pick) internal {
        vm.prank(player);
        game.predict(roundId, pick);
    }

    function _close(uint64 roundId) internal {
        vm.warp(uint256(GENESIS) + uint256(roundId) * 600);
    }

    function _credit(address player) internal returns (uint256) {
        vm.prank(keeper);
        return game.checkpoint(player, 16);
    }

    function _assertPrediction(address player, uint64 roundId, bool scored, uint8 award) internal view {
        (, bool exists, bool isScored, uint8 awarded) = game.predictions(player, roundId);
        assertTrue(exists);
        assertEq(isScored, scored);
        assertEq(awarded, award);
    }
}

