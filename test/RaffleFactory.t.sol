// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RaffleFactory} from "../src/RaffleFactory.sol";
import {Raffle} from "../src/Raffle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockRandomnessProvider} from "./mocks/MockRandomnessProvider.sol";

contract RaffleFactoryTest is Test {
    RaffleFactory public factory;
    MockERC20 public assetToken;
    MockERC20 public paymentToken;
    MockRandomnessProvider public provider;

    address public owner = address(0x1);
    address public feeRecipient = address(0x2);
    address public seller = address(0x3);
    address public buyer = address(0x4);

    uint256 public constant FEE_BPS = 200; // 2%
    uint256 public constant ASSET_AMOUNT = 1000 * 10 ** 18;
    uint256 public constant TICKET_PRICE = 1 * 10 ** 18;
    uint256 public constant TICKET_CAP = 100;
    uint256 public constant SELLER_MIN = TICKET_PRICE * TICKET_CAP;
    uint16 public constant WINNERS_COUNT = 3;

    function setUp() public {
        // initialize() requires startTime >= block.timestamp, and every test builds its
        // schedule relative to now. Start from a realistic clock so the arithmetic below
        // never has to reach behind block zero.
        vm.warp(1_000_000);

        provider = new MockRandomnessProvider();
        // Seeds are handed out to each request immediately, so drawWinners() works in the
        // same test without a separate fulfilment step.
        provider.setAutoSeed(uint256(keccak256("factory-seed")));

        factory = new RaffleFactory(owner, feeRecipient, FEE_BPS, address(provider));

        assetToken = new MockERC20("Asset Token", "ASSET");
        paymentToken = new MockERC20("Payment Token", "PAY");

        // Enough for several raffles in one test (see the pagination test).
        assetToken.mint(seller, ASSET_AMOUNT * 10);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// @dev Creates a raffle as `who`. `who` is always the seller: the factory refuses to
    ///      name anybody else.
    function _createAs(address who) internal returns (Raffle r) {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        vm.startPrank(who);
        assetToken.approve(address(factory), ASSET_AMOUNT);
        address addr = factory.createRaffle(
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
        vm.stopPrank();
        r = Raffle(addr);
    }

    // ------------------------------------------------------------------
    // constructor
    // ------------------------------------------------------------------

    function test_Constructor() public view {
        assertEq(factory.feeBps(), FEE_BPS);
        assertEq(factory.feeRecipient(), feeRecipient);
        assertEq(factory.owner(), owner);
        assertEq(address(factory.randomnessProvider()), address(provider));
        assertEq(factory.MAX_FEE_BPS(), 1000);
        assertTrue(factory.RAFFLE_IMPLEMENTATION() != address(0));
    }

    function test_Constructor_RevertsOnZeroOwner() public {
        // Ownable's own constructor runs first and rejects the zero owner, so the revert
        // is OwnableInvalidOwner rather than the factory's InvalidAddress.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new RaffleFactory(address(0), feeRecipient, FEE_BPS, address(provider));
    }

    function test_Constructor_RevertsOnZeroFeeRecipient() public {
        vm.expectRevert(RaffleFactory.InvalidAddress.selector);
        new RaffleFactory(owner, address(0), FEE_BPS, address(provider));
    }

    function test_Constructor_RevertsOnZeroProvider() public {
        vm.expectRevert(RaffleFactory.InvalidAddress.selector);
        new RaffleFactory(owner, feeRecipient, FEE_BPS, address(0));
    }

    function test_Constructor_RevertsOnFeeAboveMaxFeeBps() public {
        vm.expectRevert(RaffleFactory.InvalidFeeBps.selector);
        new RaffleFactory(owner, feeRecipient, 1001, address(provider));

        // Exactly at the ceiling is fine.
        RaffleFactory atMax = new RaffleFactory(owner, feeRecipient, 1000, address(provider));
        assertEq(atMax.feeBps(), 1000);
    }

    // ------------------------------------------------------------------
    // createRaffle
    // ------------------------------------------------------------------

    function test_CreateRaffle() public {
        Raffle raffle = _createAs(seller);

        assertTrue(factory.isRaffle(address(raffle)));
        assertEq(factory.getRaffleCount(), 1);
        assertEq(factory.getRaffle(0), address(raffle));
        assertEq(raffle.seller(), seller);
        assertEq(uint8(raffle.state()), uint8(Raffle.State.Active));
        assertEq(assetToken.balanceOf(address(raffle)), ASSET_AMOUNT);
    }

    /// @dev This still passes precisely because the caller IS the named seller. The factory
    ///      accepts `raffleSeller` only when it equals msg.sender (or is zero); the prank
    ///      here makes customSeller the caller, so naming them is a no-op rather than an
    ///      attempt to spend somebody else's allowance.
    function test_CreateRaffle_WithCustomSeller() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;
        address customSeller = address(0x10);

        assetToken.mint(customSeller, ASSET_AMOUNT);

        vm.startPrank(customSeller);
        assetToken.approve(address(factory), ASSET_AMOUNT);

        address raffleAddr = factory.createRaffle(
            customSeller, // == msg.sender, so permitted
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

        Raffle raffle = Raffle(raffleAddr);
        assertEq(raffle.seller(), customSeller);
        assertTrue(factory.isRaffle(raffleAddr));
    }

    function test_CreateRaffle_WithZeroSeller_UsesMsgSender() public {
        Raffle raffle = _createAs(seller);
        assertEq(raffle.seller(), seller);
        assertTrue(factory.isRaffle(address(raffle)));
    }

    /// @notice Same promise as the test above, stated as its own regression: address(0)
    ///         keeps working and simply means "me".
    function test_CreateRaffle_ZeroSellerMeansCaller() public {
        address other = address(0x11);
        assetToken.mint(other, ASSET_AMOUNT);

        Raffle raffle = _createAs(other);

        assertEq(raffle.seller(), other, "address(0) must resolve to the caller");
        assertEq(assetToken.balanceOf(other), 0, "prize pulled from the caller");
        assertEq(assetToken.balanceOf(address(raffle)), ASSET_AMOUNT);
    }

    /// @notice Regression for the approval-theft finding: a third party must not be able to
    ///         spend a victim's standing allowance to the factory by naming them as seller.
    function test_CreateRaffle_RevertsWhenSellerIsNotCaller() public {
        address attacker = address(0xBAD);
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        // The victim has approved the factory (a perfectly normal thing to have done
        // before creating their own raffle) and holds the prize.
        vm.prank(seller);
        assetToken.approve(address(factory), type(uint256).max);
        uint256 victimBalanceBefore = assetToken.balanceOf(seller);

        vm.prank(attacker);
        vm.expectRevert(RaffleFactory.SellerMustBeCaller.selector);
        factory.createRaffle(
            seller, // naming the victim
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

        assertEq(assetToken.balanceOf(seller), victimBalanceBefore, "victim's tokens must not move");
        assertEq(factory.getRaffleCount(), 0, "no raffle may be registered");
    }

    /// @dev Winners are no longer chosen by finalize(). Settling the sale and drawing the
    ///      winners are two transactions, so that whoever sends finalize() cannot influence
    ///      an outcome that does not exist yet.
    function test_WinnersPickedOnDraw() public {
        Raffle raffle = _createAs(seller);

        vm.warp(raffle.startTime());

        // Buy the whole cap so the raffle sells out.
        paymentToken.mint(buyer, SELLER_MIN);
        vm.startPrank(buyer);
        paymentToken.approve(address(raffle), SELLER_MIN);
        raffle.buyTickets(TICKET_CAP, address(0));
        vm.stopPrank();

        vm.warp(raffle.endTime());
        raffle.finalize();

        // finalize() only settles the sale and asks for a seed.
        assertEq(uint8(raffle.state()), uint8(Raffle.State.RandomnessPending));
        assertEq(raffle.getWinners().length, 0, "no winners before the draw");
        assertEq(provider.requestCount(), 1);

        raffle.drawWinners();

        assertEq(uint8(raffle.state()), uint8(Raffle.State.Succeeded));
        assertEq(raffle.getWinners().length, WINNERS_COUNT);
    }

    // ------------------------------------------------------------------
    // admin
    // ------------------------------------------------------------------

    function test_SetFeeBps() public {
        vm.prank(owner);
        factory.setFeeBps(300);

        assertEq(factory.feeBps(), 300);
    }

    function test_SetFeeBps_RevertInvalid() public {
        vm.prank(owner);
        vm.expectRevert(RaffleFactory.InvalidFeeBps.selector);
        factory.setFeeBps(10001); // > 100%
    }

    function test_SetFeeBps_RevertsAboveMaxFeeBps() public {
        uint256 max = factory.MAX_FEE_BPS();

        vm.prank(owner);
        vm.expectRevert(RaffleFactory.InvalidFeeBps.selector);
        factory.setFeeBps(max + 1);

        // Exactly the ceiling is allowed.
        vm.prank(owner);
        factory.setFeeBps(max);
        assertEq(factory.feeBps(), max);
    }

    function test_SetFeeRecipient() public {
        address newRecipient = address(0x9);

        vm.prank(owner);
        factory.setFeeRecipient(newRecipient);

        assertEq(factory.feeRecipient(), newRecipient);
    }

    function test_SetFeeRecipient_RevertInvalid() public {
        vm.prank(owner);
        vm.expectRevert(RaffleFactory.InvalidAddress.selector);
        factory.setFeeRecipient(address(0));
    }

    function test_OnlyOwner_CanSetFeeBps() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, seller));
        factory.setFeeBps(300);
    }

    function test_OnlyOwner_CanSetFeeRecipient() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, seller));
        factory.setFeeRecipient(address(0x9));
    }

    function test_Ownership_IsTwoStep() public {
        address newOwner = address(0xA11CE);

        vm.prank(owner);
        factory.transferOwnership(newOwner);

        // Step one alone changes nothing.
        assertEq(factory.owner(), owner, "ownership must not move on transfer alone");
        assertEq(factory.pendingOwner(), newOwner);

        // Somebody else cannot accept on the pending owner's behalf.
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, seller));
        factory.acceptOwnership();

        vm.prank(newOwner);
        factory.acceptOwnership();

        assertEq(factory.owner(), newOwner);
        assertEq(factory.pendingOwner(), address(0));

        // The new owner can administer; the old one cannot.
        vm.prank(newOwner);
        factory.setFeeBps(400);
        assertEq(factory.feeBps(), 400);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        factory.setFeeBps(500);
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    function test_GetRaffles_Paginates() public {
        address r0 = address(_createAs(seller));
        address r1 = address(_createAs(seller));
        address r2 = address(_createAs(seller));

        assertEq(factory.getRaffleCount(), 3);

        address[] memory all = factory.getRaffles(0, 10);
        assertEq(all.length, 3, "limit beyond the end is clamped");
        assertEq(all[0], r0);
        assertEq(all[1], r1);
        assertEq(all[2], r2);

        address[] memory firstPage = factory.getRaffles(0, 2);
        assertEq(firstPage.length, 2);
        assertEq(firstPage[0], r0);
        assertEq(firstPage[1], r1);

        address[] memory secondPage = factory.getRaffles(2, 2);
        assertEq(secondPage.length, 1, "last page is short");
        assertEq(secondPage[0], r2);

        address[] memory pastEnd = factory.getRaffles(3, 2);
        assertEq(pastEnd.length, 0, "offset at the end returns nothing");

        address[] memory wayPastEnd = factory.getRaffles(100, 10);
        assertEq(wayPastEnd.length, 0, "out-of-range offset returns nothing");

        address[] memory zeroLimit = factory.getRaffles(0, 0);
        assertEq(zeroLimit.length, 0, "zero limit returns nothing");
    }
}
