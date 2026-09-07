// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
    VALIDATION MATRIX — every guard in Raffle.initialize, plus the address
    guards on the constructors and the two admin setters.

    The rest of the suite drives raffles through the factory, which is the only
    caller `initialize` accepts. That leaves most of these guards asserted but never
    fired: the factory supplies `seller`, `feeBps`, `feeRecipient` and the provider
    itself, so several are unreachable in production and exist as defence in depth.
    Defence in depth that has never been exercised is a guess, so this suite stands
    in as the factory and fires each one.
//////////////////////////////////////////////////////////////////////////*/

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../../src/Raffle.sol";
import {RaffleFactory} from "../../src/RaffleFactory.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockRandomnessProvider} from "../mocks/MockRandomnessProvider.sol";
import {ChainlinkVRFProvider} from "../../src/randomness/ChainlinkVRFProvider.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev This test contract IS the factory, so it can hand `initialize` anything it likes.
contract ValidationTest is Test {
    Raffle internal implementation;
    MockRandomnessProvider internal provider;
    MockERC20 internal asset;
    MockERC20 internal pay;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal seller = makeAddr("seller");

    function setUp() public {
        vm.warp(1_700_000_000);
        implementation = new Raffle(address(this));
        provider = new MockRandomnessProvider();
        asset = new MockERC20("Wrapped Ether", "WETH");
        pay = new MockERC20("USD Coin", "USDC");
    }

    /// A set of parameters that passes every check, so each test can spoil exactly one.
    function _valid() internal view returns (Raffle.RaffleParams memory p) {
        p = Raffle.RaffleParams({
            seller: seller,
            assetToken: address(asset),
            assetAmount: 900e18,
            paymentToken: address(pay),
            ticketPrice: 1e18,
            ticketCap: 10,
            sellerMin: 10e18,
            startTime: block.timestamp + 1,
            endTime: block.timestamp + 7 days,
            winnersCount: 3,
            feeBps: 200,
            feeRecipient: feeRecipient,
            randomnessProvider: address(provider)
        });
    }

    function _clone() internal returns (Raffle) {
        return Raffle(Clones.clone(address(implementation)));
    }

    function _expect(Raffle.RaffleParams memory p, string memory reason) internal {
        Raffle r = _clone();
        vm.expectRevert(bytes(reason));
        r.initialize(p);
    }

    /// The happy case, so the matrix below is proving the guard and not a typo in `_valid()`.
    function test_Validation_BaselineParametersAreAccepted() public {
        Raffle r = _clone();
        r.initialize(_valid());
        assertEq(uint8(r.state()), uint8(Raffle.State.Active));
        assertEq(r.seller(), seller);
    }

    function test_Validation_OnlyTheFactoryMayInitialize() public {
        Raffle r = _clone();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("Raffle: only factory"));
        r.initialize(_valid());
    }

    function test_Validation_ImplementationItselfCannotBeInitialized() public {
        vm.expectRevert(); // InvalidInitialization: the constructor disabled it
        implementation.initialize(_valid());
    }

    function test_Validation_ARaffleCannotBeInitializedTwice() public {
        Raffle r = _clone();
        r.initialize(_valid());
        vm.expectRevert();
        r.initialize(_valid());
    }

    // ------------------------------------------------------------------ addresses

    function test_Validation_SellerMustNotBeZero() public {
        Raffle.RaffleParams memory p = _valid();
        p.seller = address(0);
        _expect(p, "Raffle: invalid seller");
    }

    function test_Validation_ProviderMustNotBeZero() public {
        Raffle.RaffleParams memory p = _valid();
        p.randomnessProvider = address(0);
        _expect(p, "Raffle: invalid provider");
    }

    function test_Validation_FeeRecipientMustNotBeZero() public {
        Raffle.RaffleParams memory p = _valid();
        p.feeRecipient = address(0);
        _expect(p, "Raffle: invalid fee recipient");
    }

    // ------------------------------------------------------------------ economics

    function test_Validation_TicketPriceMustBePositive() public {
        Raffle.RaffleParams memory p = _valid();
        p.ticketPrice = 0;
        _expect(p, "Raffle: invalid ticket price");
    }

    function test_Validation_TicketCapMustBePositive() public {
        Raffle.RaffleParams memory p = _valid();
        p.ticketCap = 0;
        _expect(p, "Raffle: invalid ticket cap");
    }

    function test_Validation_SellerMinMustBePositive() public {
        Raffle.RaffleParams memory p = _valid();
        p.sellerMin = 0;
        _expect(p, "Raffle: invalid seller min");
    }

    /// The target has to be exactly what selling out produces, or "sold out" and "target met"
    /// would be two different questions and settlement would have to pick one.
    function test_Validation_SellerMinMustEqualPriceTimesCap() public {
        Raffle.RaffleParams memory p = _valid();
        p.sellerMin = 9e18;
        _expect(p, "Raffle: sellerMin must equal price times cap");
    }

    function test_Validation_FeeCannotExceedTheCap() public {
        Raffle.RaffleParams memory p = _valid();
        p.feeBps = 1001;
        _expect(p, "Raffle: fee too high");

        p.feeBps = implementation.MAX_FEE_BPS();
        Raffle r = _clone();
        r.initialize(p); // the cap itself is allowed
        assertEq(r.feeBps(), implementation.MAX_FEE_BPS());
    }

    // ------------------------------------------------------------------ winners

    function test_Validation_WinnersCountMustBePositiveAndFitTheCap() public {
        Raffle.RaffleParams memory p = _valid();
        p.winnersCount = 0;
        _expect(p, "Raffle: invalid winners count");

        p.winnersCount = 11; // more winners than tickets
        _expect(p, "Raffle: invalid winners count");
    }

    /// The ceiling exists so a draw always fits in a block; see DECISIONS.md D-18.
    function test_Validation_WinnersCountMustNotExceedTheHardCeiling() public {
        Raffle.RaffleParams memory p = _valid();
        uint16 max = uint16(implementation.MAX_WINNERS_COUNT());
        p.ticketCap = uint256(max) + 1;
        p.sellerMin = p.ticketPrice * p.ticketCap;
        p.winnersCount = max + 1;
        _expect(p, "Raffle: winners count too high");
    }

    /// Without this, the last winners would be credited zero and their claim would revert.
    function test_Validation_PrizeMustCoverOneUnitPerWinner() public {
        Raffle.RaffleParams memory p = _valid();
        p.assetAmount = 2; // three winners, two units
        _expect(p, "Raffle: prize too small for winners");
    }

    // ------------------------------------------------------------------ timing

    function test_Validation_StartCannotBeInThePast() public {
        Raffle.RaffleParams memory p = _valid();
        p.startTime = block.timestamp - 1;
        _expect(p, "Raffle: start in past");
    }

    function test_Validation_DurationMustMeetTheMinimum() public {
        Raffle.RaffleParams memory p = _valid();
        p.endTime = p.startTime + implementation.MIN_DURATION() - 1;
        _expect(p, "Raffle: duration too short");

        p.endTime = p.startTime + implementation.MIN_DURATION();
        Raffle r = _clone();
        r.initialize(p); // exactly the minimum is allowed
        assertEq(r.endTime(), p.endTime);
    }

    // ------------------------------------------------------------------ buying

    function test_Validation_BuyingZeroTicketsIsRejected() public {
        Raffle r = _clone();
        r.initialize(_valid());
        vm.warp(block.timestamp + 1);
        vm.expectRevert(bytes("Raffle: invalid amount"));
        r.buyTickets(0, address(0));
    }

    // ------------------------------------------------------------------ views

    /// `canDraw()` must agree with what `drawWinners()` would actually do in every state, or a
    /// frontend will offer a button that reverts. That mismatch was finding R-11.
    function test_Validation_CanDrawIsFalseOutsideRandomnessPending() public {
        Raffle r = _clone();
        r.initialize(_valid());
        assertFalse(r.canDraw(), "Active");
        assertFalse(r.canFinalize(), "before the deadline");

        vm.warp(r.endTime());
        assertTrue(r.canFinalize());
        r.finalize(); // nothing sold, so it fails outright rather than asking for randomness
        assertTrue(r.hasFailed());
        assertFalse(r.canDraw(), "Failed");
        assertFalse(r.canFinalize(), "already settled");
    }

    // ------------------------------------------------------------------ constructors and setters

    function test_Validation_RaffleConstructorRejectsAZeroFactory() public {
        vm.expectRevert(bytes("Raffle: invalid factory"));
        new Raffle(address(0));
    }

    function test_Validation_FactoryRejectsAZeroProvider() public {
        RaffleFactory f = new RaffleFactory(owner, feeRecipient, 200, address(provider));
        vm.prank(owner);
        vm.expectRevert(RaffleFactory.InvalidAddress.selector);
        f.setRandomnessProvider(address(0));

        // And the setter is owner-only.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")));
        f.setRandomnessProvider(address(provider));
    }

    function test_Validation_ProviderRejectsAZeroFactory() public {
        ChainlinkVRFProvider vrf =
            new ChainlinkVRFProvider(owner, makeAddr("coordinator"), bytes32("lane"), 1, 3, 200000, false);
        vm.prank(owner);
        vm.expectRevert(ChainlinkVRFProvider.InvalidAddress.selector);
        vrf.setFactory(address(0));
    }
}
