// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HamsterTestBase, HamsterOracle} from "./HamsterTestBase.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";

/// @dev Deliberately non-view fallback: the caller, not this implementation,
/// must enforce STATICCALL to prevent state-changing callbacks from the oracle.
contract ReenteringReadCore {
    address private immutable _game;
    address private immutable _backend;

    constructor(address game, address backend) {
        _game = game;
        _backend = backend;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (bool reentered,) =
            _game.call{gas: 1_000_000}(abi.encodeCall(HamsterOracle.predict, (4, HamsterOracle.Outcome.NAP)));
        require(!reentered, "oracle changed game state during read");
        (bool success, bytes memory result) = _backend.staticcall(data);
        require(success, "reference oracle failed");
        return result;
    }
}

contract StaticReadSafetyTest is HamsterTestBase {
    function test_externalReadsCannotReenterToWriteGameState() public {
        _pick(alice, 2, HamsterOracle.Outcome.SPRINT);
        _close(2);
        MockSqueekCore referenceCore = new MockSqueekCore();
        referenceCore.initializeMock();
        referenceCore.record(2, 100);
        ReenteringReadCore malicious = new ReenteringReadCore(address(game), address(referenceCore));
        vm.etch(CORE, address(malicious).code);
        _credit(alice);
        assertEq(game.points(alice), 3);
        assertEq(game.historyLength(CORE), 0);
        (uint256 nap, uint256 jog, uint256 sprint) = game.roundCounts(4);
        assertEq(nap + jog + sprint, 0);
    }

    function test_runtimeSizeAndForbiddenOpcodes() public view {
        bytes memory code = address(game).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "escape opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }
}
