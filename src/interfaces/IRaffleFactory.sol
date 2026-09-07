// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRaffleFactory
/// @notice Minimal view of the factory used by peripheral contracts.
interface IRaffleFactory {
    function feeBps() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function randomnessProvider() external view returns (address);
    function isRaffle(address) external view returns (bool);
    function owner() external view returns (address);
}
