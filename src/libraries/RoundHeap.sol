// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev A per-player min heap allows predictions to be placed in any order and
/// scored chronologically. Each operation takes O(log n), at most 64 levels:
/// callers only insert unique, nonzero uint64 round IDs.
library RoundHeap {
    function insert(uint64[] storage heap, uint64 roundId) internal {
        uint256 index = heap.length;
        heap.push(roundId);
        while (index != 0) {
            uint256 parent = (index - 1) / 2;
            if (heap[parent] <= roundId) break;
            heap[index] = heap[parent];
            index = parent;
        }
        heap[index] = roundId;
    }

    /// @dev Requires a nonempty heap. Callers check length before use.
    function removeMin(uint64[] storage heap) internal {
        uint64 last = heap[heap.length - 1];
        heap.pop();
        uint256 length = heap.length;
        if (length == 0) return;
        uint256 index = 0;
        while (true) {
            uint256 child = index * 2 + 1;
            if (child >= length) break;
            if (child + 1 < length && heap[child + 1] < heap[child]) ++child;
            if (last <= heap[child]) break;
            heap[index] = heap[child];
            index = child;
        }
        heap[index] = last;
    }
}

