// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IRandomnessProvider} from "./interfaces/IRandomnessProvider.sol";

/// @title Raffle
/// @notice One sale of a fixed number of tickets for one prize.
/// @dev Deployed once as an implementation; each raffle is an EIP-1167 clone of it.
///      Vocabulary is in CONTEXT.md, rationale in docs/security/DECISIONS.md.
contract Raffle is ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;

    // ============ Types ============

    /// @dev Uninitialized is first because clone storage begins as all zeroes.
    enum State {
        Uninitialized,
        Active,
        RandomnessPending,
        Succeeded,
        Failed
    }

    /// @dev Grouped to keep initialize() within stack limits.
    struct RaffleParams {
        address seller;
        address assetToken;
        uint256 assetAmount;
        address paymentToken;
        uint256 ticketPrice;
        uint256 ticketCap;
        uint256 sellerMin;
        uint256 startTime;
        uint256 endTime;
        uint16 winnersCount;
        uint256 feeBps;
        address feeRecipient;
        address randomnessProvider;
    }

    // ============ Constants ============

    /// @notice Upper bound on winners. A full draw costs about 6M gas at this ceiling;
    ///         a draw too large to fit in a block would strand the raffle.
    uint256 public constant MAX_WINNERS_COUNT = 100;
    /// @notice Ceiling on the protocol fee, mirroring the factory's own cap.
    uint256 public constant MAX_FEE_BPS = 1000; // 10%
    /// @notice Shortest permitted gap between start and end.
    uint256 public constant MIN_DURATION = 10 minutes;
    /// @notice How long a raffle waits for its seed before anyone may fail it.
    uint256 public constant RANDOMNESS_TIMEOUT = 1 days;
    /// @notice How long past the deadline an unsettled raffle may be failed by anyone.
    /// @dev Also the window a provider that reverts on request costs buyers.
    uint256 public constant FINALIZE_GRACE = 7 days;

    /// @notice Backstop: past this, failOnTimeout() fires even if a seed did arrive,
    ///         so a raffle whose draw cannot execute is refunded rather than stranded.
    uint256 public constant DRAW_DEADLINE = 30 days;

    // ============ Immutable ============

    /// @dev Immutable lives in the implementation bytecode, so clones read it too.
    address public immutable FACTORY;

    // ============ Frozen terms ============

    address public seller;
    address public assetToken;
    uint256 public assetAmount;
    address public paymentToken;
    uint256 public ticketPrice;
    uint256 public ticketCap;
    uint256 public sellerMin;
    uint256 public startTime;
    uint256 public endTime;
    uint16 public winnersCount;

    /// @dev Frozen at creation, so factory changes never affect a live raffle.
    uint256 public feeBps;
    address public feeRecipient;
    IRandomnessProvider public randomnessProvider;

    // ============ Lifecycle ============

    State public state;

    // ============ Ticket accounting ============

    mapping(address => uint256) public tickets;
    address[] public ticketHolders;
    uint256 public totalTickets;
    uint256 public totalFunds;

    // ============ Randomness ============

    bytes32 public randomnessRequestId;
    uint256 public randomnessRequestedAt;
    uint256 public seed;

    // ============ Outcome ============

    address[] public winners;

    /// @dev One ledger per token. Never combined.
    uint256 public sellerProceeds; // payment token
    uint256 public protocolFeeOwed; // payment token
    mapping(address => uint256) public pendingPrize; // asset token

    bool public assetWithdrawnBySeller;
    mapping(address => bool) public refundClaimed;
    mapping(address => bool) public prizeClaimed;

    /// @dev Backs the without-replacement draw. Stores value+1; zero means
    ///      "this position still holds its own index".
    mapping(uint256 => uint256) private _swap;

    // ============ Events ============

    event RaffleInitialized(
        address indexed seller,
        address indexed assetToken,
        address indexed paymentToken,
        uint256 assetAmount,
        uint256 ticketPrice,
        uint256 ticketCap,
        uint256 startTime,
        uint256 endTime,
        uint16 winnersCount
    );
    /// @notice The terms copied from the factory and frozen on this raffle.
    event TermsFrozen(uint256 feeBps, address feeRecipient, address randomnessProvider);
    event TicketsPurchased(address indexed payer, address indexed holder, uint256 amount, uint256 totalTickets);
    event RandomnessRequested(bytes32 indexed requestId);
    event Finalized(bool indexed succeeded, uint256 totalFunds);
    event WinnersSet(address[] winners, uint256 seed);
    event RefundClaimed(address indexed claimer, uint256 amount);
    event PrizeClaimed(address indexed winner, uint256 amount);
    event SellerWithdrawn(address indexed seller, uint256 amount);
    event FeeWithdrawn(address indexed recipient, uint256 amount);
    event AssetWithdrawn(address indexed seller, uint256 amount);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    // ============ Constructor ============

    constructor(address factory_) {
        require(factory_ != address(0), "Raffle: invalid factory");
        FACTORY = factory_;
        _disableInitializers(); // the implementation must never be usable as a raffle
    }

    // ============ Initialization ============

    /// @notice Configure a freshly deployed clone. Callable once, by the factory only.
    function initialize(RaffleParams calldata p) external initializer {
        require(msg.sender == FACTORY, "Raffle: only factory");
        require(p.seller != address(0), "Raffle: invalid seller");
        require(p.assetToken.code.length > 0, "Raffle: asset token not a contract");
        require(p.paymentToken.code.length > 0, "Raffle: payment token not a contract");
        require(p.randomnessProvider != address(0), "Raffle: invalid provider");
        require(p.ticketPrice > 0, "Raffle: invalid ticket price");
        require(p.ticketCap > 0, "Raffle: invalid ticket cap");
        require(p.sellerMin > 0, "Raffle: invalid seller min");
        require(p.ticketPrice * p.ticketCap == p.sellerMin, "Raffle: sellerMin must equal price times cap");
        require(p.startTime >= block.timestamp, "Raffle: start in past");
        require(p.endTime >= p.startTime + MIN_DURATION, "Raffle: duration too short");
        require(p.winnersCount > 0 && p.winnersCount <= p.ticketCap, "Raffle: invalid winners count");
        require(p.winnersCount <= MAX_WINNERS_COUNT, "Raffle: winners count too high");
        require(p.assetAmount >= p.winnersCount, "Raffle: prize too small for winners");
        require(p.feeBps <= MAX_FEE_BPS, "Raffle: fee too high");
        require(p.feeRecipient != address(0), "Raffle: invalid fee recipient");

        seller = p.seller;
        assetToken = p.assetToken;
        assetAmount = p.assetAmount;
        paymentToken = p.paymentToken;
        ticketPrice = p.ticketPrice;
        ticketCap = p.ticketCap;
        sellerMin = p.sellerMin;
        startTime = p.startTime;
        endTime = p.endTime;
        winnersCount = p.winnersCount;
        feeBps = p.feeBps;
        feeRecipient = p.feeRecipient;
        randomnessProvider = IRandomnessProvider(p.randomnessProvider);

        state = State.Active;

        emit RaffleInitialized(
            p.seller,
            p.assetToken,
            p.paymentToken,
            p.assetAmount,
            p.ticketPrice,
            p.ticketCap,
            p.startTime,
            p.endTime,
            p.winnersCount
        );
        emit TermsFrozen(p.feeBps, p.feeRecipient, p.randomnessProvider);
    }

    // ============ Selling ============

    /// @notice Buy tickets. Payment always comes from the caller.
    /// @param n Number of tickets.
    /// @param recipient Address the tickets belong to; address(0) means the caller.
    function buyTickets(uint256 n, address recipient) external nonReentrant {
        require(state == State.Active, "Raffle: not active");
        require(block.timestamp >= startTime, "Raffle: not started");
        // Half-open [startTime, endTime), so selling and settling never overlap.
        require(block.timestamp < endTime, "Raffle: ended");
        require(n > 0, "Raffle: invalid amount");
        require(totalTickets + n <= ticketCap, "Raffle: exceeds cap");

        address holder = recipient == address(0) ? msg.sender : recipient;
        uint256 cost = ticketPrice * n;

        totalTickets += n;
        totalFunds += cost;
        tickets[holder] += n;
        for (uint256 i = 0; i < n; i++) {
            ticketHolders.push(holder);
        }

        // Credit only what actually arrives; a token that takes a cut is rejected.
        uint256 balanceBefore = IERC20(paymentToken).balanceOf(address(this));
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), cost);
        require(
            IERC20(paymentToken).balanceOf(address(this)) - balanceBefore == cost, "Raffle: unsupported payment token"
        );

        emit TicketsPurchased(msg.sender, holder, n, totalTickets);
    }

    // ============ Settlement ============

    /// @notice Settle whether the raffle sold out. Anyone may call, after the deadline.
    /// @dev Deliberately does not choose winners: the seed does not exist yet, so the
    ///      caller cannot influence the outcome by choosing when to send this.
    function finalize() external nonReentrant {
        require(state == State.Active, "Raffle: not active");
        require(block.timestamp >= endTime, "Raffle: not ended");

        if (totalFunds != sellerMin) {
            state = State.Failed;
            emit Finalized(false, totalFunds);
            return;
        }

        state = State.RandomnessPending;
        randomnessRequestedAt = block.timestamp;
        randomnessRequestId = randomnessProvider.requestRandomness(
            address(this), keccak256(abi.encode(address(this), totalTickets, totalFunds, endTime))
        );

        emit RandomnessRequested(randomnessRequestId);
    }

    /// @notice Draw the winners once the seed is available. Anyone may call.
    function drawWinners() external nonReentrant {
        require(state == State.RandomnessPending, "Raffle: not pending");

        uint256 s = randomnessProvider.getRandomness(randomnessRequestId);
        require(s != 0, "Raffle: randomness not ready");
        seed = s;

        _pickWinners(s);

        uint256 fee = (totalFunds * feeBps) / 10000;
        protocolFeeOwed = fee;
        sellerProceeds = totalFunds - fee;

        state = State.Succeeded;
        emit Finalized(true, totalFunds);
    }

    /// @notice Fail a raffle whose seed never arrived, so everyone can be repaid.
    function failOnTimeout() external {
        require(state == State.RandomnessPending, "Raffle: not pending");
        require(block.timestamp > randomnessRequestedAt + RANDOMNESS_TIMEOUT, "Raffle: not timed out");
        if (block.timestamp <= randomnessRequestedAt + DRAW_DEADLINE) {
            // A seed that did arrive must be drawn, not refunded, so the outcome
            // cannot depend on who called first.
            try randomnessProvider.getRandomness(randomnessRequestId) returns (uint256 available) {
                require(available == 0, "Raffle: randomness arrived, draw instead");
            } catch {
                // A provider that cannot answer a view is broken; failing is correct.
            }
        }
        state = State.Failed;
        emit Finalized(false, totalFunds);
    }

    /// @notice Fail a raffle nobody ever settled, so everyone can be repaid.
    /// @dev Anyone may finalize, so this is a last resort rather than a normal path.
    function failIfAbandoned() external {
        require(state == State.Active, "Raffle: not active");
        require(block.timestamp > endTime + FINALIZE_GRACE, "Raffle: grace not elapsed");
        state = State.Failed;
        emit Finalized(false, totalFunds);
    }

    /// @notice Seller calls off their own raffle before anyone has bought a ticket.
    function cancel() external {
        require(msg.sender == seller, "Raffle: not seller");
        require(state == State.Active, "Raffle: not active");
        require(totalTickets == 0, "Raffle: tickets already sold");
        state = State.Failed;
        emit Finalized(false, 0);
    }

    // ============ Claims (all pull-based, including the protocol fee) ============

    /// @notice Winners collect their share of the prize.
    function claimPrize() external nonReentrant {
        require(state == State.Succeeded, "Raffle: not succeeded");
        uint256 prize = pendingPrize[msg.sender];
        require(prize > 0, "Raffle: no prize to claim");

        pendingPrize[msg.sender] = 0;
        prizeClaimed[msg.sender] = true;

        _payOut(assetToken, msg.sender, prize);
        emit PrizeClaimed(msg.sender, prize);
    }

    /// @notice Buyers reclaim what they paid, once the raffle has failed.
    function claimRefund() external nonReentrant {
        require(state == State.Failed, "Raffle: not failed");
        uint256 n = tickets[msg.sender];
        require(n > 0, "Raffle: no tickets");

        tickets[msg.sender] = 0;
        refundClaimed[msg.sender] = true;
        uint256 amount = n * ticketPrice;

        _payOut(paymentToken, msg.sender, amount);
        emit RefundClaimed(msg.sender, amount);
    }

    /// @notice Seller collects the proceeds of a successful raffle.
    function withdrawSeller() external nonReentrant {
        require(msg.sender == seller, "Raffle: not seller");
        require(state == State.Succeeded, "Raffle: not succeeded");
        uint256 amount = sellerProceeds;
        require(amount > 0, "Raffle: nothing to withdraw");

        sellerProceeds = 0;
        _payOut(paymentToken, seller, amount);
        emit SellerWithdrawn(seller, amount);
    }

    /// @notice Send the protocol fee to the recipient frozen at creation. Anyone may call.
    /// @dev Pulled, not pushed, so a recipient that cannot receive never blocks the raffle.
    function withdrawFee() external nonReentrant {
        require(state == State.Succeeded, "Raffle: not succeeded");
        uint256 amount = protocolFeeOwed;
        require(amount > 0, "Raffle: no fee to withdraw");

        protocolFeeOwed = 0;
        _payOut(paymentToken, feeRecipient, amount);
        emit FeeWithdrawn(feeRecipient, amount);
    }

    /// @notice Seller reclaims the prize from a failed raffle.
    function withdrawAsset() external nonReentrant {
        require(msg.sender == seller, "Raffle: not seller");
        require(state == State.Failed, "Raffle: not failed");
        require(!assetWithdrawnBySeller, "Raffle: asset already withdrawn");

        assetWithdrawnBySeller = true;
        _payOut(assetToken, seller, assetAmount);
        emit AssetWithdrawn(seller, assetAmount);
    }

    /// @notice Rescue tokens sent here by mistake. Never the prize or the payments.
    function recoverToken(address token, address to) external nonReentrant {
        require(msg.sender == seller, "Raffle: not seller");
        require(token != assetToken && token != paymentToken, "Raffle: protected token");
        require(to != address(0), "Raffle: invalid recipient");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "Raffle: nothing to recover");

        IERC20(token).safeTransfer(to, balance);
        emit TokenRecovered(token, to, balance);
    }

    /// @dev Every liability is paid through here. This contract's own balance must fall by
    ///      exactly the amount owed: a token that debits more is spending another claimant's
    ///      escrow, and one that debits nothing would mark a debt settled that never moved.
    ///      Both revert with the ledger entry intact. What the receiver nets afterwards is the
    ///      token's business; what leaves this contract is ours.
    function _payOut(address token, address to, uint256 amount) private {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        require(IERC20(token).balanceOf(address(this)) + amount == balanceBefore, "Raffle: unsupported token transfer");
    }

    // ============ The draw ============

    /// @notice Draw `winnersCount` distinct tickets from one seed.
    /// @dev Partial Fisher-Yates over a virtual array, so only touched positions cost
    ///      storage. No ticket wins twice; an address holding several still can.
    function _pickWinners(uint256 s) internal {
        uint256 n = totalTickets;
        uint256 per = assetAmount / winnersCount;
        uint256 remainder = assetAmount % winnersCount;

        for (uint256 i = 0; i < winnersCount; i++) {
            // INVARIANT: j >= i, so position i is never read again and _swap[i] can be
            // skipped. Widen this range and the draw starts repeating tickets.
            uint256 j = i + (uint256(keccak256(abi.encode(s, i))) % (n - i));
            uint256 pick = _at(j);
            _swap[j] = _at(i) + 1;

            address winner = ticketHolders[pick];
            winners.push(winner);
            pendingPrize[winner] += per + (i < remainder ? 1 : 0);
        }

        emit WinnersSet(winners, s);
    }

    /// @dev Untouched positions hold their own index.
    function _at(uint256 i) private view returns (uint256) {
        uint256 v = _swap[i];
        return v == 0 ? i : v - 1;
    }

    // ============ Views ============

    function getTickets(address user) external view returns (uint256) {
        return tickets[user];
    }

    function getWinners() external view returns (address[] memory) {
        return winners;
    }

    function getTicketHolderCount() external view returns (uint256) {
        return ticketHolders.length;
    }

    /// @notice True once the raffle has settled either way.
    function finalized() external view returns (bool) {
        return state == State.Succeeded || state == State.Failed;
    }

    function succeeded() external view returns (bool) {
        return state == State.Succeeded;
    }

    function hasFailed() external view returns (bool) {
        return state == State.Failed;
    }

    /// @notice True when finalize() would be accepted right now.
    function canFinalize() external view returns (bool) {
        return state == State.Active && block.timestamp >= endTime;
    }

    /// @notice True when drawWinners() would be accepted right now.
    function canDraw() external view returns (bool) {
        if (state != State.RandomnessPending) return false;
        return randomnessProvider.getRandomness(randomnessRequestId) != 0;
    }

    /// @notice Frontend helper for per-user status.
    function getUserFlags(address user)
        external
        view
        returns (bool userRefundClaimed, bool userPrizeClaimed, uint256 remainingTickets, uint256 pendingPrizeAmount)
    {
        return (refundClaimed[user], prizeClaimed[user], tickets[user], pendingPrize[user]);
    }
}
