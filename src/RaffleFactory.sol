// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Raffle} from "./Raffle.sol";
import {IRandomnessProvider} from "./interfaces/IRandomnessProvider.sol";

/// @title RaffleFactory
/// @notice Creates raffles as EIP-1167 clones and holds the terms new raffles are born with.
/// @dev Settings here apply only to raffles created from now on: a raffle copies the fee,
///      recipient and provider at creation and never reads them again.
contract RaffleFactory is Ownable2Step {
    using Clones for address;
    using SafeERC20 for IERC20;

    /// @notice Hard ceiling on the protocol fee. Not adjustable.
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    address public immutable RAFFLE_IMPLEMENTATION;
    address[] public raffles;
    mapping(address => bool) public isRaffle;

    uint256 public feeBps;
    address public feeRecipient;
    IRandomnessProvider public randomnessProvider;

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

    error InvalidFeeBps();
    error InvalidAddress();
    error SellerMustBeCaller();
    error UnsupportedAssetToken();

    /// @param _owner Passed explicitly: a CREATE2 deployment routes through a proxy, so
    ///        msg.sender here would be that proxy rather than the operator.
    constructor(address _owner, address _feeRecipient, uint256 _feeBps, address _provider) Ownable(_owner) {
        // A zero owner is already rejected by Ownable's constructor.
        if (_feeRecipient == address(0)) revert InvalidAddress();
        if (_provider == address(0)) revert InvalidAddress();
        if (_feeBps > MAX_FEE_BPS) revert InvalidFeeBps();

        feeRecipient = _feeRecipient;
        feeBps = _feeBps;
        randomnessProvider = IRandomnessProvider(_provider);

        RAFFLE_IMPLEMENTATION = address(new Raffle(address(this)));
    }

    /// @notice Create a raffle and escrow its prize, taken from the caller.
    /// @dev `raffleSeller` must be the caller or zero. It cannot name a third party: an
    ///      allowance to this factory is not permission for a stranger to spend it.
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
        if (raffleSeller != address(0) && raffleSeller != msg.sender) {
            revert SellerMustBeCaller();
        }

        raffle = RAFFLE_IMPLEMENTATION.clone();
        isRaffle[raffle] = true;
        raffles.push(raffle);

        Raffle(raffle)
            .initialize(
                Raffle.RaffleParams({
                    seller: msg.sender,
                    assetToken: assetToken,
                    assetAmount: assetAmount,
                    paymentToken: paymentToken,
                    ticketPrice: ticketPrice,
                    ticketCap: ticketCap,
                    sellerMin: sellerMin,
                    startTime: startTime,
                    endTime: endTime,
                    winnersCount: winnersCount,
                    feeBps: feeBps,
                    feeRecipient: feeRecipient,
                    randomnessProvider: address(randomnessProvider)
                })
            );

        // Escrow the prize and confirm the raffle received all of it.
        uint256 balanceBefore = IERC20(assetToken).balanceOf(raffle);
        IERC20(assetToken).safeTransferFrom(msg.sender, raffle, assetAmount);
        if (IERC20(assetToken).balanceOf(raffle) - balanceBefore != assetAmount) {
            revert UnsupportedAssetToken();
        }

        emit RaffleCreated(
            raffle,
            msg.sender,
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

    // ============ Admin ============

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert InvalidFeeBps();
        emit FeeBpsUpdated(feeBps, _feeBps);
        feeBps = _feeBps;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert InvalidAddress();
        emit FeeRecipientUpdated(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    function setRandomnessProvider(address _provider) external onlyOwner {
        if (_provider == address(0)) revert InvalidAddress();
        emit RandomnessProviderUpdated(address(randomnessProvider), _provider);
        randomnessProvider = IRandomnessProvider(_provider);
    }

    // ============ Views ============

    function getRaffleCount() external view returns (uint256) {
        return raffles.length;
    }

    function getRaffle(uint256 index) external view returns (address) {
        return raffles[index];
    }

    /// @notice Page through the registry. Prefer this to reading the whole list.
    function getRaffles(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = raffles.length;
        if (offset >= total) return new address[](0);
        uint256 remaining = total - offset;
        uint256 count = limit < remaining ? limit : remaining;
        page = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = raffles[offset + i];
        }
    }
}
