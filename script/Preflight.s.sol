// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "../src/interfaces/ISqueekCore.sol";

interface ICoreIdentity {
    function implementationCodeAddress() external view returns (address);
    function implementationCodeVersion() external view returns (uint64);
}

/// @notice Read-only deployment check. Run against Sepolia; never broadcasts.
/// @dev The game deliberately has no constructor dependency calls. Deployment
/// operators must check the actual external dependency separately, before launch.
contract Preflight {
    address public constant CORE = 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44;
    address public constant REVIEWED_IMPLEMENTATION = 0x284747C4664AF2203E7A90a2Ee76f22b6B5e6889;
    bytes32 public constant REVIEWED_RUNTIME_HASH =
        0xd8f2fb3c7dcf63e6dc0378ce5f85ceea52a876ae1f0cd66ac8631c3103371f8a;

    struct Report {
        uint256 chainId;
        address core;
        address implementation;
        uint64 version;
        uint64 defaultThreshold;
        uint256 currentRound;
        ISqueekCore.CoreConfiguration configuration;
        ISqueekCore.CoreState state;
    }

    function run() external view returns (Report memory report) {
        require(block.chainid == 11_155_111, "Sepolia only");
        require(CORE.code.length != 0, "missing SqueekCore");
        report.chainId = block.chainid;
        report.core = CORE;
        report.implementation = ICoreIdentity(CORE).implementationCodeAddress();
        report.version = ICoreIdentity(CORE).implementationCodeVersion();
        require(
            report.implementation == REVIEWED_IMPLEMENTATION && report.version == 3, "review core upgrade"
        );
        require(report.implementation.codehash == REVIEWED_RUNTIME_HASH, "review core code change");
        report.configuration = ISqueekCore(CORE).configuration();
        require(
            report.configuration.genesisTimestamp == 1_793_022_600
                && report.configuration.roundDuration == 600
                && report.configuration.maxWorkPerRound == 10_000,
            "incompatible clock or work cap"
        );
        require(block.timestamp >= report.configuration.genesisTimestamp, "before genesis");
        report.currentRound = (block.timestamp - report.configuration.genesisTimestamp) / 600 + 1;
        report.defaultThreshold = 100;
        report.state = ISqueekCore(CORE).state();
        require(report.state.settledThroughRound < report.currentRound, "future frontier");
    }
}
