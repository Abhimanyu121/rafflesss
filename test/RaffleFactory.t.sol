// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {RaffleFactory} from "../src/RaffleFactory.sol";
import {Raffle} from "../src/Raffle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract RaffleFactoryTest is Test {
    RaffleFactory public factory;
    MockERC20 public assetToken;
    MockERC20 public paymentToken;

    address public owner = address(0x1);
    address public feeRecipient = address(0x2);
    address public seller = address(0x3);

    uint256 public constant FEE_BPS = 200; // 2%

    function setUp() public {
        vm.prank(owner);
        factory = new RaffleFactory(feeRecipient, FEE_BPS);

        assetToken = new MockERC20("Asset Token", "ASSET");
        paymentToken = new MockERC20("Payment Token", "PAY");

        // Mint assets to seller
        assetToken.mint(seller, 1000 * 10 ** 18);
    }

    function test_Constructor() public {
        assertEq(factory.feeBps(), FEE_BPS);
        assertEq(factory.feeRecipient(), feeRecipient);
        assertEq(factory.owner(), owner);
        assertTrue(factory.raffleImplementation() != address(0));
    }

    function test_CreateRaffle() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        vm.startPrank(seller);
        // Approve factory to transfer asset
        assetToken.approve(address(factory), 1000 * 10 ** 18);

        address raffleAddr = factory.createRaffle(
            address(assetToken),
            1000 * 10 ** 18,
            address(paymentToken),
            1 * 10 ** 18,
            100,
            100 * 10 ** 18, // sellerMin must equal ticketPrice * ticketCap (1 * 100)
            startTime,
            endTime,
            3
        );
        vm.stopPrank();

        assertTrue(factory.isRaffle(raffleAddr));
        assertEq(factory.getRaffleCount(), 1);
        assertEq(factory.getRaffle(0), raffleAddr);
    }

    function test_SetFeeBps() public {
        vm.prank(owner);
        factory.setFeeBps(300);

        assertEq(factory.feeBps(), 300);
    }

    function test_SetFeeBps_RevertInvalid() public {
        vm.prank(owner);
        vm.expectRevert();
        factory.setFeeBps(10001); // > 100%
    }

    function test_SetFeeRecipient() public {
        address newRecipient = address(0x9);

        vm.prank(owner);
        factory.setFeeRecipient(newRecipient);

        assertEq(factory.feeRecipient(), newRecipient);
    }

    function test_SetFeeRecipient_RevertInvalid() public {
        vm.prank(owner);
        vm.expectRevert();
        factory.setFeeRecipient(address(0));
    }

    function test_WinnersPickedAutomatically() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        vm.startPrank(seller);
        // Approve factory to transfer asset
        assetToken.approve(address(factory), 1000 * 10 ** 18);

        address raffleAddr = factory.createRaffle(
            address(assetToken),
            1000 * 10 ** 18,
            address(paymentToken),
            1 * 10 ** 18,
            100,
            100 * 10 ** 18, // sellerMin must equal ticketPrice * ticketCap (1 * 100)
            startTime,
            endTime,
            3
        );
        vm.stopPrank();

        Raffle raffle = Raffle(raffleAddr);

        // Warp to start time
        vm.warp(startTime);

        // Buy exactly sellerMin (100 tokens) to make raffle succeed
        paymentToken.mint(address(0x4), 100 * 10 ** 18);
        vm.startPrank(address(0x4));
        paymentToken.approve(raffleAddr, 100 * 10 ** 18);
        raffle.buyTickets(100, address(0)); // Exactly 100 tokens = sellerMin (ticketPrice * ticketCap)
        vm.stopPrank();

        vm.warp(endTime + 1);
        raffle.finalize();

        // Advance blocks so blockhash is available
        vm.roll(block.number + 10);

        // Winners are now picked automatically when claimPrize is called
        // Verify winners array is empty before
        address[] memory winnersBefore = raffle.getWinners();
        assertEq(winnersBefore.length, 0);

        // Try to claim prize - this will trigger winner picking
        // Since address(0x4) bought all tickets, they should be a winner
        vm.prank(address(0x4));
        raffle.claimPrize();

        // Verify winners are now set
        address[] memory winners = raffle.getWinners();
        assertEq(winners.length, 3);
    }

    function test_OnlyOwner_CanSetFeeBps() public {
        vm.prank(seller);
        vm.expectRevert();
        factory.setFeeBps(300);
    }

    function test_OnlyOwner_CanSetFeeRecipient() public {
        vm.prank(seller);
        vm.expectRevert();
        factory.setFeeRecipient(address(0x9));
    }
}
