// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Raffle} from "../src/Raffle.sol";
import {RaffleFactory} from "../src/RaffleFactory.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Fuzz tests for Raffle contract
contract RaffleFuzzTest is Test {
    RaffleFactory public factory;
    MockERC20 public assetToken;
    MockERC20 public paymentToken;

    address public seller = address(0x1);
    address public feeRecipient = address(0x2);

    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        paymentToken = new MockERC20("Payment Token", "PAY");
        factory = new RaffleFactory(feeRecipient, 200);
    }

    /// @notice Fuzz test: invariant that total funds equals sum of individual ticket purchases
    function testFuzz_TotalFundsInvariant(
        uint256 ticketPrice,
        uint8 ticketCount
    ) public {
        // Bound inputs
        ticketPrice = bound(ticketPrice, 1 wei, 1000 ether);
        ticketCount = uint8(bound(ticketCount, 1, 10)); // Max 10 tickets

        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        // ticketCap must be set so that ticketPrice * ticketCap == sellerMin
        // For simplicity, set ticketCap = 10, so sellerMin = 10 * ticketPrice
        uint256 ticketCap = 10;
        uint256 sellerMin = ticketPrice * ticketCap; // Must equal ticketPrice * ticketCap

        vm.startPrank(seller);
        assetToken.mint(seller, 1000 ether);
        assetToken.approve(address(factory), 1000 ether);

        address raffleAddr = factory.createRaffle(
            address(assetToken),
            1000 ether,
            address(paymentToken),
            ticketPrice,
            ticketCap,
            sellerMin,
            startTime,
            endTime,
            3
        );
        vm.stopPrank();

        Raffle raffle = Raffle(raffleAddr);
        // Asset is already transferred by factory

        // Warp to start time
        vm.warp(startTime);

        // Setup buyer - ensure purchase doesn't exceed sellerMin
        address buyer = address(0x100);
        uint256 cost = ticketPrice * ticketCount;
        require(cost <= sellerMin, "Test setup: cost exceeds sellerMin");
        paymentToken.mint(buyer, cost * 2);

        vm.startPrank(buyer);
        paymentToken.approve(raffleAddr, cost);
        raffle.buyTickets(ticketCount, address(0));
        vm.stopPrank();

        // Invariant: totalFunds == tickets[buyer] * ticketPrice
        assertEq(raffle.totalFunds(), raffle.tickets(buyer) * ticketPrice);
    }

    /// @notice Fuzz test: cannot exceed ticket cap
    function testFuzz_CannotExceedCap(
        uint256 ticketCap,
        uint256 buyAmount
    ) public {
        ticketCap = bound(ticketCap, 4, 10000); // At least 4 to allow winnersCount = 3 < ticketCap
        // Bound buyAmount to prevent overflow when multiplying by 1 ether
        // Use a safe upper bound to avoid overflow
        uint256 maxSafeBuyAmount = type(uint256).max / 1 ether;
        buyAmount = bound(
            buyAmount,
            ticketCap + 1,
            maxSafeBuyAmount > 1000000 ? 1000000 : maxSafeBuyAmount
        );

        // Skip if buyAmount would cause overflow
        if (buyAmount > type(uint256).max / 1 ether) {
            return;
        }

        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        // sellerMin must equal ticketPrice * ticketCap
        uint256 ticketPrice = 1 ether;
        uint256 sellerMin = ticketPrice * ticketCap;

        // Ensure winnersCount < ticketCap (validation requirement)
        uint16 winnersCount = 3;
        require(
            winnersCount < ticketCap,
            "Test setup: winnersCount must be < ticketCap"
        );

        vm.startPrank(seller);
        assetToken.mint(seller, 1000 ether);
        assetToken.approve(address(factory), 1000 ether);

        address raffleAddr = factory.createRaffle(
            address(assetToken),
            1000 ether,
            address(paymentToken),
            ticketPrice,
            ticketCap,
            sellerMin,
            startTime,
            endTime,
            winnersCount
        );
        vm.stopPrank();

        Raffle raffle = Raffle(raffleAddr);
        // Asset is already transferred by factory

        // Warp to start time
        vm.warp(startTime);

        address buyer = address(0x100);
        uint256 cost = buyAmount * 1 ether;
        paymentToken.mint(buyer, cost);

        vm.startPrank(buyer);
        paymentToken.approve(raffleAddr, cost);
        vm.expectRevert("Raffle: exceeds cap");
        raffle.buyTickets(buyAmount, address(0));
        vm.stopPrank();
    }

    /// @notice Fuzz test: seller payout calculation
    function testFuzz_SellerPayoutCalculation(
        uint256 ticketCapRaw,
        uint256 feeBps
    ) public {
        feeBps = bound(feeBps, 0, 10000);
        // Ensure ticketCap and sellerMin satisfy: ticketPrice * ticketCap == sellerMin
        uint256 ticketPrice = 1 ether;
        ticketCapRaw = bound(ticketCapRaw, 10, 10000); // Number of tickets
        uint256 ticketCap = ticketCapRaw;
        uint256 sellerMin = ticketPrice * ticketCap; // Must equal ticketPrice * ticketCap

        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        // Create factory with fuzzed fee
        RaffleFactory fuzzFactory = new RaffleFactory(feeRecipient, feeBps);

        vm.startPrank(seller);
        assetToken.mint(seller, 1000 ether);
        assetToken.approve(address(fuzzFactory), 1000 ether);

        address raffleAddr = fuzzFactory.createRaffle(
            address(assetToken),
            1000 ether,
            address(paymentToken),
            ticketPrice,
            ticketCap,
            sellerMin,
            startTime,
            endTime,
            3
        );
        vm.stopPrank();

        Raffle raffle = Raffle(raffleAddr);
        // Asset is already transferred by factory

        // Warp to start time
        vm.warp(startTime);

        // Buy exactly sellerMin to make raffle succeed
        address buyer = address(0x100);
        paymentToken.mint(buyer, sellerMin);

        vm.startPrank(buyer);
        paymentToken.approve(raffleAddr, sellerMin);
        uint256 ticketsToBuy = sellerMin / ticketPrice; // Exact division
        raffle.buyTickets(ticketsToBuy, address(0));
        vm.stopPrank();

        vm.warp(endTime + 1);
        raffle.finalize();

        // Raffle should succeed since totalFunds == sellerMin
        assertTrue(raffle.succeeded());
        assertEq(raffle.totalFunds(), sellerMin);
        uint256 expectedFee = (raffle.totalFunds() * feeBps) / 10000;
        uint256 expectedPayout = raffle.totalFunds() - expectedFee;
        assertEq(raffle.pendingWithdrawals(seller), expectedPayout);
    }
}
