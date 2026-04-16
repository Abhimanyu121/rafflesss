// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Raffle
/// @notice A minimal, extensible raffle contract for selling tickets and distributing prizes
/// @dev Uses pull-based withdrawals for security
contract Raffle is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    address public constant ETH_ADDRESS = address(0);
    uint256 public constant MAX_TICKETS_PER_ADDRESS = 10000; // Prevent single-wallet domination
    uint256 public constant MAX_WINNERS_COUNT = 200; // Maximum winners to ensure sufficient block history (200 blocks ≈ 40 minutes)

    // ============ State Variables ============
    address public factory;
    address public seller;
    address public assetToken; // ERC20 token address (0x0 for ETH)
    uint256 public assetAmount;
    address public paymentToken; // ERC20 token address (0x0 for ETH)
    uint256 public ticketPrice;
    uint256 public ticketCap;
    uint256 public sellerMin;
    uint256 public startTime;
    uint256 public endTime;
    uint16 public winnersCount;
    uint256 finalizationBlock;
    // Ticket accounting
    mapping(address => uint256) public tickets;
    mapping(uint256 => bool) public winningIndex;
    address[] public ticketHolders;
    uint256 public totalTickets;
    uint256 public totalFunds;

    // Finalization state
    bool public finalized;
    bool private _succeededState; // Stored during finalize()
    address[] public winners;
    bool winnersSet;
    bool public assetWithdrawnBySeller;

    // Pull-based withdrawals
    mapping(address => uint256) public pendingWithdrawals; // For refunds and seller payout
    mapping(address => bool) public refundClaimedAllTickets;
    mapping(address => bool) public prizeClaimedAll;

    // ============ Events ============
    event Initialized(
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
    event TicketsPurchased(
        address indexed buyer,
        uint256 amount,
        uint256 totalTickets
    );
    event Finalized(bool succeeded, uint256 totalFunds);
    event WinnersSet(address[] winners);
    event RefundClaimed(address indexed claimer, uint256 amount);
    event PrizeClaimed(address indexed winner, uint256 amount);
    event SellerWithdrawn(address indexed seller, uint256 amount);
    event AssetWithdrawn(address indexed seller, uint256 amount);

    // ============ Modifiers ============
    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    function _onlyFactory() internal view {
        require(msg.sender == factory, "Raffle: only factory");
    }

    modifier onlyActive() {
        _onlyActive();
        _;
    }

    function _onlyActive() internal view {
        require(
            block.timestamp >= startTime && block.timestamp <= endTime,
            "Raffle: not active"
        );
        require(!finalized, "Raffle: already finalized");
    }

    modifier onlyAfterEnd() {
        _onlyAfterEnd();
        _;
    }

    function _onlyAfterEnd() internal view {
        require(block.timestamp > endTime, "Raffle: not ended");
    }

    // ============ Constructor ============
    constructor() {
        // Constructor only runs on implementation deployment
        // Clones will have factory set via initialize
    }

    // ============ Initialization ============
    /// @notice Initialize the raffle (called once by factory)
    /// @param _seller The seller address
    /// @param _assetToken The asset token address (0x0 for ETH)
    /// @param _assetAmount The amount of asset
    /// @param _paymentToken The payment token address (0x0 for ETH)
    /// @param _ticketPrice The price per ticket
    /// @param _ticketCap Maximum number of tickets
    /// @param _sellerMin Minimum funds required for success
    /// @param _startTime Start timestamp
    /// @param _endTime End timestamp
    /// @param _winnersCount Number of winners
    function initialize(
        address _seller,
        address _assetToken,
        uint256 _assetAmount,
        address _paymentToken,
        uint256 _ticketPrice,
        uint256 _ticketCap,
        uint256 _sellerMin,
        uint256 _startTime,
        uint256 _endTime,
        uint16 _winnersCount
    ) external {
        require(seller == address(0), "Raffle: already initialized");
        require(factory == address(0), "Raffle: factory already set");

        // Set factory to msg.sender (the factory contract)
        factory = msg.sender;
        require(_seller != address(0), "Raffle: invalid seller");
        require(_ticketPrice > 0, "Raffle: invalid ticket price");
        require(_ticketCap > 0, "Raffle: invalid ticket cap");
        require(_sellerMin > 0, "Raffle: invalid seller min");
        require(_startTime < _endTime, "Raffle: invalid time range");
        require(
            _winnersCount > 0 && _winnersCount <= _ticketCap,
            "Raffle: invalid winners count"
        );
        require(
            _winnersCount <= MAX_WINNERS_COUNT,
            "Raffle: winners count too high"
        );
        require(
            _ticketPrice * _ticketCap == _sellerMin,
            "Raffle: invalid ticket price"
        );
        require(_paymentToken != address(0), "Raffle: invalid payment token");
        require(_assetToken != address(0), "Raffle: invalid asset token");
        require(_assetAmount > 0, "Raffle: invalid asset amount");

        seller = _seller;
        assetToken = _assetToken;
        assetAmount = _assetAmount;
        paymentToken = _paymentToken;
        ticketPrice = _ticketPrice;
        ticketCap = _ticketCap;
        sellerMin = _sellerMin;
        startTime = _startTime;
        endTime = _endTime;
        winnersCount = _winnersCount;

        emit Initialized(
            _seller,
            _assetToken,
            _assetAmount,
            _paymentToken,
            _ticketPrice,
            _ticketCap,
            _sellerMin,
            _startTime,
            _endTime,
            _winnersCount
        );
    }

    // ============ Public Functions ============
    /// @notice Buy tickets (ERC20 only - use WETH for native ETH)
    /// @param n Number of tickets to buy
    /// @param recipient Address to assign tickets to (address(0) to use msg.sender)
    function buyTickets(
        uint256 n,
        address recipient
    ) external onlyActive nonReentrant {
        require(n > 0, "Raffle: invalid amount");
        require(totalTickets + n <= ticketCap, "Raffle: exceeds cap");
        address buyer = msg.sender;
        if (recipient != address(0)) {
            buyer = recipient;
        }
        require(
            tickets[buyer] + n <= MAX_TICKETS_PER_ADDRESS,
            "Raffle: exceeds per-address limit"
        );

        uint256 cost = ticketPrice * n;
        require(totalFunds + cost <= sellerMin, "Raffle: exceeds sellerMin");

        totalTickets += n;
        tickets[buyer] += n;
        for (uint256 i = 0; i < n; i++) {
            ticketHolders.push(buyer);
        }
        // Payment always comes from msg.sender (the caller), not the recipient
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), cost);
        totalFunds += cost;

        emit TicketsPurchased(buyer, n, totalTickets);
    }

    /// @notice Finalize the raffle (anyone can call after endTime)
    function finalize() external onlyAfterEnd nonReentrant {
        require(!finalized, "Raffle: already finalized");

        finalized = true;
        // Raffle succeeds only if totalFunds exactly equals sellerMin by endTime
        // This is a design decision: all tickets must be sold for success (all-or-nothing)
        // Time-based check: if endTime has passed and totalFunds < sellerMin, it has failed
        _succeededState = _succeeded();

        if (_succeededState) {
            finalizationBlock = block.number;
            // Calculate protocol fee (from factory)
            uint256 feeBps = RaffleFactory(factory).feeBps();
            uint256 protocolFee = (totalFunds * feeBps) / 10000;
            uint256 sellerPayout = totalFunds - protocolFee;

            pendingWithdrawals[seller] = sellerPayout;

            // Send protocol fee to fee recipient
            address feeRecipient = RaffleFactory(factory).feeRecipient();
            if (protocolFee > 0 && feeRecipient != address(0)) {
                IERC20(paymentToken).safeTransfer(feeRecipient, protocolFee);
            }

            // Pick winners immediately using past blocks (no waiting required)
            _pickWinners();
        }

        emit Finalized(_succeededState, totalFunds);
    }

    /// @notice Claim refund (for losers when raffle failed)
    function claimRefund() external nonReentrant {
        require(!_succeeded(), "Raffle: raffle succeeded");
        require(tickets[msg.sender] > 0, "Raffle: no tickets");

        uint256 refundAmount = tickets[msg.sender] * ticketPrice;
        tickets[msg.sender] = 0; // Prevent double claim
        refundClaimedAllTickets[msg.sender] = true;

        IERC20(paymentToken).safeTransfer(msg.sender, refundAmount);

        emit RefundClaimed(msg.sender, refundAmount);
    }

    /// @notice Claim prize (for winners)
    /// @dev Winners are picked automatically during finalize(), so they should already be set
    function claimPrize() external nonReentrant {
        require(finalized, "Raffle: not finalized");
        require(_succeeded(), "Raffle: raffle failed");
        require(winnersSet, "Raffle: winners not set");
        require(winners.length > 0, "Raffle: winners not set");

        bool isWinner = false;
        for (uint256 i = 0; i < winners.length; i++) {
            if (winners[i] == msg.sender) {
                isWinner = true;
            }
        }
        require(isWinner, "Raffle: not a winner");

        uint256 prize = pendingWithdrawals[msg.sender];
        require(prize > 0, "Raffle: no prize to claim");
        pendingWithdrawals[msg.sender] = 0;
        prizeClaimedAll[msg.sender] = true;

        // Transfer asset to winner
        IERC20(assetToken).safeTransfer(msg.sender, prize);

        emit PrizeClaimed(msg.sender, prize);
    }

    /// @notice Withdraw seller proceeds
    function withdrawSeller() external nonReentrant {
        require(msg.sender == seller, "Raffle: not seller");
        require(finalized, "Raffle: not finalized");
        require(_succeeded(), "Raffle: raffle failed");

        uint256 amount = pendingWithdrawals[seller];
        require(amount > 0, "Raffle: nothing to withdraw");
        pendingWithdrawals[seller] = 0;

        // Transfer payment token proceeds to seller
        IERC20(paymentToken).safeTransfer(seller, amount);

        emit SellerWithdrawn(seller, amount);
    }

    /// @notice Withdraw asset by seller if raffle failed
    function withdrawAsset() external nonReentrant {
        require(msg.sender == seller, "Raffle: not seller");
        require(!_succeeded(), "Raffle: raffle succeeded");
        require(!assetWithdrawnBySeller, "Raffle: asset already withdrawn");

        // Transfer the full asset amount back to seller
        IERC20(assetToken).safeTransfer(seller, assetAmount);
        assetWithdrawnBySeller = true;

        emit AssetWithdrawn(seller, assetAmount);
    }

    // ============ View Functions ============
    /// @notice Get the number of tickets for an address
    function getTickets(address user) external view returns (uint256) {
        return tickets[user];
    }

    /// @notice Get all winners
    function getWinners() external view returns (address[] memory) {
        return winners;
    }

    /// @notice Frontend helper for per-user status flags
    function getUserFlags(
        address user
    )
        external
        view
        returns (
            bool refundClaimed,
            bool prizeClaimed,
            uint256 remainingTickets,
            uint256 pendingPrize
        )
    {
        refundClaimed = refundClaimedAllTickets[user];
        prizeClaimed = prizeClaimedAll[user];
        remainingTickets = tickets[user];
        pendingPrize = pendingWithdrawals[user];
    }

    /// @notice Check if raffle has failed based on time and funds
    /// @return True if endTime has passed and totalFunds < sellerMin
    function hasFailed() external view returns (bool) {
        if (finalized) {
            return !_succeededState;
        }
        // Time-based check: if endTime has passed and we haven't reached sellerMin, it has failed
        return (block.timestamp >= endTime) && (totalFunds < sellerMin);
    }

    /// @notice Check if raffle can be finalized (time-based)
    /// @return True if endTime has passed and not yet finalized
    function canFinalize() external view returns (bool) {
        return (block.timestamp >= endTime) && !finalized;
    }
    /// @notice Pick winners using blockhashes from past blocks
    /// @dev Uses consecutive blocks going backwards from finalization block
    /// @dev Note: Users with many tickets can win multiple times (by design)
    function _pickWinners() internal {
        // Ensure we have enough blocks before finalization
        require(
            finalizationBlock >= winnersCount,
            "Raffle: insufficient blocks"
        );

        // Calculate prize per winner (equal split)
        uint256 prizePerWinner = assetAmount / winnersCount;
        uint256 remainder = assetAmount % winnersCount;

        for (uint256 i = 0; i < winnersCount; i++) {
            // Use consecutive blocks going backwards: finalizationBlock - 1, finalizationBlock - 2, etc.
            bytes32 blockHash = blockhash(finalizationBlock - 1 - i);
            uint256 random = uint256(blockHash);
            random = random % totalTickets;

            // Handle collisions: if this ticket index already won, try next one
            // Note: After 3 attempts, we allow duplicate wins (users with many tickets can win multiple times)
            uint k = 0;
            while (winningIndex[random]) {
                random = (random + 1) % totalTickets;
                k++;
                if (k > 2) {
                    break; // Allow duplicate wins after 3 attempts
                }
            }

            winners.push(ticketHolders[random]);
            winningIndex[random] = true;
            uint256 prize = prizePerWinner;
            if (i < remainder) {
                prize += 1; // Distribute remainder to first winners
            }
            pendingWithdrawals[ticketHolders[random]] += prize;
        }

        emit WinnersSet(winners);
        winnersSet = true;
    }

    /// @notice Get succeeded status
    /// @return True if raffle succeeded (finalized and totalFunds == sellerMin)
    function succeeded() external view returns (bool) {
        if (finalized) {
            return _succeededState;
        }
        return _succeeded();
    }

    function _succeeded() internal view returns (bool) {
        if ((block.timestamp >= endTime)) {
            return (block.timestamp >= endTime) && (totalFunds == sellerMin);
        } else {
            return false;
        }
    }
}

// Forward declaration for factory interface
interface RaffleFactory {
    function feeBps() external view returns (uint256);
    function feeRecipient() external view returns (address);
}
