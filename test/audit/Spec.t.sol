// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Spec-conformance tests
/// @notice Each test encodes a promise made by the DOCUMENTATION (README.md,
///         MECHANISMS.md, docs/*.md, or NatSpec in src/). A FAILING test here
///         means the docs and the code disagree. These are NOT exploit PoCs.
///         Run: forge test --match-path test/audit/Spec.t.sol -vvv

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Raffle} from "../../src/Raffle.sol";
import {RaffleFactory} from "../../src/RaffleFactory.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IRandomnessProvider} from "../../src/interfaces/IRandomnessProvider.sol";
import {MockRandomnessProvider} from "../mocks/MockRandomnessProvider.sol";

contract SpecTest is Test {
    RaffleFactory internal factory;
    Raffle internal raffle;
    MockERC20 internal assetToken;
    MockERC20 internal paymentToken;
    MockRandomnessProvider internal provider;

    address internal seller = address(0x1);
    address internal buyer1 = address(0x2);
    address internal buyer2 = address(0x3);
    address internal feeRecipient = address(0x5);
    address internal stranger = address(0xBEEF);

    uint256 internal constant ASSET_AMOUNT = 1000 ether;
    uint256 internal constant TICKET_PRICE = 1 ether;
    uint256 internal constant TICKET_CAP = 100;
    uint256 internal constant SELLER_MIN = TICKET_PRICE * TICKET_CAP;
    uint16 internal constant WINNERS_COUNT = 3;
    uint256 internal constant FEE_BPS = 200;

    function setUp() public {
        // initialize() rejects a start time in the past, and every schedule below is built
        // relative to now, so start from a realistic clock.
        vm.warp(1_000_000);

        assetToken = new MockERC20("Asset", "ASSET");
        paymentToken = new MockERC20("Pay", "PAY");

        provider = new MockRandomnessProvider();
        // A seed is available the instant it is requested, so the draw needs no separate
        // fulfilment step. Tests that want a silent oracle install their own provider.
        provider.setAutoSeed(uint256(keccak256("spec-seed")));

        // The test contract is the factory owner (needed for setRandomnessProvider/setFeeBps).
        factory = new RaffleFactory(address(this), feeRecipient, FEE_BPS, address(provider));

        assetToken.mint(seller, ASSET_AMOUNT * 10);
        paymentToken.mint(buyer1, 100_000 ether);
        paymentToken.mint(buyer2, 100_000 ether);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    function _create(uint256 cap) internal returns (Raffle r) {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;
        vm.startPrank(seller);
        assetToken.approve(address(factory), ASSET_AMOUNT);
        address addr = factory.createRaffle(
            address(0),
            address(assetToken),
            ASSET_AMOUNT,
            address(paymentToken),
            TICKET_PRICE,
            cap,
            TICKET_PRICE * cap,
            startTime,
            endTime,
            WINNERS_COUNT
        );
        vm.stopPrank();
        r = Raffle(addr);
        vm.warp(startTime); // raffle is now active
    }

    function _buy(Raffle r, address who, uint256 n, address recipient) internal {
        vm.startPrank(who);
        paymentToken.approve(address(r), n * TICKET_PRICE);
        r.buyTickets(n, recipient);
        vm.stopPrank();
    }

    /// @dev Take a sold-out raffle all the way to Succeeded: settle the sale, then draw.
    function _settleSucceeded(Raffle r) internal {
        vm.warp(r.endTime());
        r.finalize();
        r.drawWinners();
    }

    // ------------------------------------------------------------------
    // 1. MECHANISMS.md:110  "claimRefund() ... Requires: finalized, !succeeded"
    //    docs/PRODUCT_FLOW_AND_DECISIONS.md:71 "Buyers can LATER claim refunds"
    //    (i.e. after settlement marks the raffle failed).
    // ------------------------------------------------------------------
    function test_Spec_ClaimRefundRequiresFinalized() public {
        raffle = _create(TICKET_CAP);
        _buy(raffle, buyer1, 10, address(0)); // under-sold
        vm.warp(raffle.endTime() + 1); // ended, but NOT settled
        assertFalse(raffle.finalized(), "precondition: not finalized");

        vm.prank(buyer1);
        vm.expectRevert("Raffle: not failed"); // docs: must revert because not failed
        raffle.claimRefund();
    }

    // ------------------------------------------------------------------
    // 2. README.md:29  "claimRefund() - Losers claim refunds (if raffle failed)"
    //    docs/PRODUCT_FLOW_AND_DECISIONS.md:82 "Losers (if raffle failed)"
    //    A sold-out raffle during its sale window has not failed.
    // ------------------------------------------------------------------
    function test_Spec_ClaimRefundRevertsOnSoldOutRaffle() public {
        raffle = _create(TICKET_CAP);
        _buy(raffle, buyer1, TICKET_CAP, address(0)); // sold out
        assertEq(raffle.totalFunds(), SELLER_MIN, "precondition: sold out");
        assertLt(block.timestamp, raffle.endTime(), "precondition: sale active");

        vm.prank(buyer1);
        vm.expectRevert("Raffle: not failed"); // docs: no refund unless the raffle failed
        raffle.claimRefund();
    }

    // ------------------------------------------------------------------
    // 3. MECHANISMS.md:123 "withdrawAsset() ... Requires: finalized, !succeeded"
    //    README.md:10 "Locks seller assets until the raffle completes"
    //    docs/PRODUCT_FLOW_AND_DECISIONS.md:36 "the prize is locked ... until
    //    the raffle is finalized"
    // ------------------------------------------------------------------
    function test_Spec_WithdrawAssetRequiresFinalized() public {
        raffle = _create(TICKET_CAP);
        _buy(raffle, buyer1, 10, address(0));
        assertLt(block.timestamp, raffle.endTime(), "precondition: sale active");
        assertFalse(raffle.finalized(), "precondition: not finalized");

        vm.prank(seller);
        vm.expectRevert("Raffle: not failed"); // docs: asset locked until settlement
        raffle.withdrawAsset();

        assertEq(assetToken.balanceOf(address(raffle)), ASSET_AMOUNT, "prize must still be escrowed");
    }

    // ------------------------------------------------------------------
    // 4. README.md:11,38 "Pull-based withdrawals"
    //    docs/PRODUCT_FLOW_AND_DECISIONS.md:79 "Settlement is entirely
    //    pull-based: the contract never pushes tokens to users."
    //    docs/PRODUCT_FLOW_AND_DECISIONS.md:128 "We never push tokens"
    // ------------------------------------------------------------------
    function test_Spec_ProtocolFeeIsPullBased() public {
        raffle = _create(TICKET_CAP);
        _buy(raffle, buyer1, TICKET_CAP, address(0));
        vm.warp(raffle.endTime());

        uint256 feeBalBefore = paymentToken.balanceOf(feeRecipient);
        uint256 raffleBalBefore = paymentToken.balanceOf(address(raffle));

        // Settlement is now two transactions; neither may move a token.
        raffle.finalize();
        assertEq(paymentToken.balanceOf(feeRecipient), feeBalBefore, "docs: finalize must not PUSH tokens");
        assertEq(
            paymentToken.balanceOf(address(raffle)), raffleBalBefore, "docs: no tokens leave the raffle during finalize"
        );

        raffle.drawWinners();
        assertEq(
            paymentToken.balanceOf(feeRecipient),
            feeBalBefore,
            "docs: the draw must not PUSH the fee either; it is pulled later"
        );
        assertEq(
            paymentToken.balanceOf(address(raffle)), raffleBalBefore, "docs: no tokens leave the raffle during the draw"
        );

        // The fee is owed, not sent, and anyone may pull it to the frozen recipient.
        uint256 expectedFee = (SELLER_MIN * FEE_BPS) / 10000;
        assertEq(raffle.protocolFeeOwed(), expectedFee, "fee is booked as owed");

        vm.prank(stranger);
        raffle.withdrawFee();

        assertEq(paymentToken.balanceOf(feeRecipient), feeBalBefore + expectedFee);
        assertEq(raffle.protocolFeeOwed(), 0);
    }

    // ------------------------------------------------------------------
    // 5. src/Raffle.sol "The implementation itself must never be usable as a raffle."
    //    docs/PRODUCT_FLOW_AND_DECISIONS.md:168 "A factory owns the implementation"
    //    The implementation is locked with _disableInitializers(), so initializing it
    //    reverts with OpenZeppelin's InvalidInitialization().
    // ------------------------------------------------------------------
    function test_Spec_ImplementationCannotBeInitialized() public {
        address impl = factory.RAFFLE_IMPLEMENTATION();
        assertEq(uint8(Raffle(impl).state()), uint8(Raffle.State.Uninitialized), "precondition: impl uninit");
        assertEq(Raffle(impl).FACTORY(), address(factory), "the implementation is bound to its factory");

        Raffle.RaffleParams memory p = Raffle.RaffleParams({
            seller: stranger,
            assetToken: address(assetToken),
            assetAmount: ASSET_AMOUNT,
            paymentToken: address(paymentToken),
            ticketPrice: TICKET_PRICE,
            ticketCap: TICKET_CAP,
            sellerMin: SELLER_MIN,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 days,
            winnersCount: WINNERS_COUNT,
            feeBps: FEE_BPS,
            feeRecipient: feeRecipient,
            randomnessProvider: address(provider)
        });

        vm.prank(stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Raffle(impl).initialize(p);

        // Not even the factory can wake the implementation up.
        vm.prank(address(factory));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Raffle(impl).initialize(p);

        assertEq(uint8(Raffle(impl).state()), uint8(Raffle.State.Uninitialized));
    }

    // ------------------------------------------------------------------
    // 6. canFinalize() "True when finalize() would be accepted right now";
    //    README.md:138 "After endTime, anyone can finalize".
    //    If canFinalize() is true, finalize() must succeed.
    // ------------------------------------------------------------------
    function test_Spec_FinalizeAllowedWhenCanFinalizeTrue() public {
        raffle = _create(TICKET_CAP);
        _buy(raffle, buyer1, 10, address(0)); // failure path: no draw
        vm.warp(raffle.endTime()); // exactly endTime
        assertTrue(raffle.canFinalize(), "precondition: view says finalizable");

        raffle.finalize(); // docs: must succeed
        assertTrue(raffle.finalized());
        assertTrue(raffle.hasFailed(), "under-sold raffles fail");
        assertFalse(raffle.canFinalize(), "the view closes once settled");
    }

    // ------------------------------------------------------------------
    // 7. README.md:184 "VRF Integration: Implement IRandomnessProvider and set
    //    via setRandomnessProvider()"; MECHANISMS.md:16 "Factory manages ...
    //    randomness provider"; MECHANISMS.md:204 "Can be upgraded to Chainlink
    //    VRF via IRandomnessProvider".
    //    The raffle must actually consult the provider, and must not be able to
    //    reach Succeeded on its own if the provider never answers.
    // ------------------------------------------------------------------
    function test_Spec_RandomnessProviderIsUsed() public {
        // A provider that is asked but never answers, i.e. a realistic oracle.
        MockRandomnessProvider silent = new MockRandomnessProvider();
        factory.setRandomnessProvider(address(silent)); // test contract is owner
        assertEq(address(factory.randomnessProvider()), address(silent));

        raffle = _create(TICKET_CAP);
        assertEq(address(raffle.randomnessProvider()), address(silent), "the raffle copies the provider in at creation");

        _buy(raffle, buyer1, TICKET_CAP, address(0));
        vm.warp(raffle.endTime());

        uint256 requestsBefore = silent.requestCount();
        vm.expectCall(address(silent), abi.encodeWithSelector(IRandomnessProvider.requestRandomness.selector));
        raffle.finalize();

        assertEq(silent.requestCount(), requestsBefore + 1, "docs: provider must be consulted");
        assertTrue(raffle.randomnessRequestId() != bytes32(0), "a request id is recorded");

        // No answer means no winners: the raffle cannot talk itself into Succeeded.
        assertEq(uint8(raffle.state()), uint8(Raffle.State.RandomnessPending));
        assertFalse(raffle.canDraw(), "nothing to draw from");

        vm.expectRevert("Raffle: randomness not ready");
        raffle.drawWinners();

        assertEq(
            uint8(raffle.state()),
            uint8(Raffle.State.RandomnessPending),
            "docs: unanswered randomness must never reach Succeeded"
        );
        assertFalse(raffle.succeeded());
        assertEq(raffle.getWinners().length, 0);

        // And the wait has an escape hatch, so nobody's money is trapped.
        vm.warp(block.timestamp + raffle.RANDOMNESS_TIMEOUT() + 1);
        raffle.failOnTimeout();
        assertTrue(raffle.hasFailed());

        // A seed that turns up after the escape hatch was used cannot resurrect the raffle.
        silent.fulfillLast(uint256(keccak256("late-seed")));
        assertGt(silent.getRandomness(raffle.randomnessRequestId()), 0);
        vm.expectRevert("Raffle: not pending");
        raffle.drawWinners();
        assertTrue(raffle.hasFailed());
    }

    // ------------------------------------------------------------------
    // 8. The per-address ticket limit ("Maximum 10,000 tickets per address") was
    //    REMOVED. It never bound the thing it claimed to bind: one payer could
    //    always route the excess to a second recipient address, so it capped an
    //    address rather than a buyer. The documented behaviour is now simply
    //    "there is no per-address limit"; only the ticket cap binds.
    // ------------------------------------------------------------------
    function test_Spec_NoPerAddressLimit() public {
        uint256 cap = 10_002;
        raffle = _create(cap);

        // Comfortably past the limit the old docs advertised, in one address.
        _buy(raffle, buyer1, 10_001, address(0));
        assertEq(raffle.tickets(buyer1), 10_001, "no per-address ceiling applies");

        // And the routing that used to defeat the limit is now plainly permitted.
        _buy(raffle, buyer1, 1, buyer2);
        assertEq(raffle.tickets(buyer2), 1, "payer may buy for someone else");
        assertEq(raffle.totalTickets(), cap);

        // The only ceiling left is the ticket cap.
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: exceeds cap");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // 9. src/Raffle.sol P-3 "Terms that live outside the raffle are copied in at
    //    creation and frozen"; RaffleFactory NatSpec "Settings here apply to raffles
    //    created from now on ... nothing the owner does can alter a raffle that is
    //    already selling tickets."
    // ------------------------------------------------------------------
    function test_Spec_FeeTermsFrozenAtCreation() public {
        raffle = _create(TICKET_CAP);
        assertEq(raffle.feeBps(), FEE_BPS, "born with the factory's 2%");

        // The owner raises the factory fee to the ceiling mid-sale.
        uint256 max = factory.MAX_FEE_BPS();
        factory.setFeeBps(max);
        factory.setFeeRecipient(stranger);
        assertEq(factory.feeBps(), max);

        assertEq(raffle.feeBps(), FEE_BPS, "the live raffle keeps its own terms");
        assertEq(raffle.feeRecipient(), feeRecipient, "and its own recipient");

        _buy(raffle, buyer1, TICKET_CAP, address(0));
        _settleSucceeded(raffle);

        uint256 expectedFee = (SELLER_MIN * FEE_BPS) / 10000; // 2 ether, not 10
        assertEq(raffle.protocolFeeOwed(), expectedFee, "settled at the frozen 2%");
        assertEq(raffle.sellerProceeds(), SELLER_MIN - expectedFee);

        uint256 strangerBefore = paymentToken.balanceOf(stranger);
        raffle.withdrawFee();
        assertEq(paymentToken.balanceOf(feeRecipient), expectedFee, "paid to the frozen recipient");
        assertEq(paymentToken.balanceOf(stranger), strangerBefore, "not to the factory's new recipient");
    }

    // ------------------------------------------------------------------
    // 10. Same promise for the randomness source: swapping the factory's provider
    //     must not reach into a raffle that is already selling tickets.
    // ------------------------------------------------------------------
    function test_Spec_ProviderFrozenAtCreation() public {
        raffle = _create(TICKET_CAP);
        assertEq(address(raffle.randomnessProvider()), address(provider));

        // The owner swaps the factory's provider mid-sale. The replacement would happily
        // answer, so if the raffle re-read the factory the swap would be observable.
        MockRandomnessProvider replacement = new MockRandomnessProvider();
        replacement.setAutoSeed(uint256(keccak256("replacement-seed")));
        factory.setRandomnessProvider(address(replacement));

        assertEq(
            address(raffle.randomnessProvider()),
            address(provider),
            "the live raffle keeps the provider it was born with"
        );

        _buy(raffle, buyer1, TICKET_CAP, address(0));
        _settleSucceeded(raffle);

        assertEq(provider.requestCount(), 1, "the original provider was asked");
        assertEq(replacement.requestCount(), 0, "the replacement was never asked");
        assertEq(uint8(raffle.state()), uint8(Raffle.State.Succeeded));
        assertEq(raffle.getWinners().length, WINNERS_COUNT);

        // A raffle created after the swap does get the new provider.
        Raffle later = _create(TICKET_CAP);
        assertEq(address(later.randomnessProvider()), address(replacement));
    }
}
