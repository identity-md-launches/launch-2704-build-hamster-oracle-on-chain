// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "../../src/interfaces/ISqueekCore.sol";

/// @dev Test-only implementation of the real read ABI and sparse certified ledger.
/// The helper record() replaces reporter signatures; it is NOT a production oracle.
contract MockSqueekCore is ISqueekCore {
    CoreConfiguration private _configuration;
    CoreState private _state;
    RoundCheckpoint[] private _records;
    bool public unavailable;

    event RoundRecorded(
        uint64 indexed roundId,
        uint64 work,
        uint64 cumulativeWork,
        uint96 cumulativeBlockUnits,
        uint32 workPerThousandBlocks,
        bytes32 dataHash
    );
    event BatchSettled(
        bytes32 indexed digest,
        address indexed reporter,
        uint64 indexed settledThroughRound,
        uint256 nonce,
        uint64 previousSettledThroughRound,
        uint16 activeRoundCount,
        uint64 cumulativeWork,
        uint96 cumulativeBlockUnits
    );

    function initializeMock() external {
        require(_configuration.roundDuration == 0, "already initialized");
        _configuration.genesisTimestamp = 1_793_022_600;
        _configuration.roundDuration = 600;
        _configuration.maxWorkPerRound = 10_000;
        _configuration.maxRoundsPerBatch = 16;
        _configuration.initialWorkPerThousandBlocks = 10_000;
        _configuration.targetBlocksPerActiveRound = 40;
        _configuration.difficultySmoothingRounds = 30;
        _configuration.blockUnitsPerBlock = 1_000_000_000;
        _state.workPerThousandBlocks = 10_000;
    }

    function configuration() external view returns (CoreConfiguration memory) {
        require(!unavailable, "core unavailable");
        return _configuration;
    }

    function state() external view returns (CoreState memory) {
        require(!unavailable, "core unavailable");
        return _state;
    }

    /// @dev One active record (or none for zero work), certifying preceding gaps as zero.
    function record(uint64 roundId, uint64 work) external {
        require(roundId > _state.settledThroughRound, "frontier must advance");
        require(
            uint256(_configuration.genesisTimestamp) + uint256(roundId) * 600 <= block.timestamp,
            "round not elapsed"
        );
        require(work <= _configuration.maxWorkPerRound, "work cap");
        uint64 previous = _state.settledThroughRound;
        if (work != 0) {
            _state.cumulativeWork += work;
            _state.cumulativeBlockUnits += uint96(uint256(work) * 1e12 / _state.workPerThousandBlocks);
            if (work >= 40) {
                _state.workPerThousandBlocks =
                    uint32((uint256(_state.workPerThousandBlocks) * 29 + uint256(work) * 1000 / 40) / 30);
            }
            bytes32 dataHash = keccak256(abi.encode(roundId, work));
            _records.push(
                RoundCheckpoint(
                    roundId,
                    _state.cumulativeWork,
                    _state.cumulativeBlockUnits,
                    _state.workPerThousandBlocks,
                    dataHash
                )
            );
            emit RoundRecorded(
                roundId,
                work,
                _state.cumulativeWork,
                _state.cumulativeBlockUnits,
                _state.workPerThousandBlocks,
                dataHash
            );
        }
        _state.settledThroughRound = roundId;
        _state.blockHeight = uint64(_state.cumulativeBlockUnits / 1e9);
        _state.blockProgress = _state.cumulativeBlockUnits % 1e9;
        emit BatchSettled(
            keccak256(abi.encode(roundId, work)),
            _configuration.reporter,
            roundId,
            _state.authorizationNonce++,
            previous,
            work == 0 ? 0 : 1,
            _state.cumulativeWork,
            _state.cumulativeBlockUnits
        );
    }

    function roundPage(uint64 afterRound, uint64 throughRound, uint256 maxRecords)
        external
        view
        returns (RoundPage memory result)
    {
        require(!unavailable, "core unavailable");
        require(
            throughRound >= afterRound && throughRound <= _state.settledThroughRound && maxRecords <= 16,
            "invalid bounds"
        );
        uint256 first = _after(afterRound);
        uint256 end = _after(throughRound);
        result.certifiedThroughRound = throughRound;
        if (end - first > maxRecords) {
            end = first + maxRecords;
            result.certifiedThroughRound = _records[end].roundId - 1;
        }
        result.start = _position(first);
        result.end = _position(end);
        result.rounds = new RoundCheckpoint[](end - first);
        for (uint256 i = first; i < end; ++i) {
            result.rounds[i - first] = _records[i];
        }
    }

    function _after(uint64 roundId) private view returns (uint256 low) {
        uint256 high = _records.length;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (_records[mid].roundId <= roundId) low = mid + 1;
            else high = mid;
        }
    }

    function _position(uint256 count) private view returns (LedgerPosition memory) {
        if (count == 0) return LedgerPosition(0, 0, _configuration.initialWorkPerThousandBlocks);
        RoundCheckpoint memory last = _records[count - 1];
        return LedgerPosition(last.cumulativeWork, last.cumulativeBlockUnits, last.workPerThousandBlocks);
    }

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function setPaused(bool value) external {
        _state.paused = value;
    }

    function setConfiguration(CoreConfiguration calldata config) external {
        _configuration = config;
    }

    function setState(CoreState calldata value) external {
        _state = value;
    }
}

