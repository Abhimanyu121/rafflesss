// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../src/Raffle.sol";
import {RaffleFactory} from "../src/RaffleFactory.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract RaffleTest is Test {
    RaffleFactory public factory;
    Raffle public raffle;
    MockERC20 public assetToken;
    MockERC20 public paymentToken;

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

    function setUp() public {
        // Deploy tokens
        assetToken = new MockERC20("Asset Token", "ASSET");
        paymentToken = new MockERC20("Payment Token", "PAY");

        // Deploy factory
        factory = new RaffleFactory(feeRecipient, FEE_BPS);

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

    function test_BuyTickets_RevertNotActive() public {
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

        // Try before start (don't warp to startTime)
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: not active");
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

        // Try to buy tickets after endTime - should fail (onlyActive modifier checks this)
        vm.startPrank(buyer2);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: not active");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();
    }

    function test_BuyTickets_RevertAfterFinalized() public {
        _createRaffle();
        _buyEnoughTickets();
        _finalize();

        // Try to buy tickets after finalization - should fail (onlyActive modifier checks this)
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: not active");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();
    }

    function test_Finalize_Success() public {
        _createRaffle();
        _buyEnoughTickets();

        // Ensure we have enough blocks before finalization
        vm.roll(block.number + WINNERS_COUNT + 10);
        vm.warp(raffle.endTime() + 1);
        raffle.finalize();

        assertTrue(raffle.finalized());
        assertTrue(raffle.succeeded());
        assertEq(raffle.totalFunds(), SELLER_MIN); // Exact match required

        // Check seller has pending withdrawal (fee deducted from totalFunds)
        uint256 calculatedPayout = raffle.totalFunds() -
            ((raffle.totalFunds() * FEE_BPS) / 10000);
        assertEq(raffle.pendingWithdrawals(seller), calculatedPayout);
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
    }

    function test_PickWinners_AutomaticallyDuringFinalize() public {
        _createRaffle();
        _buyEnoughTickets();

        // Ensure we have enough blocks before finalization (need at least winnersCount blocks)
        vm.roll(block.number + WINNERS_COUNT + 10);

        // Finalize - winners should be picked automatically
        _finalize();

        // Verify winners are set immediately after finalize
        address[] memory winners = raffle.getWinners();
        assertEq(winners.length, WINNERS_COUNT);
        assertGt(winners.length, 0); // Winners are set
    }

    function test_Finalize_RevertInsufficientBlocks() public {
        _createRaffle();
        _buyEnoughTickets();

        // Don't advance enough blocks - we need at least winnersCount blocks before finalization
        // If we finalize with fewer blocks, _pickWinners will revert
        vm.warp(raffle.endTime() + 1);
        
        // Try to finalize with insufficient blocks (less than winnersCount)
        // This should revert during _pickWinners
        vm.expectRevert("Raffle: insufficient blocks");
        raffle.finalize();
    }

    function test_ClaimPrize() public {
        _createRaffle();
        _buyEnoughTickets();

        // Ensure we have enough blocks before finalization
        vm.roll(block.number + WINNERS_COUNT + 10);
        _finalize();

        // Winners are already picked during finalize
        address[] memory winners = raffle.getWinners();
        assertEq(winners.length, WINNERS_COUNT);

        // Find a winner and claim their prize
        address winner = winners[0];
        uint256 winnerBalanceBefore = assetToken.balanceOf(winner);
        uint256 prizePerWinner = ASSET_AMOUNT / WINNERS_COUNT;

        vm.prank(winner);
        raffle.claimPrize();

        // Verify winner got a prize (at least prizePerWinner, could be more if remainder)
        assertGe(
            assetToken.balanceOf(winner),
            winnerBalanceBefore + prizePerWinner
        );
        assertEq(raffle.pendingWithdrawals(winner), 0);
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
    }

    function test_WithdrawAsset_FailedRaffle() public {
        _createRaffle();

        // Buy tickets but raffle fails
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), 10 * TICKET_PRICE);
        raffle.buyTickets(10, address(0)); // Only 10 tokens, less than SELLER_MIN (50)
        vm.stopPrank();

        vm.warp(raffle.endTime() + 1);
        raffle.finalize();

        assertTrue(raffle.finalized());
        assertFalse(raffle.succeeded());

        // Seller withdraws asset
        uint256 assetBalanceBefore = assetToken.balanceOf(seller);
        uint256 raffleAssetBalanceBefore = assetToken.balanceOf(
            address(raffle)
        );

        vm.prank(seller);
        raffle.withdrawAsset();

        assertEq(
            assetToken.balanceOf(seller),
            assetBalanceBefore + ASSET_AMOUNT
        );
        assertEq(
            assetToken.balanceOf(address(raffle)),
            raffleAssetBalanceBefore - ASSET_AMOUNT
        );
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

    function test_WithdrawAsset_RevertNotFinalized() public {
        _createRaffle();

        vm.prank(seller);
        vm.expectRevert("Raffle: not finalized");
        raffle.withdrawAsset();
    }

    function test_WithdrawAsset_RevertRaffleSucceeded() public {
        _createRaffle();
        _buyEnoughTickets();
        _finalize();

        assertTrue(raffle.succeeded());

        vm.prank(seller);
        vm.expectRevert("Raffle: raffle succeeded");
        raffle.withdrawAsset();
    }

    function test_WithdrawSeller() public {
        _createRaffle();
        _buyEnoughTickets();
        _finalize();

        uint256 calculatedPayout = raffle.totalFunds() -
            ((raffle.totalFunds() * FEE_BPS) / 10000);
        uint256 balanceBefore = paymentToken.balanceOf(seller);

        vm.prank(seller);
        raffle.withdrawSeller();

        assertEq(
            paymentToken.balanceOf(seller),
            balanceBefore + calculatedPayout
        );
        assertEq(raffle.pendingWithdrawals(seller), 0);
    }

    function test_HasFailed_TimeBased() public {
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

        // After endTime but not finalized, should be failed (time-based check)
        vm.warp(raffle.endTime() + 1);
        assertTrue(raffle.hasFailed());

        // After finalization, should still show as failed
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

        // After finalization, should show as succeeded
        vm.roll(block.number + WINNERS_COUNT + 10);
        raffle.finalize();
        assertFalse(raffle.hasFailed());
        assertTrue(raffle.succeeded());
    }

    function test_CanFinalize() public {
        _createRaffle();

        // Before endTime, cannot finalize
        assertFalse(raffle.canFinalize());

        // At endTime, can finalize
        vm.warp(raffle.endTime());
        assertTrue(raffle.canFinalize());

        // After endTime, can finalize
        vm.warp(raffle.endTime() + 1 days);
        assertTrue(raffle.canFinalize());

        // After finalization, cannot finalize again
        raffle.finalize();
        assertFalse(raffle.canFinalize());
    }

    function test_ReentrancyProtection() public {
        // This is a basic test - in production, use a reentrancy attack contract
        _createRaffle();
        _buyEnoughTickets();

        // Ensure we have enough blocks before finalization
        vm.roll(block.number + WINNERS_COUNT + 10);
        _finalize();

        // Winners are already picked during finalize
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

        // Warp to start time so raffle is active
        vm.warp(startTime);
    }

    function _createRaffleEth() internal {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        vm.startPrank(seller);
        address raffleAddr = factory.createRaffle(
            address(0), // raffleSeller: address(0) means use msg.sender
            address(assetToken),
            ASSET_AMOUNT,
            address(0), // ETH
            TICKET_PRICE,
            TICKET_CAP,
            SELLER_MIN,
            startTime,
            endTime,
            WINNERS_COUNT
        );
        raffle = Raffle(raffleAddr);
        vm.stopPrank();

        // Warp to start time so raffle is active
        vm.warp(startTime);
    }

    function _buyEnoughTickets() internal {
        // Buy exactly sellerMin amount (exact match required)
        // Since sellerMin = ticketPrice * ticketCap, we need to buy all tickets
        uint256 ticketsNeeded = TICKET_CAP; // Buy all tickets to reach sellerMin

        // Distribute tickets across buyers to reach exactly sellerMin
        uint256 ticketsPerBuyer = ticketsNeeded / 3; // 100 / 3 = 33 tickets each
        uint256 remainder = ticketsNeeded % 3; // 100 % 3 = 1 ticket remainder

        vm.startPrank(buyer1);
        paymentToken.approve(
            address(raffle),
            (ticketsPerBuyer + remainder) * TICKET_PRICE
        );
        raffle.buyTickets(ticketsPerBuyer + remainder, address(0)); // 33 + 1 = 34 tickets
        vm.stopPrank();

        vm.startPrank(buyer2);
        paymentToken.approve(address(raffle), ticketsPerBuyer * TICKET_PRICE);
        raffle.buyTickets(ticketsPerBuyer, address(0)); // 33 tickets
        vm.stopPrank();

        vm.startPrank(buyer3);
        paymentToken.approve(address(raffle), ticketsPerBuyer * TICKET_PRICE);
        raffle.buyTickets(ticketsPerBuyer, address(0)); // 33 tickets
        vm.stopPrank();
        // Total: 34 + 33 + 33 = 100 tickets = exactly SELLER_MIN (ticketPrice * ticketCap)
    }

    function _finalize() internal {
        // Ensure we have enough blocks before finalization (need at least winnersCount)
        vm.roll(block.number + WINNERS_COUNT + 10);
        vm.warp(raffle.endTime() + 1);
        raffle.finalize();
    }

    function test_CreateRaffle_WithCustomSeller() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;
        address customSeller = address(0x10);

        // Mint assets to customSeller (factory transfers from _raffleSeller)
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
        assertTrue(factory.isRaffle(raffleAddr));
    }

    function test_CreateRaffle_WithCustomSeller_WithdrawWorks() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;
        address customSeller = address(0x10);

        // Mint assets to customSeller (factory transfers from _raffleSeller)
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
        _finalize();

        // Custom seller should be able to withdraw
        uint256 calculatedPayout = raffle.totalFunds() -
            ((raffle.totalFunds() * FEE_BPS) / 10000);
        uint256 balanceBefore = paymentToken.balanceOf(customSeller);

        vm.prank(customSeller);
        raffle.withdrawSeller();

        assertEq(
            paymentToken.balanceOf(customSeller),
            balanceBefore + calculatedPayout
        );
        assertEq(raffle.pendingWithdrawals(customSeller), 0);
    }

    // ============ Missing Test Cases ============

    function test_DoublePrizeClaim_Revert() public {
        _createRaffle();
        _buyEnoughTickets();
        vm.roll(block.number + WINNERS_COUNT + 10);
        _finalize();

        address[] memory winners = raffle.getWinners();
        require(winners.length > 0, "No winners");

        address winner = winners[0];
        uint256 prize = raffle.pendingWithdrawals(winner);
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

        // Second withdrawal should fail (insufficient balance)
        vm.prank(seller);
        vm.expectRevert();
        raffle.withdrawAsset();
    }

    function test_SameWinnerWinsMultipleTimes() public {
        _createRaffle();

        // One buyer buys all tickets
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), TICKET_CAP * TICKET_PRICE);
        raffle.buyTickets(TICKET_CAP, address(0));
        vm.stopPrank();

        vm.roll(block.number + WINNERS_COUNT + 10);
        _finalize();

        // Since buyer1 owns all tickets, they can win multiple times
        address[] memory winners = raffle.getWinners();
        assertEq(winners.length, WINNERS_COUNT);

        // Count how many times buyer1 won
        uint256 buyer1Wins = 0;
        for (uint256 i = 0; i < winners.length; i++) {
            if (winners[i] == buyer1) {
                buyer1Wins++;
            }
        }

        // Buyer1 should have won at least once (likely multiple times)
        assertGe(buyer1Wins, 1);
    }

    function test_FinalizeCalledTwice_Revert() public {
        _createRaffle();
        _buyEnoughTickets();
        vm.roll(block.number + WINNERS_COUNT + 10);
        _finalize();

        // Try to finalize again
        vm.expectRevert("Raffle: already finalized");
        raffle.finalize();
    }

    function test_BuyTicketsAtExactEndTime() public {
        _createRaffle();

        // Buy tickets at exact endTime (should succeed)
        vm.warp(raffle.endTime());
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        raffle.buyTickets(1, address(0));
        vm.stopPrank();

        assertEq(raffle.tickets(buyer1), 1);

        // Try to buy after endTime (should fail)
        vm.warp(raffle.endTime() + 1);
        vm.startPrank(buyer2);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: not active");
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
        assertEq(
            paymentToken.balanceOf(buyer1),
            buyerBalanceBefore + 10 * TICKET_PRICE
        );

        // Seller withdraws asset
        uint256 sellerBalanceBefore = assetToken.balanceOf(seller);
        vm.prank(seller);
        raffle.withdrawAsset();
        assertEq(
            assetToken.balanceOf(seller),
            sellerBalanceBefore + ASSET_AMOUNT
        );
    }

    function test_AllWinnersClaimPrizes() public {
        _createRaffle();
        _buyEnoughTickets();
        vm.roll(block.number + WINNERS_COUNT + 10);
        _finalize();

        address[] memory winners = raffle.getWinners();
        assertEq(winners.length, WINNERS_COUNT);

        uint256 totalPrizeClaimed = 0;

        // All winners claim their prizes
        // Note: Some addresses might win multiple times, so we need to track unique winners
        // Use a simple approach: collect unique winners first
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
            uint256 prize = raffle.pendingWithdrawals(winner);
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
    }

    function test_CreateRaffleWithCustomSeller_AssetTransfer() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;
        address customSeller = address(0x10);

        // Mint assets to customSeller (factory transfers from _raffleSeller when customSeller is specified)
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

    function test_InsufficientBlocksBeforeFinalization() public {
        _createRaffle();
        _buyEnoughTickets();

        vm.warp(raffle.endTime() + 1);

        // Try to finalize without enough blocks (need at least winnersCount blocks)
        // This should revert
        vm.expectRevert("Raffle: insufficient blocks");
        raffle.finalize();
    }
}
