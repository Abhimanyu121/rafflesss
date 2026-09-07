// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRandomnessProvider} from "../../src/interfaces/IRandomnessProvider.sol";

/// @title MockRandomnessProvider
/// @notice Test double that lets a test decide the seed and when it becomes available.
/// @dev Never deploy this. It exists so tests can drive the raffle deterministically.
contract MockRandomnessProvider is IRandomnessProvider {
    mapping(bytes32 => uint256) public randomness;
    mapping(bytes32 => address) public requester;
    bytes32 public lastRequestId;
    uint256 public requestCount;

    /// @dev Seed handed out automatically to each new request. Zero means "not ready
    ///      until the test calls fulfill", which is the realistic oracle behaviour.
    uint256 public autoSeed;

    function setAutoSeed(uint256 s) external {
        autoSeed = s;
    }

    function requestRandomness(address raffle, bytes32 seed) external returns (bytes32 requestId) {
        requestCount++;
        requestId = keccak256(abi.encode(raffle, seed, requestCount));
        requester[requestId] = raffle;
        lastRequestId = requestId;
        if (autoSeed != 0) {
            randomness[requestId] = autoSeed;
        }
    }

    function getRandomness(bytes32 requestId) external view returns (uint256) {
        return randomness[requestId];
    }

    /// @notice Deliver a seed for a pending request.
    function fulfill(bytes32 requestId, uint256 value) external {
        randomness[requestId] = value;
    }

    /// @notice Deliver a seed for the most recent request.
    function fulfillLast(uint256 value) external {
        randomness[lastRequestId] = value;
    }
}
