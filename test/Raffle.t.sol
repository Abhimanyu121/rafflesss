// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../src/Raffle.sol";
import {RaffleFactory} from "../src/RaffleFactory.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockRandomnessProvider} from "./mocks/MockRandomnessProvider.sol";

contract RaffleTest is Test {
    RaffleFactory public factory;
    Raffle public raffle;
    MockERC20 public assetToken;
    MockERC20 public paymentToken;
    MockRandomnessProvider public provider;

    address public owner = address(0x9);
    address public seller = address(0x1);
    address public buyer1 = address(0x2);
    address public buyer2 = address(0x3);
    address public buyer3 = address(0x4);
    address public feeRecipient = address(0x5);

    uint256 public constant ASSET_AMOUNT = 1000 * 10 ** 18;
    uint256 public constant TICKET_PRICE = 1 * 10 ** 18;
    uint256 public constant TICKET_CAP = 100;
    uint256 public constant SELLER_MIN = TICKET_PRICE * TICKET_CAP; // Must equal ticketPrice * ticketCap
    uint16 public constant WINNERS_COUNT = 3;
    uint256 public constant FEE_BPS = 200; // 2%

    /// @dev Seed the mock oracle hands out. Any non-zero value works.
    uint256 internal constant SEED = uint256(keccak256("raffle-test-seed"));

    function setUp() public {
        // A raffle may not start in the past, so tests need a sane clock.
        vm.warp(1_700_000_000);

        // Deploy tokens
        assetToken = new MockERC20("Asset Token", "ASSET");
        paymentToken = new MockERC20("Payment Token", "PAY");

        // Deploy the randomness source. A non-zero auto seed means every request
        // is answered immediately, which is the happy path for most tests.
        provider = new MockRandomnessProvider();
        provider.setAutoSeed(SEED);

        // Deploy factory
        factory = new RaffleFactory(owner, feeRecipient, FEE_BPS, address(provider));

        // Setup: mint tokens to seller
        assetToken.mint(seller, ASSET_AMOUNT);
        paymentToken.mint(buyer1, 1000 * 10 ** 18);
        paymentToken.mint(buyer2, 1000 * 10 ** 18);
        paymentToken.mint(buyer3, 1000 * 10 ** 18);
    }

    function test_CreateRaffle() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        vm.startPrank(seller);
        // Approve factory to transfer asset
        assetToken.approve(address(factory), ASSET_AMOUNT);

        address raffleAddr = factory.createRaffle(
            address(0), // raffleSeller: address(0) means use msg.sender
            address(assetToken),
            ASSET_AMOUNT,
            address(paymentToken),
            TICKET_PRICE,
            TICKET_CAP,
            SELLER_MIN,
            startTime,
            endTime,
            WINNERS_COUNT
        );

        raffle = Raffle(raffleAddr);
        assertEq(raffle.seller(), seller);
        assertEq(raffle.assetToken(), address(assetToken));
        assertEq(raffle.assetAmount(), ASSET_AMOUNT);
        assertEq(raffle.paymentToken(), address(paymentToken));
        assertEq(raffle.ticketPrice(), TICKET_PRICE);
        assertEq(raffle.ticketCap(), TICKET_CAP);
        assertEq(raffle.sellerMin(), SELLER_MIN);
        assertEq(raffle.winnersCount(), WINNERS_COUNT);
        assertEq(uint256(raffle.state()), uint256(Raffle.State.Active));
        assertEq(raffle.feeBps(), FEE_BPS);
        assertEq(raffle.feeRecipient(), feeRecipient);
        assertEq(address(raffle.randomnessProvider()), address(provider));
        assertTrue(factory.isRaffle(raffleAddr));
        vm.stopPrank();
    }

    function test_BuyTickets_ERC20() public {
        _createRaffle();

        uint256 ticketCount = 10;
        uint256 cost = TICKET_PRICE * ticketCount;

        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), cost);
        raffle.buyTickets(ticketCount, address(0));
        vm.stopPrank();

        assertEq(raffle.tickets(buyer1), ticketCount);
        assertEq(raffle.totalTickets(), ticketCount);
        assertEq(raffle.totalFunds(), cost);
        assertEq(raffle.getTicketHolderCount(), ticketCount);
    }

    function test_BuyTickets_WithRecipient() public {
        _createRaffle();

        uint256 ticketCount = 10;
        uint256 cost = TICKET_PRICE * ticketCount;

        // buyer1 buys tickets but specifies buyer2 as recipient
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), cost);
        raffle.buyTickets(ticketCount, buyer2);
        vm.stopPrank();

        // Verify that buyer2 (recipient) gets the tickets, not buyer1
        assertEq(raffle.tickets(buyer2), ticketCount);
        assertEq(raffle.tickets(buyer1), 0);
        assertEq(raffle.totalTickets(), ticketCount);
        assertEq(raffle.totalFunds(), cost);

        // Verify payment was taken from buyer1 (the caller)
        assertEq(paymentToken.balanceOf(buyer1), 1000 * 10 ** 18 - cost);
    }

    function test_BuyTickets_MultipleBuyers() public {
        _createRaffle();

        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 100 * TICKET_PRICE);
        raffle.buyTickets(20, address(0));
        vm.stopPrank();

        vm.startPrank(buyer2);
        paymentToken.approve(address(raffle), 100 * TICKET_PRICE);
        raffle.buyTickets(30, address(0));
        vm.stopPrank();

        assertEq(raffle.tickets(buyer1), 20);
        assertEq(raffle.tickets(buyer2), 30);
        assertEq(raffle.totalTickets(), 50);
    }

    function test_BuyTickets_RevertExceedsCap() public {
        _createRaffle();

        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 200 * TICKET_PRICE);
        vm.expectRevert("Raffle: exceeds cap");
        raffle.buyTickets(TICKET_CAP + 1, address(0));
        vm.stopPrank();
    }

    function test_BuyTickets_RevertExceedsSellerMin() public {
        _createRaffle();

        // Since sellerMin = ticketCap * ticketPrice, they're always equal
        // Buy all tickets except one
        uint256 ticketsToBuy = TICKET_CAP - 1; // 99 tickets
        uint256 cost = ticketsToBuy * TICKET_PRICE;

        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), cost);
        raffle.buyTickets(ticketsToBuy, address(0));
        vm.stopPrank();

        // Now try to buy 2 more tickets - this would exceed both cap and sellerMin
        // The cap check happens first, so it will fail on "exceeds cap"
        vm.startPrank(buyer2);
        paymentToken.approve(address(raffle), 2 * TICKET_PRICE);
        vm.expectRevert("Raffle: exceeds cap");
        raffle.buyTickets(2, address(0)); // Would make total 101, exceeding cap (and sellerMin)
        vm.stopPrank();
    }

    function test_BuyTickets_ExactSellerMin() public {
        _createRaffle();

        // Buy exactly sellerMin worth of tickets (which equals ticketCap)
        uint256 exactTickets = TICKET_CAP; // 100 tickets = sellerMin
        uint256 cost = exactTickets * TICKET_PRICE;

        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), cost);
        raffle.buyTickets(exactTickets, address(0));
        vm.stopPrank();

        assertEq(raffle.totalFunds(), SELLER_MIN);
        assertEq(raffle.totalTickets(), exactTickets);

        // Try to buy one more ticket - should fail on cap (since we've bought all tickets)
        vm.startPrank(buyer2);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: exceeds cap");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();
    }

    /// @dev Was test_BuyTickets_RevertNotActive. A raffle is Active from creation now,
    ///      so buying before startTime is rejected by the clock, not by the state.
    function test_BuyTickets_RevertBeforeStart() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        vm.startPrank(seller);
        // Approve factory to transfer asset
        assetToken.approve(address(factory), ASSET_AMOUNT);

        address raffleAddr = factory.createRaffle(
            address(0), // raffleSeller: address(0) means use msg.sender
            address(assetToken),
            ASSET_AMOUNT,
            address(paymentToken),
            TICKET_PRICE,
            TICKET_CAP,
            SELLER_MIN,
            startTime,
            endTime,
            WINNERS_COUNT
        );
        raffle = Raffle(raffleAddr);
        vm.stopPrank();

        // The raffle is Active, but selling has not opened yet.
        assertEq(uint256(raffle.state()), uint256(Raffle.State.Active));

        // Try before start (don't warp to startTime)
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: not started");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();
    }

    function test_BuyTickets_RevertAfterEndTime() public {
        _createRaffle();

        // Buy some tickets during active period
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 10 * TICKET_PRICE);
        raffle.buyTickets(10, address(0));
        vm.stopPrank();

        // Move time past endTime
        vm.warp(raffle.endTime() + 1);

        // Selling window is half-open, so this is rejected by the clock.
        vm.startPrank(buyer2);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: ended");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();
    }

    function test_BuyTickets_RevertAfterFinalized() public {
        _createRaffle();
        _buyEnoughTickets();
        _settle();

        // Try to buy tickets after settlement - the state check rejects it
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: not active");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();
    }

    function test_Finalize_Success() public {
        _createRaffle();
        _buyEnoughTickets();
        _settle();

        assertTrue(raffle.finalized());
        assertTrue(raffle.succeeded());
        assertEq(raffle.totalFunds(), SELLER_MIN); // Exact match required

        // The two payment-token ledgers split totalFunds exactly.
        uint256 expectedFee = (SELLER_MIN * FEE_BPS) / 10000;
        assertEq(raffle.protocolFeeOwed(), expectedFee);
        assertEq(raffle.sellerProceeds(), SELLER_MIN - expectedFee);
        assertEq(raffle.sellerProceeds() + raffle.protocolFeeOwed(), raffle.totalFunds());
    }

    function test_Finalize_Failure() public {
        _createRaffle();

        // Buy less than sellerMin
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 10 * TICKET_PRICE);
        raffle.buyTickets(10, address(0)); // Only 10 tokens, less than SELLER_MIN (100)
        vm.stopPrank();

        vm.warp(raffle.endTime() + 1);
        raffle.finalize();

        assertTrue(raffle.finalized());
        assertFalse(raffle.succeeded());
        assertTrue(raffle.hasFailed());
        // An undersold raffle never asks for randomness.
        assertEq(provider.requestCount(), 0);
    }

    /// @dev Was test_PickWinners_AutomaticallyDuringFinalize. finalize() no longer draws;
    ///      it only settles the sale and requests a seed. drawWinners() picks the winners.
    function test_PickWinners_DuringDrawWinners() public {
        _createRaffle();
        _buyEnoughTickets();

        vm.warp(raffle.endTime() + 1);
        raffle.finalize();

        // finalize() settles the sale only
        assertEq(uint256(raffle.state()), uint256(Raffle.State.RandomnessPending));
        assertEq(raffle.getWinners().length, 0);
        assertTrue(raffle.canDraw());

        raffle.drawWinners();

        address[] memory winners = raffle.getWinners();
        assertEq(winners.length, WINNERS_COUNT);
        assertEq(raffle.seed(), SEED);
        assertTrue(raffle.succeeded());
    }

    function test_ClaimPrize() public {
        _createRaffle();
        _buyEnoughTickets();
        _settle();

        address[] memory winners = raffle.getWinners();
        assertEq(winners.length, WINNERS_COUNT);

        // Find a winner and claim their prize
        address winner = winners[0];
        uint256 winnerBalanceBefore = assetToken.balanceOf(winner);
        uint256 prizePerWinner = ASSET_AMOUNT / WINNERS_COUNT;
        uint256 credited = raffle.pendingPrize(winner);
        assertGe(credited, prizePerWinner);

        vm.prank(winner);
        raffle.claimPrize();

        // Verify winner got exactly what was credited
        assertEq(assetToken.balanceOf(winner), winnerBalanceBefore + credited);
        assertEq(raffle.pendingPrize(winner), 0);
        assertTrue(raffle.prizeClaimed(winner));
    }

    function test_ClaimRefund() public {
        _createRaffle();

        // Buy tickets but raffle fails
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 10 * TICKET_PRICE);
        raffle.buyTickets(10, address(0));
        vm.stopPrank();

        vm.warp(raffle.endTime() + 1);
        raffle.finalize();

        uint256 refundAmount = 10 * TICKET_PRICE;
        uint256 balanceBefore = paymentToken.balanceOf(buyer1);

        vm.prank(buyer1);
        raffle.claimRefund();

        assertEq(paymentToken.balanceOf(buyer1), balanceBefore + refundAmount);
        assertEq(raffle.tickets(buyer1), 0);
        assertTrue(raffle.refundClaimed(buyer1));
    }

    function test_WithdrawAsset_FailedRaffle() public {
        _createRaffle();

        // Buy tickets but raffle fails
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 10 * TICKET_PRICE);
        raffle.buyTickets(10, address(0)); // Only 10 tokens, less than SELLER_MIN (100)
        vm.stopPrank();

        vm.warp(raffle.endTime() + 1);
        raffle.finalize();

        assertTrue(raffle.finalized());
        assertFalse(raffle.succeeded());

        // Seller withdraws asset
        uint256 assetBalanceBefore = assetToken.balanceOf(seller);
        uint256 raffleAssetBalanceBefore = assetToken.balanceOf(address(raffle));

        vm.prank(seller);
        raffle.withdrawAsset();

        assertEq(assetToken.balanceOf(seller), assetBalanceBefore + ASSET_AMOUNT);
        assertEq(assetToken.balanceOf(address(raffle)), raffleAssetBalanceBefore - ASSET_AMOUNT);
        assertTrue(raffle.assetWithdrawnBySeller());
    }

    function test_WithdrawAsset_RevertNotSeller() public {
        _createRaffle();

        // Buy tickets but raffle fails
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 10 * TICKET_PRICE);
        raffle.buyTickets(10, address(0));
        vm.stopPrank();

        vm.warp(raffle.endTime() + 1);
        raffle.finalize();

        vm.prank(buyer1);
        vm.expectRevert("Raffle: not seller");
        raffle.withdrawAsset();
    }

    function test_WithdrawAsset_RevertRaffleSucceeded() public {
        _createRaffle();
        _buyEnoughTickets();
        _settle();

        assertTrue(raffle.succeeded());

        vm.prank(seller);
        vm.expectRevert("Raffle: not failed");
        raffle.withdrawAsset();
    }

    function test_WithdrawSeller() public {
        _createRaffle();
        _buyEnoughTickets();
        _settle();

        uint256 calculatedPayout = raffle.totalFunds() - ((raffle.totalFunds() * FEE_BPS) / 10000);
        uint256 balanceBefore = paymentToken.balanceOf(seller);

        vm.prank(seller);
        raffle.withdrawSeller();

        assertEq(paymentToken.balanceOf(seller), balanceBefore + calculatedPayout);
        assertEq(raffle.sellerProceeds(), 0);
    }

    /// @dev Was test_HasFailed_TimeBased. hasFailed() reads the state now: the clock alone
    ///      never fails a raffle, someone has to settle it.
    function test_HasFailed_StateBased() public {
        _createRaffle();

        // Before endTime, should not be failed
        assertFalse(raffle.hasFailed());

        // Buy less than sellerMin
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 10 * TICKET_PRICE);
        raffle.buyTickets(10, address(0));
        vm.stopPrank();

        // Still before endTime, should not be failed
        assertFalse(raffle.hasFailed());

        // Past endTime but not settled: still Active, so still not failed.
        vm.warp(raffle.endTime() + 1);
        assertFalse(raffle.hasFailed());
        assertEq(uint256(raffle.state()), uint256(Raffle.State.Active));

        // Only finalization decides it
        raffle.finalize();
        assertTrue(raffle.hasFailed());
        assertFalse(raffle.succeeded());
    }

    function test_HasFailed_SuccessfulRaffle() public {
        _createRaffle();
        _buyEnoughTickets();

        // Before endTime, should not be failed
        assertFalse(raffle.hasFailed());

        // After endTime but not finalized, should not be failed (has enough funds)
        vm.warp(raffle.endTime() + 1);
        assertFalse(raffle.hasFailed());

        // After settlement, should show as succeeded
        raffle.finalize();
        raffle.drawWinners();
        assertFalse(raffle.hasFailed());
        assertTrue(raffle.succeeded());
    }

    /// @dev The boundary is no longer sidestepped: canFinalize() and finalize() agree at
    ///      exactly endTime.
    function test_CanFinalize() public {
        _createRaffle();

        // Before endTime, cannot finalize
        assertFalse(raffle.canFinalize());
        vm.warp(raffle.endTime() - 1);
        assertFalse(raffle.canFinalize());

        // Well after endTime, can finalize
        vm.warp(raffle.endTime() + 1 days);
        assertTrue(raffle.canFinalize());

        // And at exactly endTime, can finalize - and finalize() actually succeeds there
        vm.warp(raffle.endTime());
        assertTrue(raffle.canFinalize());
        raffle.finalize();
        assertTrue(raffle.finalized());

        // After finalization, cannot finalize again
        assertFalse(raffle.canFinalize());
    }

    /// @dev Was test_ReentrancyProtection, which never re-entered anything. It is a
    ///      double-claim test, named honestly.
    function test_ClaimPrize_SecondClaimReverts() public {
        _createRaffle();
        _buyEnoughTickets();
        _settle();

        address[] memory winners = raffle.getWinners();
        require(winners.length > 0, "No winners found");

        // Claim prize once (should succeed)
        vm.prank(winners[0]);
        raffle.claimPrize();

        // Now try to claim prize twice (should fail - already claimed)
        vm.prank(winners[0]);
        vm.expectRevert("Raffle: no prize to claim");
        raffle.claimPrize();
    }

    // ============ Helper Functions ============

    function _createRaffle() internal {
        raffle = _createRaffleWith(ASSET_AMOUNT, TICKET_PRICE, TICKET_CAP, WINNERS_COUNT);
    }

    /// @dev Creates a raffle owned by `seller`, mints the prize first, and warps to startTime.
    function _createRaffleWith(uint256 assetAmount_, uint256 ticketPrice_, uint256 ticketCap_, uint16 winnersCount_)
        internal
        returns (Raffle created)
    {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = startTime + 6 days;

        assetToken.mint(seller, assetAmount_);

        vm.startPrank(seller);
        // Approve factory to transfer asset
        assetToken.approve(address(factory), assetAmount_);

        address raffleAddr = factory.createRaffle(
            address(0), // raffleSeller: address(0) means use msg.sender
            address(assetToken),
            assetAmount_,
            address(paymentToken),
            ticketPrice_,
            ticketCap_,
            ticketPrice_ * ticketCap_,
            startTime,
            endTime,
            winnersCount_
        );
        vm.stopPrank();

        created = Raffle(raffleAddr);

        // Warp to start time so tickets can be sold
        vm.warp(startTime);
    }

    function _buy(Raffle target, address buyer, uint256 n) internal {
        uint256 cost = target.ticketPrice() * n;
        vm.startPrank(buyer);
        paymentToken.approve(address(target), cost);
        target.buyTickets(n, address(0));
        vm.stopPrank();
    }

    function _buyEnoughTickets() internal {
        // Buy exactly sellerMin amount (exact match required)
        // Since sellerMin = ticketPrice * ticketCap, we need to buy all tickets
        uint256 ticketsNeeded = TICKET_CAP; // Buy all tickets to reach sellerMin

        // Distribute tickets across buyers to reach exactly sellerMin
        uint256 ticketsPerBuyer = ticketsNeeded / 3; // 100 / 3 = 33 tickets each
        uint256 remainder = ticketsNeeded % 3; // 100 % 3 = 1 ticket remainder

        _buy(raffle, buyer1, ticketsPerBuyer + remainder); // 34 tickets
        _buy(raffle, buyer2, ticketsPerBuyer); // 33 tickets
        _buy(raffle, buyer3, ticketsPerBuyer); // 33 tickets
        // Total: 34 + 33 + 33 = 100 tickets = exactly SELLER_MIN (ticketPrice * ticketCap)
    }

    /// @dev Settle the sale only. Winners are not picked here any more.
    function _finalize() internal {
        vm.warp(raffle.endTime() + 1);
        raffle.finalize();
    }

    /// @dev The full settlement: finalize, then draw with the seed the mock oracle
    ///      already handed over.
    function _settle() internal {
        _finalize();
        raffle.drawWinners();
    }

    function test_CreateRaffle_WithCustomSeller() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;
        address customSeller = address(0x10);

        // Mint assets to customSeller (the prize is pulled from the caller)
        assetToken.mint(customSeller, ASSET_AMOUNT);

        vm.startPrank(customSeller);
        // Approve factory to transfer asset from customSeller
        assetToken.approve(address(factory), ASSET_AMOUNT);

        address raffleAddr = factory.createRaffle(
            customSeller, // naming yourself is allowed; naming a third party is not
            address(assetToken),
            ASSET_AMOUNT,
            address(paymentToken),
            TICKET_PRICE,
            TICKET_CAP,
            SELLER_MIN,
            startTime,
            endTime,
            WINNERS_COUNT
        );
        vm.stopPrank();

        raffle = Raffle(raffleAddr);
        assertEq(raffle.seller(), customSeller);
        assertTrue(factory.isRaffle(raffleAddr));
    }

    function test_CreateRaffle_WithCustomSeller_WithdrawWorks() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;
        address customSeller = address(0x10);

        // Mint assets to customSeller (the prize is pulled from the caller)
        assetToken.mint(customSeller, ASSET_AMOUNT);

        vm.startPrank(customSeller);
        // Approve factory to transfer asset from customSeller
        assetToken.approve(address(factory), ASSET_AMOUNT);

        address raffleAddr = factory.createRaffle(
            customSeller, // Custom seller address
            address(assetToken),
            ASSET_AMOUNT,
            address(paymentToken),
            TICKET_PRICE,
            TICKET_CAP,
            SELLER_MIN,
            startTime,
            endTime,
            WINNERS_COUNT
        );
        vm.stopPrank();

        raffle = Raffle(raffleAddr);
        assertEq(raffle.seller(), customSeller);

        // Warp to start time
        vm.warp(startTime);
        _buyEnoughTickets();
        _settle();

        // Custom seller should be able to withdraw
        uint256 calculatedPayout = raffle.totalFunds() - ((raffle.totalFunds() * FEE_BPS) / 10000);
        uint256 balanceBefore = paymentToken.balanceOf(customSeller);

        vm.prank(customSeller);
        raffle.withdrawSeller();

        assertEq(paymentToken.balanceOf(customSeller), balanceBefore + calculatedPayout);
        assertEq(raffle.sellerProceeds(), 0);
    }

    // ============ Missing Test Cases ============

    function test_DoublePrizeClaim_Revert() public {
        _createRaffle();
        _buyEnoughTickets();
        _settle();

        address[] memory winners = raffle.getWinners();
        require(winners.length > 0, "No winners");

        address winner = winners[0];
        uint256 prize = raffle.pendingPrize(winner);
        require(prize > 0, "No prize");

        // First claim should succeed
        vm.prank(winner);
        raffle.claimPrize();

        // Second claim should fail
        vm.prank(winner);
        vm.expectRevert("Raffle: no prize to claim");
        raffle.claimPrize();
    }

    function test_MultipleWithdrawAsset_Revert() public {
        _createRaffle();

        // Buy tickets but raffle fails
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 10 * TICKET_PRICE);
        raffle.buyTickets(10, address(0));
        vm.stopPrank();

        vm.warp(raffle.endTime() + 1);
        raffle.finalize();

        assertTrue(raffle.finalized());
        assertFalse(raffle.succeeded());

        // First withdrawal should succeed
        vm.prank(seller);
        raffle.withdrawAsset();

        // Second withdrawal is refused by the flag, which is set before the transfer
        vm.prank(seller);
        vm.expectRevert("Raffle: asset already withdrawn");
        raffle.withdrawAsset();
    }

    function test_SameWinnerWinsMultipleTimes() public {
        _createRaffle();

        // One buyer buys all tickets
        _buy(raffle, buyer1, TICKET_CAP);

        _settle();

        // Since buyer1 owns all tickets, they win every slot: distinct tickets,
        // same address, which is the documented behaviour.
        address[] memory winners = raffle.getWinners();
        assertEq(winners.length, WINNERS_COUNT);

        uint256 buyer1Wins = 0;
        for (uint256 i = 0; i < winners.length; i++) {
            if (winners[i] == buyer1) {
                buyer1Wins++;
            }
        }

        assertEq(buyer1Wins, WINNERS_COUNT);
        // Every share lands in one ledger entry.
        assertEq(raffle.pendingPrize(buyer1), ASSET_AMOUNT);
    }

    function test_FinalizeCalledTwice_Revert() public {
        _createRaffle();
        _buyEnoughTickets();
        _settle();

        // Try to finalize again - the raffle is no longer Active
        vm.expectRevert("Raffle: not active");
        raffle.finalize();
    }

    /// @dev Was test_BuyTicketsAtExactEndTime, which asserted a purchase AT endTime
    ///      succeeded. The window is half-open now, so endTime is a hard stop.
    function test_BuyTickets_RevertAtAndAfterEndTime() public {
        _createRaffle();

        // At exact endTime: rejected
        vm.warp(raffle.endTime());
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: ended");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();

        assertEq(raffle.tickets(buyer1), 0);

        // After endTime: also rejected
        vm.warp(raffle.endTime() + 1);
        vm.startPrank(buyer2);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: ended");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();
    }

    function test_MaxWinnersCount() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        vm.startPrank(seller);
        assetToken.approve(address(factory), ASSET_AMOUNT);

        // Try to create raffle with winnersCount > MAX_WINNERS_COUNT (200)
        vm.expectRevert("Raffle: winners count too high");
        factory.createRaffle(
            address(0),
            address(assetToken),
            ASSET_AMOUNT,
            address(paymentToken),
            TICKET_PRICE,
            300, // ticketCap
            300 * TICKET_PRICE, // sellerMin
            startTime,
            endTime,
            201 // winnersCount > MAX_WINNERS_COUNT
        );
        vm.stopPrank();
    }

    function test_RefundAndAssetWithdrawal_FailedRaffle() public {
        _createRaffle();

        // Buy tickets but raffle fails
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 10 * TICKET_PRICE);
        raffle.buyTickets(10, address(0));
        vm.stopPrank();

        vm.warp(raffle.endTime() + 1);
        raffle.finalize();

        assertTrue(raffle.finalized());
        assertFalse(raffle.succeeded());

        // Buyer claims refund
        uint256 buyerBalanceBefore = paymentToken.balanceOf(buyer1);
        vm.prank(buyer1);
        raffle.claimRefund();
        assertEq(paymentToken.balanceOf(buyer1), buyerBalanceBefore + 10 * TICKET_PRICE);

        // Seller withdraws asset
        uint256 sellerBalanceBefore = assetToken.balanceOf(seller);
        vm.prank(seller);
        raffle.withdrawAsset();
        assertEq(assetToken.balanceOf(seller), sellerBalanceBefore + ASSET_AMOUNT);
    }

    function test_AllWinnersClaimPrizes() public {
        _createRaffle();
        _buyEnoughTickets();
        _settle();

        address[] memory winners = raffle.getWinners();
        assertEq(winners.length, WINNERS_COUNT);

        uint256 totalPrizeClaimed = 0;

        // All winners claim their prizes
        // Note: an address can hold several winning tickets, so collect unique winners
        address[] memory uniqueWinners = new address[](WINNERS_COUNT);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < winners.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueWinners[j] == winners[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                uniqueWinners[uniqueCount] = winners[i];
                uniqueCount++;
            }
        }

        // Claim prizes for unique winners
        for (uint256 i = 0; i < uniqueCount; i++) {
            address winner = uniqueWinners[i];
            uint256 balanceBefore = assetToken.balanceOf(winner);
            uint256 prize = raffle.pendingPrize(winner);
            if (prize > 0) {
                vm.prank(winner);
                raffle.claimPrize();

                uint256 balanceAfter = assetToken.balanceOf(winner);
                assertEq(balanceAfter - balanceBefore, prize);
                totalPrizeClaimed += prize;
            }
        }

        // Total prizes claimed should equal assetAmount
        assertEq(totalPrizeClaimed, ASSET_AMOUNT);
        // And the raffle keeps none of the prize
        assertEq(assetToken.balanceOf(address(raffle)), 0);
    }

    function test_CreateRaffleWithCustomSeller_AssetTransfer() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;
        address customSeller = address(0x10);

        // Mint assets to customSeller (the prize is pulled from the caller)
        assetToken.mint(customSeller, ASSET_AMOUNT);

        vm.startPrank(customSeller);
        // Approve factory to transfer from customSeller
        assetToken.approve(address(factory), ASSET_AMOUNT);

        // Create raffle with customSeller
        address raffleAddr = factory.createRaffle(
            customSeller, // Custom seller
            address(assetToken),
            ASSET_AMOUNT,
            address(paymentToken),
            TICKET_PRICE,
            TICKET_CAP,
            SELLER_MIN,
            startTime,
            endTime,
            WINNERS_COUNT
        );
        vm.stopPrank();

        raffle = Raffle(raffleAddr);
        assertEq(raffle.seller(), customSeller);
        // Asset should be transferred from customSeller
        assertEq(assetToken.balanceOf(raffleAddr), ASSET_AMOUNT);
    }

    function test_Flags_RefundClaimed_FlipsOnlyAfterRefundClaim() public {
        _createRaffle();

        // Failed raffle setup
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 10 * TICKET_PRICE);
        raffle.buyTickets(10, address(0));
        vm.stopPrank();

        vm.warp(raffle.endTime() + 1);
        raffle.finalize();

        // Before claim: refund flag should be false
        assertFalse(raffle.refundClaimed(buyer1));
        (
            bool refundClaimedBefore,
            bool prizeClaimedBefore,
            uint256 remainingTicketsBefore,
            uint256 pendingPrizeBefore
        ) = raffle.getUserFlags(buyer1);
        assertFalse(refundClaimedBefore);
        assertFalse(prizeClaimedBefore);
        assertEq(remainingTicketsBefore, 10);
        assertEq(pendingPrizeBefore, 0);

        // Claim refund -> flag should flip
        vm.prank(buyer1);
        raffle.claimRefund();

        assertTrue(raffle.refundClaimed(buyer1));
        (bool refundClaimedAfter, bool prizeClaimedAfter, uint256 remainingTicketsAfter, uint256 pendingPrizeAfter) =
            raffle.getUserFlags(buyer1);
        assertTrue(refundClaimedAfter);
        assertFalse(prizeClaimedAfter);
        assertEq(remainingTicketsAfter, 0);
        assertEq(pendingPrizeAfter, 0);
    }

    function test_Flags_PrizeClaimed_FlipsOnlyAfterPrizeClaim() public {
        _createRaffle();
        _buyEnoughTickets();
        _settle();

        address winner = raffle.getWinners()[0];

        // Before claim: prize flag should be false
        assertFalse(raffle.prizeClaimed(winner));
        (
            bool refundClaimedBefore,
            bool prizeClaimedBefore,
            uint256 remainingTicketsBefore,
            uint256 pendingPrizeBefore
        ) = raffle.getUserFlags(winner);
        assertFalse(refundClaimedBefore);
        assertFalse(prizeClaimedBefore);
        assertGt(remainingTicketsBefore, 0);
        assertGt(pendingPrizeBefore, 0);

        // Claim prize -> flag should flip
        vm.prank(winner);
        raffle.claimPrize();

        assertTrue(raffle.prizeClaimed(winner));
        (bool refundClaimedAfter, bool prizeClaimedAfter, uint256 remainingTicketsAfter, uint256 pendingPrizeAfter) =
            raffle.getUserFlags(winner);
        assertFalse(refundClaimedAfter);
        assertTrue(prizeClaimedAfter);
        assertGt(remainingTicketsAfter, 0); // ticket ownership doesn't change on prize claim
        assertEq(pendingPrizeAfter, 0);
    }

    function test_Flags_AssetWithdrawnBySeller_FlipsOnlyAfterWithdraw() public {
        _createRaffle();

        // Failed raffle setup
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 10 * TICKET_PRICE);
        raffle.buyTickets(10, address(0));
        vm.stopPrank();

        vm.warp(raffle.endTime() + 1);
        raffle.finalize();

        // Before seller withdraw: flag should be false
        assertFalse(raffle.assetWithdrawnBySeller());

        // Seller withdraws asset -> flag flips
        vm.prank(seller);
        raffle.withdrawAsset();
        assertTrue(raffle.assetWithdrawnBySeller());

        // Cannot withdraw twice
        vm.prank(seller);
        vm.expectRevert("Raffle: asset already withdrawn");
        raffle.withdrawAsset();
    }

    // ============ New behaviour introduced by the rewrite ============

    /// @notice finalize() is accepted at exactly endTime, the instant selling stops.
    function test_Finalize_AtExactEndTime() public {
        _createRaffle();
        _buyEnoughTickets();

        vm.warp(raffle.endTime());
        assertTrue(raffle.canFinalize());

        raffle.finalize();

        assertEq(uint256(raffle.state()), uint256(Raffle.State.RandomnessPending));
        assertEq(raffle.randomnessRequestedAt(), raffle.endTime());
        assertTrue(raffle.randomnessRequestId() != bytes32(0));
    }

    /// @notice The selling window is [startTime, endTime): buying AT endTime is refused.
    function test_BuyTickets_RevertAtEndTime() public {
        _createRaffle();

        // One second before endTime the purchase is fine
        vm.warp(raffle.endTime() - 1);
        _buy(raffle, buyer1, 1);
        assertEq(raffle.tickets(buyer1), 1);

        // At endTime it is not
        vm.warp(raffle.endTime());
        vm.startPrank(buyer2);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: ended");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();

        assertEq(raffle.totalTickets(), 1);
    }

    /// @notice Without a seed there is nothing to draw from, and drawWinners() says so.
    function test_DrawWinners_RevertWhenRandomnessNotReady() public {
        provider.setAutoSeed(0); // the oracle answers later, not immediately

        _createRaffle();
        _buyEnoughTickets();
        _finalize();

        assertEq(uint256(raffle.state()), uint256(Raffle.State.RandomnessPending));
        assertFalse(raffle.canDraw());

        vm.expectRevert("Raffle: randomness not ready");
        raffle.drawWinners();

        // Once the oracle answers, the same call goes through
        provider.fulfillLast(SEED);
        assertTrue(raffle.canDraw());
        raffle.drawWinners();
        assertTrue(raffle.succeeded());
        assertEq(raffle.getWinners().length, WINNERS_COUNT);
    }

    /// @notice A seed that never arrives must not trap the money.
    function test_FailOnTimeout_OpensRefunds() public {
        provider.setAutoSeed(0);

        _createRaffle();
        _buyEnoughTickets();
        _finalize();

        assertEq(uint256(raffle.state()), uint256(Raffle.State.RandomnessPending));

        // Too early: the wait is still on
        vm.expectRevert("Raffle: not timed out");
        raffle.failOnTimeout();

        vm.warp(raffle.randomnessRequestedAt() + raffle.RANDOMNESS_TIMEOUT() + 1);
        raffle.failOnTimeout();

        assertTrue(raffle.hasFailed());
        assertTrue(raffle.finalized());

        // Every buyer gets exactly what they paid
        _assertRefund(buyer1, 34);
        _assertRefund(buyer2, 33);
        _assertRefund(buyer3, 33);
        assertEq(paymentToken.balanceOf(address(raffle)), 0);

        // And the seller gets the prize back
        uint256 sellerAssetBefore = assetToken.balanceOf(seller);
        vm.prank(seller);
        raffle.withdrawAsset();
        assertEq(assetToken.balanceOf(seller), sellerAssetBefore + ASSET_AMOUNT);
        assertEq(assetToken.balanceOf(address(raffle)), 0);
    }

    /// @notice "Nobody bothered to settle it" must not become a permanent hole either.
    function test_FailIfAbandoned_OpensRefunds() public {
        _createRaffle();
        _buyEnoughTickets(); // sold out: finalize() would have succeeded

        // Grace period not yet elapsed
        vm.warp(raffle.endTime() + raffle.FINALIZE_GRACE());
        vm.expectRevert("Raffle: grace not elapsed");
        raffle.failIfAbandoned();

        vm.warp(raffle.endTime() + raffle.FINALIZE_GRACE() + 1);
        raffle.failIfAbandoned();

        assertTrue(raffle.hasFailed());
        assertEq(raffle.getWinners().length, 0);

        _assertRefund(buyer1, 34);
        _assertRefund(buyer2, 33);
        _assertRefund(buyer3, 33);
        assertEq(paymentToken.balanceOf(address(raffle)), 0);

        uint256 sellerAssetBefore = assetToken.balanceOf(seller);
        vm.prank(seller);
        raffle.withdrawAsset();
        assertEq(assetToken.balanceOf(seller), sellerAssetBefore + ASSET_AMOUNT);
    }

    /// @notice The seller can call off a raffle nobody has bought into, and only then.
    function test_Cancel_OnlyWhenEmpty() public {
        Raffle empty = _createRaffleWith(ASSET_AMOUNT, TICKET_PRICE, TICKET_CAP, WINNERS_COUNT);

        // Not the seller's raffle to cancel
        vm.prank(buyer1);
        vm.expectRevert("Raffle: not seller");
        empty.cancel();

        uint256 sellerAssetBefore = assetToken.balanceOf(seller);
        vm.prank(seller);
        empty.cancel();

        assertTrue(empty.hasFailed());
        assertEq(uint256(empty.state()), uint256(Raffle.State.Failed));

        vm.prank(seller);
        empty.withdrawAsset();
        assertEq(assetToken.balanceOf(seller), sellerAssetBefore + ASSET_AMOUNT);

        // A raffle with a single ticket sold can no longer be called off
        Raffle sold = _createRaffleWith(ASSET_AMOUNT, TICKET_PRICE, TICKET_CAP, WINNERS_COUNT);
        _buy(sold, buyer1, 1);

        vm.prank(seller);
        vm.expectRevert("Raffle: tickets already sold");
        sold.cancel();

        assertEq(uint256(sold.state()), uint256(Raffle.State.Active));
    }

    /// @notice Regression test for the old collision bug: when every ticket wins, every
    ///         ticket index must be drawn exactly once.
    function test_NoTicketIndexWinsTwice() public {
        uint256 cap = 5;
        uint16 winners_ = 5;
        Raffle r = _createRaffleWith(
            5 * 10 ** 18, // assetAmount, divisible by 5
            TICKET_PRICE,
            cap,
            winners_
        );

        address[5] memory holders = [address(0x101), address(0x102), address(0x103), address(0x104), address(0x105)];
        for (uint256 i = 0; i < holders.length; i++) {
            paymentToken.mint(holders[i], TICKET_PRICE);
            _buy(r, holders[i], 1);
        }

        vm.warp(r.endTime());
        r.finalize();
        r.drawWinners();

        address[] memory winners = r.getWinners();
        assertEq(winners.length, winners_);

        // Each of the five distinct holders must appear exactly once
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 appearances = 0;
            for (uint256 j = 0; j < winners.length; j++) {
                if (winners[j] == holders[i]) appearances++;
            }
            assertEq(appearances, 1);
        }

        // And every one of them can actually collect an equal share
        uint256 share = (5 * 10 ** 18) / winners_;
        for (uint256 i = 0; i < holders.length; i++) {
            assertEq(r.pendingPrize(holders[i]), share);
            uint256 before = assetToken.balanceOf(holders[i]);
            vm.prank(holders[i]);
            r.claimPrize();
            assertEq(assetToken.balanceOf(holders[i]), before + share);
        }
        assertEq(assetToken.balanceOf(address(r)), 0);
    }

    /// @notice A seller who buys a ticket and wins is paid from two separate ledgers,
    ///         in two separate tokens, and neither one eats the other.
    function test_SellerWinsPrize_LedgersStaySeparate() public {
        uint256 prize = 10 * 10 ** 18;
        Raffle r = _createRaffleWith(prize, TICKET_PRICE, 1, 1); // one ticket, one winner

        paymentToken.mint(seller, TICKET_PRICE);
        _buy(r, seller, 1);

        vm.warp(r.endTime());
        r.finalize();
        r.drawWinners();

        assertEq(r.getWinners().length, 1);
        assertEq(r.getWinners()[0], seller);

        uint256 expectedFee = (TICKET_PRICE * FEE_BPS) / 10000;
        uint256 expectedProceeds = TICKET_PRICE - expectedFee;
        assertEq(r.pendingPrize(seller), prize);
        assertEq(r.sellerProceeds(), expectedProceeds);

        // Prize: paid in the asset token, exactly the prize share
        uint256 assetBefore = assetToken.balanceOf(seller);
        uint256 payBefore = paymentToken.balanceOf(seller);
        vm.prank(seller);
        r.claimPrize();
        assertEq(assetToken.balanceOf(seller), assetBefore + prize);
        assertEq(paymentToken.balanceOf(seller), payBefore); // untouched

        // Proceeds: paid in the payment token, exactly the proceeds
        assetBefore = assetToken.balanceOf(seller);
        vm.prank(seller);
        r.withdrawSeller();
        assertEq(paymentToken.balanceOf(seller), payBefore + expectedProceeds);
        assertEq(assetToken.balanceOf(seller), assetBefore); // untouched

        assertEq(r.pendingPrize(seller), 0);
        assertEq(r.sellerProceeds(), 0);
        // Only the unclaimed protocol fee is left behind
        assertEq(paymentToken.balanceOf(address(r)), expectedFee);
    }

    /// @notice Settlement pushes nothing to the fee recipient; the fee is pulled.
    function test_WithdrawFee_IsPullBased() public {
        _createRaffle();
        _buyEnoughTickets();

        uint256 feeBalanceBefore = paymentToken.balanceOf(feeRecipient);
        _settle();

        uint256 expectedFee = (SELLER_MIN * FEE_BPS) / 10000;
        assertGt(expectedFee, 0);

        // Nothing moved during settlement
        assertEq(paymentToken.balanceOf(feeRecipient), feeBalanceBefore);
        assertEq(raffle.protocolFeeOwed(), expectedFee);

        // Anyone may push the pull through; it always pays the frozen recipient
        vm.prank(buyer1);
        raffle.withdrawFee();

        assertEq(paymentToken.balanceOf(feeRecipient), feeBalanceBefore + expectedFee);
        assertEq(raffle.protocolFeeOwed(), 0);

        // And only once
        vm.expectRevert("Raffle: no fee to withdraw");
        raffle.withdrawFee();
    }

    /// @notice recoverToken can never touch the prize or the payments.
    function test_RecoverToken_RejectsProtectedTokens() public {
        _createRaffle();
        _buy(raffle, buyer1, 10); // give the raffle a payment-token balance too

        vm.prank(seller);
        vm.expectRevert("Raffle: protected token");
        raffle.recoverToken(address(assetToken), seller);

        vm.prank(seller);
        vm.expectRevert("Raffle: protected token");
        raffle.recoverToken(address(paymentToken), seller);

        // Balances are untouched
        assertEq(assetToken.balanceOf(address(raffle)), ASSET_AMOUNT);
        assertEq(paymentToken.balanceOf(address(raffle)), 10 * TICKET_PRICE);

        // A stray third token can be rescued
        MockERC20 stray = new MockERC20("Stray", "STRAY");
        stray.mint(address(raffle), 42 ether);

        vm.prank(buyer1);
        vm.expectRevert("Raffle: not seller");
        raffle.recoverToken(address(stray), buyer1);

        vm.prank(seller);
        raffle.recoverToken(address(stray), seller);

        assertEq(stray.balanceOf(seller), 42 ether);
        assertEq(stray.balanceOf(address(raffle)), 0);
    }

    // ============ Shared assertions ============

    function _assertRefund(address buyer, uint256 ticketCount) internal {
        uint256 before = paymentToken.balanceOf(buyer);
        vm.prank(buyer);
        raffle.claimRefund();
        assertEq(paymentToken.balanceOf(buyer), before + ticketCount * TICKET_PRICE);
        assertEq(raffle.tickets(buyer), 0);
        assertTrue(raffle.refundClaimed(buyer));
    }
}
