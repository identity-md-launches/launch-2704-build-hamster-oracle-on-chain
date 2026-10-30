// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "./interfaces/ISqueekCore.sol";
import {RoundHeap} from "./libraries/RoundHeap.sol";

/// @title Hamster Oracle
/// @notice Sepolia-only, nontransferable points for predicting Squeekchain work.
/// No owner, payments, privileged settlement, or upgrade mechanism.
/// @dev settle caches a round's result. Permissionless checkpoint credits one
/// player's predictions in chronological, bounded batches, updating the top 50.
contract HamsterOracle {
    using RoundHeap for uint64[];

    enum Outcome {
        NAP,
        JOG,
        SPRINT
    }

    struct Prediction {
        Outcome pick;
        bool exists;
        bool scored;
        uint8 awarded;
    }

    struct RoundResult {
        uint64 work;
        Outcome outcome;
        bool settled;
    }

    struct Player {
        uint256 points;
        uint64 streak;
        uint64 lastScoredRound;
        uint64 scoredPredictions;
    }

    struct HistoryEntry {
        uint64 roundId;
        Prediction prediction;
        RoundResult result;
    }

    struct LeaderboardEntry {
        address player;
        uint256 points;
    }

    address public constant SQUEEK_CORE = 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44;
    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint64 public constant GENESIS_TIMESTAMP = 1_793_022_600;
    uint64 public constant ROUND_DURATION = 600;
    uint64 public constant MAX_WORK = 10_000;
    uint64 public constant DEFAULT_THRESHOLD = 100;
    uint256 public constant MAX_CHECKPOINT_ROUNDS = 16;
    uint256 public constant MAX_HISTORY_PAGE = 100;
    uint256 public constant LEADERBOARD_SIZE = 50;
    uint64 public constant MAX_STREAK_BONUS = 5;

    uint64 public immutable threshold;

    mapping(address player => mapping(uint64 roundId => Prediction)) public predictions;
    mapping(uint64 roundId => RoundResult) public rounds;
    mapping(address player => Player) public players;
    mapping(uint64 roundId => uint256[3]) private _roundCounts;
    mapping(address player => uint64[]) private _history;
    mapping(address player => uint64[]) private _pending;
    address[] private _leaders;

    error WrongChain();
    error InvalidThreshold();
    error InvalidRound();
    error RoundNotFuture(uint64 roundId);
    error AlreadyPredicted(uint64 roundId);
    error RoundNotClosed(uint64 roundId);
    error RoundNotRecorded(uint64 roundId, uint64 settledThroughRound);
    error IncompatibleCore();
    error InvalidCorePage(uint64 roundId);
    error InvalidBatchSize();
    error InvalidHistoryPage();
    error UnsupportedTimestamp();

    event PredictionPlaced(address indexed player, uint64 indexed roundId, Outcome pick);
    event RoundSettled(uint64 indexed roundId, uint64 work, Outcome outcome);
    event PredictionScored(
        address indexed player,
        uint64 indexed roundId,
        bool correct,
        uint8 awarded,
        uint256 totalPoints,
        uint64 streak
    );

    modifier onlySepolia() {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert WrongChain();
        _;
    }

    /// @param threshold_ Smallest SPRINT work value, 1..10000. Deploy with 100 by default.
    /// @dev Makes no external calls; the launch factory need not have SqueekCore present.
    constructor(uint64 threshold_) onlySepolia {
        if (threshold_ == 0 || threshold_ > MAX_WORK) revert InvalidThreshold();
        threshold = threshold_;
    }

    /// @notice Round 1 starts at genesis; 0 denotes the time before genesis.
    function currentRound() public view returns (uint64) {
        if (block.timestamp < GENESIS_TIMESTAMP) return 0;
        uint256 value = (block.timestamp - GENESIS_TIMESTAMP) / ROUND_DURATION + 1;
        if (value > type(uint64).max) revert UnsupportedTimestamp();
        return uint64(value);
    }

    function roundStart(uint64 roundId) public pure returns (uint256) {
        if (roundId == 0) revert InvalidRound();
        return uint256(GENESIS_TIMESTAMP) + (uint256(roundId) - 1) * ROUND_DURATION;
    }

    function roundEnd(uint64 roundId) public pure returns (uint256) {
        return roundStart(roundId) + ROUND_DURATION;
    }

    /// @notice Predict any round whose start is still in the future, including the next round.
    /// Enum values: NAP=0, JOG=1, SPRINT=2. Picks cannot be changed or cancelled.
    function predict(uint64 roundId, Outcome pick) external onlySepolia {
        if (roundId == 0) revert InvalidRound();
        if (roundId <= currentRound()) revert RoundNotFuture(roundId);
        Prediction storage prediction = predictions[msg.sender][roundId];
        if (prediction.exists) revert AlreadyPredicted(roundId);

        prediction.pick = pick;
        prediction.exists = true;
        ++_roundCounts[roundId][uint256(pick)];
        _history[msg.sender].push(roundId);
        _pending[msg.sender].insert(roundId);
        emit PredictionPlaced(msg.sender, roundId, pick);
    }

    /// @notice Cache a closed, certified round. Anyone may call; repeats are idempotent.
    /// @dev Does not iterate over players. Call checkpoint to credit their points.
    function settle(uint64 roundId) external onlySepolia returns (uint64 work, Outcome outcome) {
        _requireClosed(roundId);
        RoundResult memory result = rounds[roundId];
        if (!result.settled) result = _settle(roundId, _coreState());
        return (result.work, result.outcome);
    }

    /// @notice Preview work from the fixed oracle, or the immutable cached result.
    /// Unknown rounds revert; a missing active record is zero only inside a certified page.
    function roundWork(uint64 roundId) external view onlySepolia returns (uint64) {
        _requireClosed(roundId);
        RoundResult memory result = rounds[roundId];
        return result.settled ? result.work : _readWork(roundId, _coreState());
    }

    /// @notice Score up to maxRounds of player's oldest pending predictions (1..16).
    /// Anyone may pay gas for any player. Returns the number actually scored.
    /// Stops at the first future or uncertified round; repeat after the reporter catches up.
    /// @dev This also settles missing results. No need to call settle separately.
    function checkpoint(address player, uint256 maxRounds) external onlySepolia returns (uint256 processed) {
        if (maxRounds == 0 || maxRounds > MAX_CHECKPOINT_ROUNDS) revert InvalidBatchSize();
        uint64[] storage pending = _pending[player];
        uint64 current = currentRound();
        ISqueekCore.CoreState memory coreState;
        bool stateLoaded = false;
        uint256 previousPoints = players[player].points;

        while (processed < maxRounds && pending.length != 0) {
            uint64 roundId = pending[0];
            if (roundId >= current) break;
            RoundResult memory result = rounds[roundId];
            if (!result.settled) {
                if (!stateLoaded) {
                    coreState = _coreState();
                    stateLoaded = true;
                }
                if (roundId > coreState.settledThroughRound) break;
                result = _settle(roundId, coreState);
            }
            pending.removeMin();
            _score(player, roundId, result.outcome);
            ++processed;
        }
        if (players[player].points != previousPoints) _updateLeaderboard(player);
    }

    function points(address player) external view returns (uint256) {
        return players[player].points;
    }

    /// @notice Consecutive correct round IDs ending at lastScoredRound (not capped).
    /// Pending predictions are not included. A wrong pick or skipped round breaks the run.
    function streak(address player) external view returns (uint64) {
        return players[player].streak;
    }

    function roundCounts(uint64 roundId) external view returns (uint256 nap, uint256 jog, uint256 sprint) {
        uint256[3] storage counts = _roundCounts[roundId];
        return (counts[0], counts[1], counts[2]);
    }

    function historyLength(address player) external view returns (uint256) {
        return _history[player].length;
    }

    /// @notice History in placement order, not round order. Limit 0..100, exclusive next offset.
    /// Offsets at or beyond length return an empty page and nextOffset=length.
    function predictionHistory(address player, uint256 offset, uint256 limit)
        external
        view
        returns (HistoryEntry[] memory entries, uint256 nextOffset)
    {
        if (limit > MAX_HISTORY_PAGE) revert InvalidHistoryPage();
        uint64[] storage history = _history[player];
        uint256 length = history.length;
        if (offset >= length) return (new HistoryEntry[](0), length);
        uint256 count = length - offset;
        if (count > limit) count = limit;
        entries = new HistoryEntry[](count);
        for (uint256 i; i < count; ++i) {
            uint64 roundId = history[offset + i];
            entries[i] = HistoryEntry(roundId, predictions[player][roundId], rounds[roundId]);
        }
        return (entries, offset + count);
    }

    /// @notice Earliest pending round, or 0 if none; also the total pending count.
    function pendingStatus(address player) external view returns (uint64 nextRound, uint256 count) {
        uint64[] storage pending = _pending[player];
        count = pending.length;
        if (count != 0) nextRound = pending[0];
    }

    /// @notice Up to 50 players with positive credited points, descending score.
    /// Equal points rank by ascending numeric wallet address, independent of call order.
    function leaderboard() external view returns (LeaderboardEntry[] memory entries) {
        entries = new LeaderboardEntry[](_leaders.length);
        for (uint256 i; i < entries.length; ++i) {
            address player = _leaders[i];
            entries[i] = LeaderboardEntry(player, players[player].points);
        }
    }

    function _requireClosed(uint64 roundId) private view {
        if (roundId == 0) revert InvalidRound();
        if (roundId >= currentRound()) revert RoundNotClosed(roundId);
    }

    function _coreState() private view returns (ISqueekCore.CoreState memory result) {
        ISqueekCore core = ISqueekCore(SQUEEK_CORE);
        ISqueekCore.CoreConfiguration memory config = core.configuration();
        if (
            config.genesisTimestamp != GENESIS_TIMESTAMP || config.roundDuration != ROUND_DURATION
                || config.maxWorkPerRound != MAX_WORK
        ) revert IncompatibleCore();
        result = core.state();
        // An upstream pause only prevents new reporting; already certified history is usable.
        uint64 current = currentRound();
        if (current == 0 || result.settledThroughRound >= current) revert IncompatibleCore();
    }

    function _readWork(uint64 roundId, ISqueekCore.CoreState memory coreState)
        private
        view
        returns (uint64 work)
    {
        if (roundId > coreState.settledThroughRound) {
            revert RoundNotRecorded(roundId, coreState.settledThroughRound);
        }
        ISqueekCore.RoundPage memory page = ISqueekCore(SQUEEK_CORE).roundPage(roundId - 1, roundId, 1);
        if (
            page.certifiedThroughRound != roundId || page.end.cumulativeWork < page.start.cumulativeWork
                || page.end.cumulativeWork > coreState.cumulativeWork || page.rounds.length > 1
        ) revert InvalidCorePage(roundId);
        work = page.end.cumulativeWork - page.start.cumulativeWork;
        if (work > MAX_WORK) revert InvalidCorePage(roundId);
        if (work == 0) {
            if (page.rounds.length != 0) revert InvalidCorePage(roundId);
        } else {
            if (
                page.rounds.length != 1 || page.rounds[0].roundId != roundId
                    || page.rounds[0].cumulativeWork != page.end.cumulativeWork
                    || page.rounds[0].dataHash == bytes32(0)
            ) revert InvalidCorePage(roundId);
        }
    }

    function _settle(uint64 roundId, ISqueekCore.CoreState memory coreState)
        private
        returns (RoundResult memory result)
    {
        uint64 work = _readWork(roundId, coreState);
        Outcome outcome = work == 0 ? Outcome.NAP : (work < threshold ? Outcome.JOG : Outcome.SPRINT);
        result = RoundResult(work, outcome, true);
        rounds[roundId] = result;
        emit RoundSettled(roundId, work, outcome);
    }

    function _score(address player, uint64 roundId, Outcome outcome) private {
        Prediction storage prediction = predictions[player][roundId];
        Player storage account = players[player];
        bool correct = prediction.pick == outcome;
        uint8 awarded = 0;
        if (correct) {
            // Subtraction avoids overflowing a uint64 lastScoredRound at its maximum.
            uint64 run = roundId - 1 == account.lastScoredRound ? account.streak + 1 : 1;
            account.streak = run;
            uint64 bonus = run - 1;
            if (bonus > MAX_STREAK_BONUS) bonus = MAX_STREAK_BONUS;
            awarded = uint8((outcome == Outcome.SPRINT ? 3 : 1) + bonus);
            account.points += awarded;
        } else {
            account.streak = 0;
        }
        account.lastScoredRound = roundId;
        ++account.scoredPredictions;
        prediction.scored = true;
        prediction.awarded = awarded;
        emit PredictionScored(player, roundId, correct, awarded, account.points, account.streak);
    }

    function _ranksAhead(address left, address right) private view returns (bool) {
        uint256 leftPoints = players[left].points;
        uint256 rightPoints = players[right].points;
        return leftPoints > rightPoints || (leftPoints == rightPoints && uint160(left) < uint160(right));
    }

    function _updateLeaderboard(address player) private {
        uint256 length = _leaders.length;
        uint256 index = 0;
        while (index < length && _leaders[index] != player) ++index;
        if (index == length) {
            if (length < LEADERBOARD_SIZE) {
                _leaders.push(player);
            } else {
                if (!_ranksAhead(player, _leaders[length - 1])) return;
                index = length - 1;
                _leaders[index] = player;
            }
        }
        // Scores only increase, so an existing member can only move toward the front.
        while (index != 0 && _ranksAhead(player, _leaders[index - 1])) {
            _leaders[index] = _leaders[index - 1];
            --index;
        }
        _leaders[index] = player;
    }
}
