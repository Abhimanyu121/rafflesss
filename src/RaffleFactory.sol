// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Raffle} from "./Raffle.sol";
import {IRandomnessProvider} from "./interfaces/IRandomnessProvider.sol";

/// @title RaffleFactory
/// @notice Factory for deploying Raffle clones (EIP-1167)
/// @dev Manages global settings and deploys minimal proxy clones
contract RaffleFactory is Ownable {
    using Clones for address;
    using SafeERC20 for IERC20;

    // ============ State Variables ============
    address public immutable RAFFLE_IMPLEMENTATION;
    address[] public raffles;
    mapping(address => bool) public isRaffle;

    uint256 public feeBps; // Basis points (e.g., 200 = 2%)
    address public feeRecipient;

    // Extensibility: adapters for future features
    IRandomnessProvider public randomnessProvider;

    // ============ Events ============
    event RaffleCreated(
        address indexed raffle,
        address indexed seller,
        address assetToken,
        uint256 assetAmount,
        address paymentToken,
        uint256 ticketPrice,
        uint256 ticketCap,
        uint256 sellerMin,
        uint256 startTime,
        uint256 endTime,
        uint16 winnersCount
    );
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event RandomnessProviderUpdated(address oldProvider, address newProvider);

    // ============ Errors ============
    error InvalidFeeBps();
    error InvalidAddress();

    // ============ Constructor ============
    constructor(address _feeRecipient, uint256 _feeBps) Ownable(msg.sender) {
        require(_feeRecipient != address(0), "Factory: invalid fee recipient");
        require(_feeBps <= 10000, "Factory: invalid fee bps");

        feeRecipient = _feeRecipient;
        feeBps = _feeBps;

        // Deploy implementation contract
        Raffle implementation = new Raffle();
        RAFFLE_IMPLEMENTATION = address(implementation);
    }

    // ============ Public Functions ============
    /// @notice Create a new raffle
    /// @param assetToken The asset token address (0x0 for ETH)
    /// @param assetAmount The amount of asset
    /// @param paymentToken The payment token address (0x0 for ETH)
    /// @param ticketPrice The price per ticket
    /// @param ticketCap Maximum number of tickets
    /// @param sellerMin Minimum funds required for success
    /// @param startTime Start timestamp
    /// @param endTime End timestamp
    /// @param winnersCount Number of winners
    /// @return raffle The address of the deployed raffle clone
    function createRaffle(
        address raffleSeller,
        address assetToken,
        uint256 assetAmount,
        address paymentToken,
        uint256 ticketPrice,
        uint256 ticketCap,
        uint256 sellerMin,
        uint256 startTime,
        uint256 endTime,
        uint16 winnersCount
    ) external returns (address raffle) {
        // Deploy clone
        raffle = RAFFLE_IMPLEMENTATION.clone();
        isRaffle[raffle] = true;
        raffles.push(raffle);
        address _raffleSeller = msg.sender;
        if (raffleSeller != address(0)) {
            _raffleSeller = raffleSeller;
        }

        // Initialize clone
        Raffle(raffle).initialize(
            _raffleSeller,
            assetToken,
            assetAmount,
            paymentToken,
            ticketPrice,
            ticketCap,
            sellerMin,
            startTime,
            endTime,
            winnersCount
        );

        // Transfer asset from seller to raffle contract
        // Seller must approve this factory before calling createRaffle
        IERC20(assetToken).safeTransferFrom(_raffleSeller, raffle, assetAmount);

        emit RaffleCreated(
            raffle,
            _raffleSeller,
            assetToken,
            assetAmount,
            paymentToken,
            ticketPrice,
            ticketCap,
            sellerMin,
            startTime,
            endTime,
            winnersCount
        );
    }

    // ============ Admin Functions ============
    /// @notice Set protocol fee (basis points)
    /// @param _feeBps New fee in basis points (max 10000 = 100%)
    function setFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > 10000) revert InvalidFeeBps();
        uint256 oldFeeBps = feeBps;
        feeBps = _feeBps;
        emit FeeBpsUpdated(oldFeeBps, _feeBps);
    }

    /// @notice Set fee recipient address
    /// @param _feeRecipient New fee recipient
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert InvalidAddress();
        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient);
    }

    /// @notice Set randomness provider (for VRF integration)
    /// @param _randomnessProvider New randomness provider address
    function setRandomnessProvider(
        address _randomnessProvider
    ) external onlyOwner {
        address oldProvider = address(randomnessProvider);
        randomnessProvider = IRandomnessProvider(_randomnessProvider);
        emit RandomnessProviderUpdated(oldProvider, _randomnessProvider);
    }

    // ============ View Functions ============
    /// @notice Get total number of raffles created
    function getRaffleCount() external view returns (uint256) {
        return raffles.length;
    }

    /// @notice Get raffle address by index
    function getRaffle(uint256 index) external view returns (address) {
        return raffles[index];
    }

    /// @notice Get all raffles (for off-chain indexing)
    function getAllRaffles() external view returns (address[] memory) {
        return raffles;
    }
}
