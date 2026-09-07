// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../src/Raffle.sol";
import {RaffleFactory} from "../src/RaffleFactory.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockRandomnessProvider} from "./mocks/MockRandomnessProvider.sol";

/// @title Fuzz tests for Raffle contract
contract RaffleFuzzTest is Test {
    RaffleFactory public factory;
    MockERC20 public assetToken;
    MockERC20 public paymentToken;
    MockRandomnessProvider public provider;

    address public owner = address(0x9);
    address public seller = address(0x1);
    address public feeRecipient = address(0x2);

    uint256 internal constant SEED = uint256(keccak256("raffle-fuzz-seed"));
    uint256 internal constant ASSET_AMOUNT = 1000 ether;

    function setUp() public {
        // A raffle may not start in the past.
        vm.warp(1_700_000_000);

        assetToken = new MockERC20("Asset Token", "ASSET");
        paymentToken = new MockERC20("Payment Token", "PAY");

        provider = new MockRandomnessProvider();
        provider.setAutoSeed(SEED);

        factory = new RaffleFactory(owner, feeRecipient, 200, address(provider));
    }

    /// @notice Whatever the mix of buyers and purchases, the books must add up:
    ///         totalFunds is exactly the tickets sold at the frozen price, and one
    ///         ticketHolders entry exists per ticket.
    function testFuzz_TotalFundsInvariant(uint256 ticketPrice, uint8 n1, uint8 n2, uint8 n3, uint8 n4) public {
        ticketPrice = bound(ticketPrice, 1 wei, 1000 ether);

        uint256 ticketCap = 100;
        Raffle raffle = _createRaffle(factory, ticketPrice, ticketCap, 3, ASSET_AMOUNT);

        address[4] memory buyers = [address(0x100), address(0x101), address(0x102), address(0x103)];
        uint256[4] memory firstBuy;
        firstBuy[0] = bound(n1, 1, 10);
        firstBuy[1] = bound(n2, 1, 10);
        firstBuy[2] = bound(n3, 1, 10);
        firstBuy[3] = bound(n4, 1, 10);

        uint256 expectedTickets;
        for (uint256 i = 0; i < buyers.length; i++) {
            // Two separate purchases per buyer, so the accounting has to survive
            // being touched more than once by the same address.
            uint256 total = firstBuy[i] + 1;
            paymentToken.mint(buyers[i], total * ticketPrice);
            _buy(raffle, buyers[i], firstBuy[i], ticketPrice);
            _buy(raffle, buyers[i], 1, ticketPrice);
            expectedTickets += total;
            assertEq(raffle.tickets(buyers[i]), total);
        }
        // At most 4 * 11 = 44 tickets, well inside the cap.
        assertLe(expectedTickets, ticketCap);

        assertEq(raffle.totalTickets(), expectedTickets);
        assertEq(raffle.totalFunds(), expectedTickets * ticketPrice);
        assertEq(raffle.getTicketHolderCount(), expectedTickets);
        // Every ticket the contract holds money for is also a ticket someone owns.
        assertEq(paymentToken.balanceOf(address(raffle)), expectedTickets * ticketPrice);
    }

    /// @notice The cap holds against a sequence of purchases, not just one oversized call.
    function testFuzz_CannotExceedCap(uint256 ticketCap, uint256 chunk) public {
        ticketCap = bound(ticketCap, 4, 50); // at least 4 so winnersCount = 3 fits
        chunk = bound(chunk, 1, ticketCap);

        uint256 ticketPrice = 1 ether;
        Raffle raffle = _createRaffle(factory, ticketPrice, ticketCap, 3, ASSET_AMOUNT);

        address buyer = address(0x100);
        paymentToken.mint(buyer, (ticketCap + chunk + 2) * ticketPrice);

        // Fill the raffle chunk by chunk, as far as whole chunks fit.
        uint256 bought;
        while (bought + chunk <= ticketCap) {
            _buy(raffle, buyer, chunk, ticketPrice);
            bought += chunk;
        }
        assertEq(raffle.totalTickets(), bought);

        // A purchase that would cross the cap is refused and changes nothing.
        uint256 room = ticketCap - bought;
        vm.startPrank(buyer);
        paymentToken.approve(address(raffle), (room + 1) * ticketPrice);
        vm.expectRevert("Raffle: exceeds cap");
        raffle.buyTickets(room + 1, address(0));
        vm.stopPrank();

        assertEq(raffle.totalTickets(), bought);
        assertEq(raffle.totalFunds(), bought * ticketPrice);

        // Exactly the remaining room is fine...
        if (room > 0) {
            _buy(raffle, buyer, room, ticketPrice);
            bought += room;
        }
        assertEq(raffle.totalTickets(), ticketCap);
        assertEq(raffle.totalFunds(), ticketCap * ticketPrice);

        // ...and a single ticket beyond it is not.
        vm.startPrank(buyer);
        paymentToken.approve(address(raffle), ticketPrice);
        vm.expectRevert("Raffle: exceeds cap");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();

        assertEq(raffle.totalTickets(), ticketCap);
    }

    /// @notice Settlement splits the money without creating or destroying any of it:
    ///         the payment token divides into seller proceeds plus protocol fee, and
    ///         the asset token divides exactly among the winners.
    function testFuzz_SellerPayoutCalculation(uint256 ticketCapRaw, uint256 feeBps) public {
        feeBps = bound(feeBps, 0, 1000); // MAX_FEE_BPS
        uint256 ticketPrice = 1 ether;
        uint256 ticketCap = bound(ticketCapRaw, 10, 1000);
        uint256 sellerMin = ticketPrice * ticketCap;

        // Create factory with fuzzed fee
        RaffleFactory fuzzFactory = new RaffleFactory(owner, feeRecipient, feeBps, address(provider));

        Raffle raffle = _createRaffle(fuzzFactory, ticketPrice, ticketCap, 3, ASSET_AMOUNT);

        // Three buyers split the cap so the winners can differ from one another.
        address[3] memory buyers = [address(0x100), address(0x101), address(0x102)];
        uint256 share = ticketCap / 3;
        uint256[3] memory counts = [share + (ticketCap % 3), share, share];
        for (uint256 i = 0; i < buyers.length; i++) {
            paymentToken.mint(buyers[i], counts[i] * ticketPrice);
            _buy(raffle, buyers[i], counts[i], ticketPrice);
        }
        assertEq(raffle.totalTickets(), ticketCap);

        vm.warp(raffle.endTime());
        raffle.finalize();
        raffle.drawWinners();

        // Raffle should succeed since totalFunds == sellerMin
        assertTrue(raffle.succeeded());
        assertEq(raffle.totalFunds(), sellerMin);

        uint256 expectedFee = (sellerMin * feeBps) / 10000;
        assertEq(raffle.protocolFeeOwed(), expectedFee);
        assertEq(raffle.sellerProceeds(), sellerMin - expectedFee);
        // Conservation: the payment token is split, never minted or burned.
        assertEq(raffle.sellerProceeds() + raffle.protocolFeeOwed(), raffle.totalFunds());
        assertEq(paymentToken.balanceOf(address(raffle)), raffle.sellerProceeds() + raffle.protocolFeeOwed());

        // Conservation: every unit of the prize is credited to somebody, exactly once.
        address[] memory winners = raffle.getWinners();
        assertEq(winners.length, 3);

        uint256 credited;
        for (uint256 i = 0; i < winners.length; i++) {
            bool seen = false;
            for (uint256 j = 0; j < i; j++) {
                if (winners[j] == winners[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) credited += raffle.pendingPrize(winners[i]);
        }
        assertEq(credited, ASSET_AMOUNT);
    }

    // ============ Helpers ============

    uint256 internal _startTime;

    function _createRaffle(
        RaffleFactory f,
        uint256 ticketPrice,
        uint256 ticketCap,
        uint16 winnersCount,
        uint256 assetAmount
    ) internal returns (Raffle raffle) {
        // Held in storage rather than as locals: createRaffle takes ten arguments and
        // this helper otherwise runs the stack out with the optimizer's default pipeline.
        _startTime = block.timestamp + 1 days;

        assetToken.mint(seller, assetAmount);

        vm.startPrank(seller);
        assetToken.approve(address(f), assetAmount);
        raffle = Raffle(
            f.createRaffle(
                address(0), // raffleSeller: address(0) means use msg.sender
                address(assetToken),
                assetAmount,
                address(paymentToken),
                ticketPrice,
                ticketCap,
                ticketPrice * ticketCap, // sellerMin must equal price * cap
                _startTime,
                _startTime + 6 days,
                winnersCount
            )
        );
        vm.stopPrank();

        // Warp to start time so tickets can be sold
        vm.warp(_startTime);
    }

    function _buy(Raffle raffle, address buyer, uint256 n, uint256 ticketPrice) internal {
        vm.startPrank(buyer);
        paymentToken.approve(address(raffle), n * ticketPrice);
        raffle.buyTickets(n, address(0));
        vm.stopPrank();
    }
}
