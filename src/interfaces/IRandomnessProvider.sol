// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRandomnessProvider
/// @notice Interface for randomness providers (off-chain relayer or Chainlink VRF)
interface IRandomnessProvider {
    /// @notice Request randomness for a raffle
    /// @param raffle The raffle address requesting randomness
    /// @param seed A seed value for randomness generation
    /// @return requestId The request ID for tracking
    function requestRandomness(address raffle, bytes32 seed) external returns (bytes32 requestId);

    /// @notice Get the randomness result for a request
    /// @param requestId The request ID
    /// @return randomness The random value (0 if not ready)
    function getRandomness(bytes32 requestId) external view returns (uint256 randomness);
}

