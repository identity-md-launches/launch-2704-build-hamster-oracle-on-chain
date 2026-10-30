// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterOracle} from "../src/HamsterOracle.sol";

/// @dev Exercise raw init code as the launch factory does, rather than only
/// Foundry's instrumented `new` expression in test functions.
contract DeploymentProbe {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address result) {
        assembly ("memory-safe") {
            result := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(result != address(0), "constructor reverted");
    }
}

contract DeploymentTest is Test {
    function test_rawFactoryDeploymentOnEmptySepoliaChain() public {
        vm.chainId(11_155_111);
        address core = 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44;
        assertEq(core.code.length, 0);
        DeploymentProbe factory = new DeploymentProbe();
        bytes memory initCode = bytes.concat(type(HamsterOracle).creationCode, abi.encode(uint64(100)));
        assertLe(initCode.length, 49_152);
        bytes32 salt = keccak256("Hamster Oracle deployment rehearsal");
        address expected = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(initCode)))
                )
            )
        );
        address deployed = factory.deploy(initCode, salt);
        assertEq(deployed, expected);
        assertGt(deployed.code.length, 0);
        assertLe(deployed.code.length, 24_576);
        HamsterOracle game = HamsterOracle(deployed);
        assertEq(game.threshold(), 100);
        assertEq(game.SQUEEK_CORE(), core);
        assertEq(game.points(address(factory)), 0);
        assertEq(game.leaderboard().length, 0);
        (bool owner,) = deployed.staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(owner);
        vm.warp(1_793_022_600);
        game.predict(2, HamsterOracle.Outcome.NAP);
        assertEq(game.historyLength(address(this)), 1);
    }
}
