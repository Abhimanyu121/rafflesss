// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../../src/Raffle.sol";
import {RaffleFactory} from "../../src/RaffleFactory.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockRandomnessProvider} from "../mocks/MockRandomnessProvider.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @title Lifecycle / state-machine / timing / access-control REGRESSION suite
/// @notice These tests were originally written as proofs-of-concept against the pre-rewrite
///         contracts, where every `test_Exploit_*` PASSED because the attack worked. The
///         contracts were then rewritten (see docs/security/FINDINGS.md, findings R-01 to R-11).
///         Each PoC has been kept verbatim in its attack steps and comments, and only its final
///         assertions inverted: the attack must now be rejected, with the SPECIFIC revert reason.
///
///         Naming convention:
///           test_Fixed_*          -> the attack is now blocked (test passes == guard holds)
///           test_NotExploitable_* -> the attack never worked and still does not
///
///         If a future refactor reintroduces one of these bugs, the corresponding test turns red.
contract LifecycleAuditTest is Test {
    RaffleFactory public factory;
    Raffle public raffle;
    MockERC20 public assetToken;
    MockERC20 public paymentToken;
    MockRandomnessProvider public provider;

    address public seller = address(0x1);
    address public buyer1 = address(0x2);
    address public buyer2 = address(0x3);
    address public buyer3 = address(0x4);
    address public feeRecipient = address(0x5);
    address public attacker = address(0xA77A);
    address public anyone = address(0xBEEF);

    uint256 public constant ASSET_AMOUNT = 1000 * 10 ** 18;
    uint256 public constant TICKET_PRICE = 1 * 10 ** 18;
    uint256 public constant TICKET_CAP = 100;
    uint256 public constant SELLER_MIN = TICKET_PRICE * TICKET_CAP;
    uint16 public constant WINNERS_COUNT = 3;
    uint256 public constant FEE_BPS = 200; // 2%
    uint256 public constant START_BAL = 1000 * 10 ** 18;
    uint256 public constant SELLER_PAYOUT = SELLER_MIN - (SELLER_MIN * FEE_BPS) / 10000; // 98e18
    uint256 public constant PROTOCOL_FEE = (SELLER_MIN * FEE_BPS) / 10000; // 2e18

    /// @dev Fixed seed used wherever the draw only needs to be deterministic, not shaped.
    uint256 internal constant SEED = uint256(keccak256("lifecycle-audit-seed"));

    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        paymentToken = new MockERC20("Payment Token", "PAY");
        provider = new MockRandomnessProvider();
        // The test contract owns the factory so the fee-change PoC (LC-8) can call setFeeBps.
        factory = new RaffleFactory(address(this), feeRecipient, FEE_BPS, address(provider));

        paymentToken.mint(buyer1, START_BAL);
        paymentToken.mint(buyer2, START_BAL);
        paymentToken.mint(buyer3, START_BAL);
        paymentToken.mint(attacker, START_BAL);
        paymentToken.mint(seller, START_BAL);

        // Realistic chain height / time. The draw no longer depends on either, which is
        // exactly what test_Fixed_LC5_* asserts.
        vm.roll(10_000);
        vm.warp(1_700_000_000);
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _createRaffle() internal {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        assetToken.mint(seller, ASSET_AMOUNT);
        vm.startPrank(seller);
        assetToken.approve(address(factory), ASSET_AMOUNT);
        address raffleAddr = factory.createRaffle(
            address(0),
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

        vm.warp(startTime);
    }

    function _buy(address who, uint256 n) internal {
        _buyFor(who, n, address(0));
    }

    function _buyFor(address payer, uint256 n, address recipient) internal {
        vm.startPrank(payer);
        paymentToken.approve(address(raffle), n * TICKET_PRICE);
        raffle.buyTickets(n, recipient);
        vm.stopPrank();
    }

    /// @dev 34 + 33 + 33 = 100 = ticketCap -> totalFunds == sellerMin
    function _sellOutHonestly() internal {
        _buy(buyer1, 34);
        _buy(buyer2, 33);
        _buy(buyer3, 33);
        assertEq(raffle.totalFunds(), SELLER_MIN);
    }

    /// @dev The sale window is half-open: finalize() is legal from endTime onwards.
    function _atEnd() internal {
        vm.warp(raffle.endTime());
        vm.roll(block.number + WINNERS_COUNT + 10);
    }

    function _afterEnd() internal {
        vm.warp(raffle.endTime() + 1);
        vm.roll(block.number + WINNERS_COUNT + 10);
    }

    /// @dev Settlement is now two transactions: finalize() decides sold-out vs failed and
    ///      requests a seed; drawWinners() consumes the seed the provider delivered.
    function _settleWithSeed(uint256 s) internal {
        raffle.finalize();
        provider.fulfillLast(s);
        raffle.drawWinners();
    }

    /// @dev Test-only seed search. NOT an attack: the seed comes from the provider, so nobody
    ///      on-chain can choose it. This only lets a test reach a specific winner shape
    ///      (e.g. "the seller wins exactly one prize") deterministically.
    ///      Requires state == RandomnessPending with no seed delivered yet.
    function _drawUntilWins(address who, uint256 minWins, uint256 maxWins, uint256 maxSeeds)
        internal
        returns (uint256 seedUsed)
    {
        for (uint256 i = 1; i <= maxSeeds; i++) {
            uint256 snap = vm.snapshotState();
            uint256 s = uint256(keccak256(abi.encode("seed", i)));
            provider.fulfillLast(s);
            raffle.drawWinners();
            uint256 w = _countWins(who);
            if (w >= minWins && w <= maxWins) {
                return s;
            }
            vm.revertToState(snap);
        }
        revert("no seed produces the required winner pattern");
    }

    function _countWins(address who) internal view returns (uint256 c) {
        address[] memory w = raffle.getWinners();
        for (uint256 i = 0; i < w.length; i++) {
            if (w[i] == who) c++;
        }
    }

    function _holderEntries(address who) internal view returns (uint256 c) {
        uint256 n = raffle.totalTickets();
        for (uint256 i = 0; i < n; i++) {
            if (raffle.ticketHolders(i) == who) c++;
        }
    }

    /// @dev Every distinct winner claims once; returns the total asset paid out.
    function _claimAllPrizes() internal returns (uint256 paid) {
        address[] memory w = raffle.getWinners();
        for (uint256 i = 0; i < w.length; i++) {
            uint256 owed = raffle.pendingPrize(w[i]);
            if (owed == 0) continue;
            vm.prank(w[i]);
            raffle.claimPrize();
            paid += owed;
        }
    }

    function _assertState(Raffle.State expected) internal view {
        assertEq(uint8(raffle.state()), uint8(expected), "unexpected state");
    }

    // ============================================================
    // LC-1  (R-01, Critical) claimRefund() had no `finalized` gate: refunds worked BEFORE
    //       endTime (_succeeded() was always false before endTime) and did not unwind
    //       totalFunds / totalTickets / ticketHolders.
    //
    //       FIX: claimRefund() requires state == Failed. A live raffle has no refund path
    //       at all, so nothing can be unwound out from under the accounting.
    // ============================================================

    /// ORIGINAL ATTACK: buy -> refund (while active) -> raffle sells out -> finalize succeeds ->
    /// attacker holds free tickets in the draw, seller's payout is unpayable, honest buyers'
    /// funds are stuck.
    ///
    /// NOW: the very first step is impossible. The raffle then settles honestly, and the
    /// genuinely-failed path is shown to unwind to zero balances.
    function test_Fixed_LC1_RefundWhileActive_FreeTicketsAndStuckPayout() public {
        _createRaffle();
        _buy(buyer1, 30);
        _buy(buyer2, 30);
        _buy(attacker, 40); // raffle is now SOLD OUT
        assertEq(raffle.totalFunds(), SELLER_MIN);
        assertEq(paymentToken.balanceOf(address(raffle)), SELLER_MIN);

        // Still inside the sale window. The old gate was `!_succeeded()`, which was false
        // here, so the refund went through. The new gate names the state it needs.
        assertLt(block.timestamp, raffle.endTime());
        _assertState(Raffle.State.Active);
        vm.prank(attacker);
        vm.expectRevert("Raffle: not failed");
        raffle.claimRefund();

        // Nothing moved: money still escrowed, tickets still owned, draw unchanged.
        assertEq(paymentToken.balanceOf(attacker), START_BAL - 40e18);
        assertEq(raffle.tickets(attacker), 40);
        assertEq(raffle.totalFunds(), SELLER_MIN);
        assertEq(raffle.totalTickets(), TICKET_CAP);
        assertEq(_holderEntries(attacker), 40);
        assertEq(paymentToken.balanceOf(address(raffle)), SELLER_MIN);

        // Settlement now succeeds with a fully funded pot: every credit is payable.
        _afterEnd();
        _settleWithSeed(SEED);
        _assertState(Raffle.State.Succeeded);

        assertEq(raffle.sellerProceeds(), SELLER_PAYOUT);
        assertEq(raffle.protocolFeeOwed(), PROTOCOL_FEE);
        assertEq(_claimAllPrizes(), ASSET_AMOUNT);
        assertEq(assetToken.balanceOf(address(raffle)), 0);

        vm.prank(seller);
        raffle.withdrawSeller();
        raffle.withdrawFee(); // pull-based, callable by anyone
        assertEq(paymentToken.balanceOf(feeRecipient), PROTOCOL_FEE);
        assertEq(paymentToken.balanceOf(address(raffle)), 0);

        // ---- and the honest failed path still refunds everyone and returns the prize ----
        _createRaffle();
        uint256 b1Before = paymentToken.balanceOf(buyer1);
        uint256 b2Before = paymentToken.balanceOf(buyer2);
        _buy(buyer1, 10);
        _buy(buyer2, 5);
        _afterEnd();
        raffle.finalize(); // 15 < 100 tickets -> Failed, no seed needed
        _assertState(Raffle.State.Failed);

        vm.prank(buyer1);
        raffle.claimRefund();
        vm.prank(buyer2);
        raffle.claimRefund();
        vm.prank(seller);
        raffle.withdrawAsset();

        assertEq(paymentToken.balanceOf(buyer1), b1Before);
        assertEq(paymentToken.balanceOf(buyer2), b2Before);
        assertEq(assetToken.balanceOf(seller), ASSET_AMOUNT);
        assertEq(paymentToken.balanceOf(address(raffle)), 0);
        assertEq(assetToken.balanceOf(address(raffle)), 0);
    }

    /// ORIGINAL ATTACK (cheapest theft): buy 98 -> refund -> re-buy 2 (the per-address counter
    /// was reset). Contract then held exactly the protocol fee, the raffle was "sold out", the
    /// attacker owned 100% of the ticketHolders entries and won the whole prize for 2% of sellerMin.
    ///
    /// NOW: the refund leg reverts, so there is nothing to re-buy with, and the pot stays whole.
    function test_Fixed_LC1_RefundRebuy_StealPrizeForCostOfFee() public {
        _createRaffle();
        _buy(attacker, 98);

        vm.prank(attacker);
        vm.expectRevert("Raffle: not failed");
        raffle.claimRefund(); // was: 98e18 back, 98 entries left behind in ticketHolders

        // The attacker is still 98e18 out of pocket and cannot recycle it.
        assertEq(paymentToken.balanceOf(attacker), START_BAL - 98e18);
        assertEq(raffle.tickets(attacker), 98);
        assertEq(paymentToken.balanceOf(address(raffle)), 98e18);

        // Filling the raffle now costs the remaining 2 tickets in real money.
        _buy(buyer1, 2);
        assertEq(raffle.totalFunds(), SELLER_MIN);
        assertEq(paymentToken.balanceOf(address(raffle)), SELLER_MIN); // fully funded, not 2e18
        assertEq(_holderEntries(attacker), 98);

        _afterEnd();
        _settleWithSeed(SEED);
        _assertState(Raffle.State.Succeeded);

        // Whatever the attacker wins was paid for at face value, and the seller is payable.
        _claimAllPrizes();
        assertLe(assetToken.balanceOf(attacker), ASSET_AMOUNT, "cannot win more than the prize");
        assertEq(paymentToken.balanceOf(attacker), START_BAL - 98e18);

        assertEq(raffle.sellerProceeds(), SELLER_PAYOUT);
        vm.prank(seller);
        raffle.withdrawSeller();
        assertEq(paymentToken.balanceOf(seller), START_BAL + SELLER_PAYOUT);
    }

    /// ORIGINAL ATTACK (zero-cost griefing): buy everything, refund everything. totalFunds ==
    /// sellerMin with a 0 balance, so finalize()'s success branch reverted on the fee transfer
    /// forever and withdrawAsset() was blocked by `!_succeeded()`. The seller's prize was locked
    /// permanently. (Also demonstrated R-08: a revert in the success branch had no recovery.)
    ///
    /// NOW: the refund reverts, the pot stays funded, and the fee is pull-based so nothing in
    /// settlement can revert on a transfer at all.
    function test_Fixed_LC1_RefundAll_PermanentlyLocksSellerAssetAtZeroCost() public {
        _createRaffle();
        _buy(attacker, TICKET_CAP);

        vm.prank(attacker);
        vm.expectRevert("Raffle: not failed");
        raffle.claimRefund();

        assertEq(paymentToken.balanceOf(attacker), START_BAL - SELLER_MIN);
        assertEq(raffle.totalFunds(), SELLER_MIN);
        assertEq(paymentToken.balanceOf(address(raffle)), SELLER_MIN);

        _afterEnd();
        // Settlement no longer pushes anything: finalize() only moves state and asks for a seed.
        raffle.finalize();
        _assertState(Raffle.State.RandomnessPending);
        provider.fulfillLast(SEED);
        raffle.drawWinners();
        _assertState(Raffle.State.Succeeded);

        // The seller cannot pull the asset out of a succeeded raffle...
        vm.prank(seller);
        vm.expectRevert("Raffle: not failed");
        raffle.withdrawAsset();

        // ...and nothing is locked: every ledger drains to zero.
        assertEq(_claimAllPrizes(), ASSET_AMOUNT);
        vm.prank(seller);
        raffle.withdrawSeller();
        raffle.withdrawFee();
        assertEq(assetToken.balanceOf(address(raffle)), 0);
        assertEq(paymentToken.balanceOf(address(raffle)), 0);
    }

    // ============================================================
    // LC-2  (R-02, Critical) withdrawAsset() had no `finalized` gate: the seller could pull the
    //       prize any time before endTime and still let the raffle "succeed".
    //
    //       FIX: withdrawAsset() requires state == Failed, and the flag is set BEFORE the
    //       transfer. cancel() is the legitimate way for a seller to back out.
    // ============================================================

    function test_Fixed_LC2_SellerPullsPrizeWhileActive_ThenRaffleSucceeds() public {
        _createRaffle();
        _sellOutHonestly(); // 100e18 escrowed by honest buyers

        // 1 second before end, the seller tries to take the prize back.
        vm.warp(raffle.endTime() - 1);
        vm.prank(seller);
        vm.expectRevert("Raffle: not failed");
        raffle.withdrawAsset();

        assertEq(assetToken.balanceOf(seller), 0);
        assertEq(assetToken.balanceOf(address(raffle)), ASSET_AMOUNT);
        assertFalse(raffle.assetWithdrawnBySeller());

        _afterEnd();
        _settleWithSeed(SEED); // succeeds: totalFunds == sellerMin
        _assertState(Raffle.State.Succeeded);

        // Even after success the prize is not the seller's to take.
        vm.prank(seller);
        vm.expectRevert("Raffle: not failed");
        raffle.withdrawAsset();

        vm.prank(seller);
        raffle.withdrawSeller();
        // The seller gets the proceeds, and only the proceeds.
        assertEq(assetToken.balanceOf(seller), 0);
        assertEq(paymentToken.balanceOf(seller), START_BAL + SELLER_PAYOUT);

        // Every winner is credited AND payable.
        assertEq(_claimAllPrizes(), ASSET_AMOUNT);
        assertEq(assetToken.balanceOf(address(raffle)), 0);

        // Buyers cannot refund a raffle that succeeded, which is correct.
        vm.prank(buyer1);
        vm.expectRevert("Raffle: not failed");
        raffle.claimRefund();
    }

    /// ORIGINAL ATTACK: the seller removed the prize immediately after creation and kept selling
    /// tickets for a prize that was no longer escrowed ("phantom raffle").
    ///
    /// NOW: the prize cannot leave an Active raffle, so a ticket is always backed.
    function test_Fixed_LC2_SellerPullsPrizeAtStart_PhantomRaffleKeepsSelling() public {
        _createRaffle();
        vm.prank(seller);
        vm.expectRevert("Raffle: not failed");
        raffle.withdrawAsset();
        assertEq(assetToken.balanceOf(address(raffle)), ASSET_AMOUNT);

        // The raffle keeps accepting money, and the prize behind it is still there.
        _buy(buyer1, 10);
        assertEq(raffle.tickets(buyer1), 10);
        assertEq(raffle.assetAmount(), ASSET_AMOUNT);
        assertEq(assetToken.balanceOf(address(raffle)), ASSET_AMOUNT);

        // recoverToken() cannot be used as a back door to the same theft.
        vm.prank(seller);
        vm.expectRevert("Raffle: protected token");
        raffle.recoverToken(address(assetToken), seller);
        vm.prank(seller);
        vm.expectRevert("Raffle: protected token");
        raffle.recoverToken(address(paymentToken), seller);
    }

    /// The legitimate replacement for "seller changed their mind": cancel(), which only works
    /// while nobody has bought in, and which fails the raffle so the prize comes back.
    function test_Fixed_LC2_CancelIsTheLegitimateReplacement() public {
        // (a) no tickets sold -> seller may cancel and reclaim the prize
        _createRaffle();
        assertEq(raffle.totalTickets(), 0);
        vm.prank(attacker);
        vm.expectRevert("Raffle: not seller");
        raffle.cancel();
        vm.prank(seller);
        raffle.cancel();
        _assertState(Raffle.State.Failed);
        vm.prank(seller);
        raffle.withdrawAsset();
        assertEq(assetToken.balanceOf(seller), ASSET_AMOUNT);
        assertEq(assetToken.balanceOf(address(raffle)), 0);
        // and the cancelled raffle can no longer sell
        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: not active");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();

        // (b) one ticket sold -> cancelling is closed off forever
        _createRaffle();
        _buy(buyer1, 1);
        vm.prank(seller);
        vm.expectRevert("Raffle: tickets already sold");
        raffle.cancel();
        vm.prank(seller);
        vm.expectRevert("Raffle: not failed");
        raffle.withdrawAsset();
        assertEq(assetToken.balanceOf(address(raffle)), ASSET_AMOUNT);
    }

    // ============================================================
    // LC-3  (R-11, Medium) Timing boundary: buyTickets used `<= endTime`, finalize used
    //       `> endTime`, and the views used `>= endTime`. At block.timestamp == endTime a raffle
    //       was simultaneously "failed" (withdrawAsset allowed) and "open for purchase".
    //
    //       FIX: one half-open window [startTime, endTime). Selling stops at exactly the instant
    //       finalization becomes possible, so the two can never overlap.
    // ============================================================

    function test_Fixed_LC3_EndTimeBoundary_WithdrawAssetThenSellOutSameBlock() public {
        _createRaffle();
        _buy(buyer1, 50);
        _buy(buyer2, 49); // 99 / 100

        _atEnd(); // t == endTime exactly
        assertEq(block.timestamp, raffle.endTime());

        // The views and the implementation now agree at the boundary.
        assertTrue(raffle.canFinalize());
        assertFalse(raffle.hasFailed()); // nothing is decided until finalize() runs
        assertFalse(raffle.succeeded());
        assertFalse(raffle.finalized());

        // Leg 1 of the attack: the seller cannot take the prize out of a live raffle.
        vm.prank(seller);
        vm.expectRevert("Raffle: not failed");
        raffle.withdrawAsset();
        assertEq(assetToken.balanceOf(address(raffle)), ASSET_AMOUNT);

        // Leg 2 of the attack: the last ticket can no longer be bought at endTime.
        vm.startPrank(buyer3);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: ended");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();
        assertEq(raffle.totalTickets(), 99);

        // finalize() is accepted AT endTime (not one second later), and the raffle is under-sold.
        raffle.finalize();
        _assertState(Raffle.State.Failed);
        assertTrue(raffle.hasFailed());
        assertTrue(raffle.finalized());

        // Failed means: buyers whole, seller gets the prize back, nobody gets both.
        vm.prank(buyer1);
        raffle.claimRefund();
        vm.prank(buyer2);
        raffle.claimRefund();
        vm.prank(seller);
        raffle.withdrawAsset();
        vm.prank(seller);
        vm.expectRevert("Raffle: not succeeded");
        raffle.withdrawSeller();

        assertEq(paymentToken.balanceOf(buyer1), START_BAL);
        assertEq(paymentToken.balanceOf(buyer2), START_BAL);
        assertEq(paymentToken.balanceOf(seller), START_BAL); // no proceeds from a failed raffle
        assertEq(assetToken.balanceOf(seller), ASSET_AMOUNT);
        assertEq(paymentToken.balanceOf(address(raffle)), 0);
        assertEq(assetToken.balanceOf(address(raffle)), 0);
    }

    // ============================================================
    // LC-4  (R-05, High) `pendingWithdrawals` was shared between the seller's PAYMENT-token
    //       payout and winners' ASSET-token prizes. If the seller address was also a winner the
    //       two credits were summed into one slot and paid out in whichever token the seller
    //       claimed first.
    //
    //       FIX: three ledgers, each denominated in exactly one token and never combined:
    //         sellerProceeds (payment) / protocolFeeOwed (payment) / pendingPrize (asset).
    // ============================================================

    /// The seller holds tickets (still allowed) and wins 1-2 of the 3 prizes. The old code paid
    /// the whole mixed slot in ASSET units, so the seller took 98e18 of asset belonging to the
    /// honest winners and their own 98e18 of proceeds became unreachable.
    function test_Fixed_LC4_SellerIsWinner_OverpaidInAssetAndProceedsLocked() public {
        _createRaffle();
        _buy(seller, 34);
        _buy(buyer2, 33);
        _buy(buyer3, 33);

        _afterEnd();
        raffle.finalize();
        _drawUntilWins(seller, 1, 2, 500); // seller wins 1 or 2 of the 3 prizes
        uint256 k = _countWins(seller);
        assertGe(k, 1);
        assertLe(k, 2);

        uint256 per = ASSET_AMOUNT / WINNERS_COUNT;
        uint256 remainder = ASSET_AMOUNT % WINNERS_COUNT;

        // The two credits live in different ledgers and never touch.
        uint256 prize = raffle.pendingPrize(seller);
        assertGe(prize, k * per);
        assertLe(prize, k * per + remainder);
        assertEq(raffle.sellerProceeds(), SELLER_PAYOUT, "proceeds are exactly the payment-token payout");
        assertEq(raffle.protocolFeeOwed(), PROTOCOL_FEE);

        // claimPrize pays the ASSET ledger only...
        uint256 sellerPayBefore = paymentToken.balanceOf(seller);
        vm.prank(seller);
        raffle.claimPrize();
        assertEq(assetToken.balanceOf(seller), prize);
        assertEq(paymentToken.balanceOf(seller), sellerPayBefore);
        assertEq(raffle.pendingPrize(seller), 0);

        // ...and withdrawSeller pays the PAYMENT ledger only.
        vm.prank(seller);
        raffle.withdrawSeller();
        assertEq(assetToken.balanceOf(seller), prize);
        assertEq(paymentToken.balanceOf(seller), sellerPayBefore + SELLER_PAYOUT);

        // Every honest co-winner is paid in full; there is at least one, since k <= 2.
        uint256 honestPaid;
        uint256 honestWinners;
        address[] memory w = raffle.getWinners();
        for (uint256 i = 0; i < w.length; i++) {
            if (w[i] == seller) continue;
            uint256 owed = raffle.pendingPrize(w[i]);
            if (owed == 0) continue;
            honestWinners++;
            vm.prank(w[i]);
            raffle.claimPrize();
            assertEq(assetToken.balanceOf(w[i]), owed);
            honestPaid += owed;
        }
        assertGt(honestWinners, 0, "there must be an honest co-winner");
        assertEq(prize + honestPaid, ASSET_AMOUNT, "prizes sum to assetAmount");

        raffle.withdrawFee();
        assertEq(assetToken.balanceOf(address(raffle)), 0);
        assertEq(paymentToken.balanceOf(address(raffle)), 0);
    }

    /// Deterministic variant: the seller buys the whole raffle and wins all 3 prizes. The old
    /// code produced a single slot of 98e18 + 1000e18, so BOTH claimPrize and withdrawSeller
    /// reverted forever. Now both pay out in full, in their own tokens.
    function test_Fixed_LC4_SellerWinsAll_BothPayoutsBricked() public {
        _createRaffle();
        _buy(seller, TICKET_CAP);
        _afterEnd();
        _settleWithSeed(SEED);

        assertEq(_countWins(seller), WINNERS_COUNT);
        assertEq(raffle.pendingPrize(seller), ASSET_AMOUNT);
        assertEq(raffle.sellerProceeds(), SELLER_PAYOUT);
        assertEq(raffle.protocolFeeOwed(), PROTOCOL_FEE);

        vm.prank(seller);
        raffle.claimPrize();
        vm.prank(seller);
        raffle.withdrawSeller();
        vm.prank(seller);
        vm.expectRevert("Raffle: not failed");
        raffle.withdrawAsset();

        assertEq(assetToken.balanceOf(seller), ASSET_AMOUNT);
        // seller spent 100e18 on tickets and got 98e18 back as proceeds
        assertEq(paymentToken.balanceOf(seller), START_BAL - SELLER_MIN + SELLER_PAYOUT);

        raffle.withdrawFee();
        assertEq(paymentToken.balanceOf(feeRecipient), PROTOCOL_FEE);
        assertEq(assetToken.balanceOf(address(raffle)), 0);
        assertEq(paymentToken.balanceOf(address(raffle)), 0);
    }

    /// Griefing variant: anyone can still GIFT tickets to the seller via `recipient`. Under the
    /// old shared ledger a single gifted winning ticket made withdrawSeller() revert forever.
    /// Now the gift is just a ticket: it credits pendingPrize, and nothing is bricked.
    function test_Fixed_LC4_GiftTicketToSeller_BricksSellerWithdraw() public {
        _createRaffle();
        _buy(buyer1, 99);
        _buyFor(attacker, 1, seller); // attacker pays, seller "owns" the ticket
        assertEq(raffle.tickets(seller), 1);

        _afterEnd();
        raffle.finalize();
        _drawUntilWins(seller, 1, WINNERS_COUNT, 3000); // the gifted ticket wins

        assertGt(raffle.pendingPrize(seller), 0);
        assertEq(raffle.sellerProceeds(), SELLER_PAYOUT);

        uint256 prize = raffle.pendingPrize(seller);
        vm.prank(seller);
        raffle.withdrawSeller(); // no longer reverts
        vm.prank(seller);
        raffle.claimPrize();
        assertEq(paymentToken.balanceOf(seller), START_BAL + SELLER_PAYOUT);
        assertEq(assetToken.balanceOf(seller), prize);

        // buyer1's own prizes are untouched by the gift
        uint256 b1 = raffle.pendingPrize(buyer1);
        if (b1 > 0) {
            vm.prank(buyer1);
            raffle.claimPrize();
            assertEq(assetToken.balanceOf(buyer1), b1);
        }
        assertEq(prize + b1, ASSET_AMOUNT);
        raffle.withdrawFee();
        assertEq(assetToken.balanceOf(address(raffle)), 0);
        assertEq(paymentToken.balanceOf(address(raffle)), 0);
    }

    // ============================================================
    // LC-5  (R-04, Critical) finalize() was permissionless and the winners depended on the block
    //       it landed in: every input (previous blockhashes) is public before the block is built,
    //       so any finalizer could simulate and only submit in a block where they won.
    //
    //       FIX: blockhash is not used anywhere. The single seed comes from the randomness
    //       provider, and the block a transaction lands in is not an input to the draw.
    // ============================================================

    /// Runs the SAME raffle twice from a snapshot, with finalize()/drawWinners() landing in wildly
    /// different blocks, and the same provider seed. The winners must be byte-for-byte identical:
    /// there is no block to shop for.
    function test_Fixed_LC5_BlockShoppingCannotChangeWinners() public {
        _createRaffle();
        _buy(attacker, 34); // 34% of tickets
        _buy(buyer2, 33);
        _buy(buyer3, 33);
        _afterEnd();

        uint256 base = block.number;
        uint256 snap = vm.snapshotState();

        // Run A: the first eligible block, finalize and draw in the same block.
        vm.roll(base + 1);
        _settleWithSeed(SEED);
        address[] memory runA = raffle.getWinners();
        uint256 winsA = _countWins(attacker);
        uint256 prizeA = raffle.pendingPrize(attacker);
        vm.revertToState(snap);

        // Run B: 250,000 blocks and 10 days later, and with finalize() and drawWinners() split
        // across two far-apart blocks and different callers.
        snap = vm.snapshotState();
        vm.roll(base + 250_000);
        vm.warp(block.timestamp + 5 days);
        vm.prank(attacker);
        raffle.finalize();
        provider.fulfillLast(SEED);
        vm.roll(block.number + 4_000);
        vm.warp(block.timestamp + 5 hours);
        vm.prank(anyone);
        raffle.drawWinners();
        address[] memory runB = raffle.getWinners();

        assertEq(runB.length, runA.length);
        for (uint256 i = 0; i < runA.length; i++) {
            assertEq(runB[i], runA[i], "winner set must not depend on the block");
        }
        assertEq(_countWins(attacker), winsA);
        assertEq(raffle.pendingPrize(attacker), prizeA);
        vm.revertToState(snap);

        // And sweeping 50 consecutive blocks never changes a single winner.
        for (uint256 i = 1; i <= 50; i++) {
            uint256 s2 = vm.snapshotState();
            vm.roll(base + i * 7);
            vm.warp(raffle.endTime() + i * 13 minutes);
            vm.prank(attacker);
            raffle.finalize();
            provider.fulfillLast(SEED);
            vm.prank(attacker);
            raffle.drawWinners();
            address[] memory cur = raffle.getWinners();
            for (uint256 j = 0; j < cur.length; j++) {
                assertEq(cur[j], runA[j], "block shopping produced a new outcome");
            }
            vm.revertToState(s2);
        }
    }

    // ============================================================
    // LC-6  (R-03, Critical) RaffleFactory.createRaffle() pulled the asset from an ARBITRARY
    //       `raffleSeller`. Any address holding an allowance to the factory could have its tokens
    //       pulled into a raffle whose economics were chosen by the attacker.
    //
    //       FIX: `raffleSeller` must be msg.sender (or zero, meaning msg.sender), and the prize
    //       is always pulled from msg.sender. An ERC20 allowance is not authorization.
    // ============================================================

    function test_Fixed_LC6_AnyoneCreatesRaffleForApprover_StealsApprovedAsset() public {
        // Victim approves the factory in preparation for creating their own raffle (separate tx)
        assetToken.mint(seller, ASSET_AMOUNT);
        vm.prank(seller);
        assetToken.approve(address(factory), ASSET_AMOUNT);

        uint256 rafflesBefore = factory.getRaffleCount();

        // Attacker front-runs with attacker-chosen economics:
        // 1 ticket @ 1 wei, 1 winner, sale window = 1 second starting now.
        vm.prank(attacker);
        vm.expectRevert(RaffleFactory.SellerMustBeCaller.selector);
        factory.createRaffle(
            seller, // victim as seller
            address(assetToken),
            ASSET_AMOUNT,
            address(paymentToken),
            1, // ticketPrice
            1, // ticketCap
            1, // sellerMin
            block.timestamp,
            block.timestamp + 1,
            1 // winnersCount
        );

        // Nothing was pulled and nothing was registered.
        assertEq(assetToken.balanceOf(seller), ASSET_AMOUNT);
        assertEq(factory.getRaffleCount(), rafflesBefore);

        // The attacker cannot launder it through address(0) either: the prize is pulled from
        // msg.sender, so the pull fails on the attacker's own (absent) allowance.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, ASSET_AMOUNT)
        );
        factory.createRaffle(
            address(0),
            address(assetToken),
            ASSET_AMOUNT,
            address(paymentToken),
            TICKET_PRICE,
            TICKET_CAP,
            SELLER_MIN,
            block.timestamp,
            block.timestamp + 7 days,
            WINNERS_COUNT
        );
        assertEq(assetToken.balanceOf(seller), ASSET_AMOUNT);
        assertEq(factory.getRaffleCount(), rafflesBefore);

        // The owner of the allowance can still name themselves explicitly.
        vm.startPrank(seller);
        address ok = factory.createRaffle(
            seller,
            address(assetToken),
            ASSET_AMOUNT,
            address(paymentToken),
            TICKET_PRICE,
            TICKET_CAP,
            SELLER_MIN,
            block.timestamp + 1 days,
            block.timestamp + 7 days,
            WINNERS_COUNT
        );
        vm.stopPrank();
        assertEq(Raffle(ok).seller(), seller);
        assertEq(assetToken.balanceOf(ok), ASSET_AMOUNT);
        assertTrue(factory.isRaffle(ok));
    }

    // ============================================================
    // LC-7  (R-10, Medium) The implementation contract behind the clones was left uninitialized
    //       and initialize() was unguarded, so anyone could become its `factory`/`seller`.
    //
    //       FIX: OpenZeppelin Initializable + _disableInitializers() in the constructor, and the
    //       factory address is an immutable baked into the implementation bytecode.
    // ============================================================

    function test_Fixed_LC7_ImplementationInitializableByAnyone() public {
        Raffle impl = Raffle(factory.RAFFLE_IMPLEMENTATION());
        assertEq(impl.FACTORY(), address(factory)); // immutable, not msg.sender
        assertEq(impl.seller(), address(0));
        assertEq(uint8(impl.state()), uint8(Raffle.State.Uninitialized));

        Raffle.RaffleParams memory p = Raffle.RaffleParams({
            seller: attacker,
            assetToken: address(assetToken),
            assetAmount: ASSET_AMOUNT,
            paymentToken: address(paymentToken),
            ticketPrice: TICKET_PRICE,
            ticketCap: TICKET_CAP,
            sellerMin: SELLER_MIN,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 days,
            winnersCount: WINNERS_COUNT,
            feeBps: 0,
            feeRecipient: attacker,
            randomnessProvider: address(provider)
        });

        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(p);

        // The implementation is inert: still uninitialized, still not a raffle, unsellable.
        assertEq(impl.seller(), address(0));
        assertEq(uint8(impl.state()), uint8(Raffle.State.Uninitialized));
        assertFalse(factory.isRaffle(address(impl)));

        vm.startPrank(buyer1);
        paymentToken.approve(address(impl), TICKET_PRICE);
        vm.expectRevert("Raffle: not active");
        impl.buyTickets(1, address(0));
        vm.stopPrank();
        assertEq(paymentToken.balanceOf(address(impl)), 0);

        // Clones made by the factory are unaffected.
        _createRaffle();
        assertEq(raffle.FACTORY(), address(factory));
        assertTrue(factory.isRaffle(address(raffle)));
    }

    // ============================================================
    // LC-8  (R-06, High) The fee was read live from the factory at finalize() time rather than
    //       snapshotted at creation, so the owner could retroactively change a raffle's economics.
    //
    //       FIX: feeBps and feeRecipient are copied into the raffle at creation and frozen, and
    //       the factory's own cap is MAX_FEE_BPS = 1000 (10%).
    // ============================================================

    function test_Fixed_LC8_FactoryOwnerRaisesFeeTo100PctBeforeFinalize() public {
        _createRaffle();
        assertEq(raffle.feeBps(), FEE_BPS);
        assertEq(raffle.feeRecipient(), feeRecipient);
        _sellOutHonestly();
        _afterEnd();

        // A 100% fee is not even expressible any more.
        vm.expectRevert(RaffleFactory.InvalidFeeBps.selector);
        factory.setFeeBps(10_000); // owner == this test contract

        // The owner raises the fee to the maximum and redirects it, mid-raffle.
        factory.setFeeBps(factory.MAX_FEE_BPS());
        factory.setFeeRecipient(attacker);
        assertEq(factory.feeBps(), 1000);

        // The in-flight raffle keeps the terms it was born with.
        assertEq(raffle.feeBps(), FEE_BPS);
        assertEq(raffle.feeRecipient(), feeRecipient);

        _settleWithSeed(SEED);
        assertEq(raffle.protocolFeeOwed(), PROTOCOL_FEE); // 2%, not 10%
        assertEq(raffle.sellerProceeds(), SELLER_PAYOUT);

        raffle.withdrawFee();
        assertEq(paymentToken.balanceOf(feeRecipient), PROTOCOL_FEE);
        assertEq(paymentToken.balanceOf(attacker), START_BAL); // the new recipient gets nothing

        vm.prank(seller);
        raffle.withdrawSeller();
        assertEq(paymentToken.balanceOf(seller), START_BAL + SELLER_PAYOUT);
    }

    // ============================================================
    // LC-9  (R-08, High) There was no recovery when settlement reverted: `finalized` never became
    //       true while `_succeeded()` stayed true, so every exit was closed and all funds were
    //       locked forever.
    //
    //       FIX: every wait has an escape hatch that returns everyone's money (P-4).
    //         failOnTimeout()   -- the seed never arrived (RANDOMNESS_TIMEOUT = 1 day)
    //         failIfAbandoned() -- nobody ever settled  (FINALIZE_GRACE = 30 days)
    // ============================================================

    function test_Fixed_LC9_RandomnessTimeoutEscapeHatch() public {
        _createRaffle();
        _sellOutHonestly();
        _afterEnd();

        raffle.finalize(); // sold out -> waits for a seed that never comes
        _assertState(Raffle.State.RandomnessPending);
        assertFalse(raffle.canDraw());

        vm.expectRevert("Raffle: randomness not ready");
        raffle.drawWinners();

        // Not before the timeout.
        vm.warp(raffle.randomnessRequestedAt() + raffle.RANDOMNESS_TIMEOUT());
        vm.expectRevert("Raffle: not timed out");
        raffle.failOnTimeout();

        vm.warp(block.timestamp + 1);

        // And the hatch is not a race against a late seed: once the answer is there the raffle
        // must be drawn, not refunded, whoever calls first.
        uint256 snap = vm.snapshotState();
        provider.fulfillLast(SEED);
        vm.prank(anyone);
        vm.expectRevert("Raffle: randomness arrived, draw instead");
        raffle.failOnTimeout();
        raffle.drawWinners();
        _assertState(Raffle.State.Succeeded);
        vm.revertToState(snap);

        // With no answer at all, anyone can free the money.
        vm.prank(anyone);
        raffle.failOnTimeout();
        _assertState(Raffle.State.Failed);

        vm.prank(buyer1);
        raffle.claimRefund();
        vm.prank(buyer2);
        raffle.claimRefund();
        vm.prank(buyer3);
        raffle.claimRefund();
        vm.prank(seller);
        raffle.withdrawAsset();

        assertEq(paymentToken.balanceOf(buyer1), START_BAL);
        assertEq(paymentToken.balanceOf(buyer2), START_BAL);
        assertEq(paymentToken.balanceOf(buyer3), START_BAL);
        assertEq(assetToken.balanceOf(seller), ASSET_AMOUNT);
        assertEq(paymentToken.balanceOf(address(raffle)), 0);
        assertEq(assetToken.balanceOf(address(raffle)), 0);

        // A late seed cannot resurrect a failed raffle.
        provider.fulfillLast(SEED);
        vm.expectRevert("Raffle: not pending");
        raffle.drawWinners();
    }

    function test_Fixed_LC9_AbandonedRaffleEscapeHatch() public {
        _createRaffle();
        _sellOutHonestly();
        _afterEnd();

        // Nobody ever calls finalize().
        _assertState(Raffle.State.Active);
        vm.expectRevert("Raffle: grace not elapsed");
        raffle.failIfAbandoned();

        vm.warp(raffle.endTime() + raffle.FINALIZE_GRACE());
        vm.expectRevert("Raffle: grace not elapsed");
        raffle.failIfAbandoned();

        vm.warp(raffle.endTime() + raffle.FINALIZE_GRACE() + 1);
        vm.prank(anyone);
        raffle.failIfAbandoned();
        _assertState(Raffle.State.Failed);

        vm.prank(buyer1);
        raffle.claimRefund();
        vm.prank(buyer2);
        raffle.claimRefund();
        vm.prank(buyer3);
        raffle.claimRefund();
        vm.prank(seller);
        raffle.withdrawAsset();

        assertEq(paymentToken.balanceOf(buyer1), START_BAL);
        assertEq(assetToken.balanceOf(seller), ASSET_AMOUNT);
        assertEq(paymentToken.balanceOf(address(raffle)), 0);
        assertEq(assetToken.balanceOf(address(raffle)), 0);

        // Neither hatch can be used to fail a raffle that already settled.
        vm.expectRevert("Raffle: not active");
        raffle.failIfAbandoned();
        vm.expectRevert("Raffle: not pending");
        raffle.failOnTimeout();
    }

    // ============================================================
    // Attacks that were correctly blocked before the rewrite, and still are
    // ============================================================

    function test_NotExploitable_ClaimPrizeOrWithdrawSellerBeforeFinalize() public {
        _createRaffle();
        _sellOutHonestly();

        vm.prank(buyer1);
        vm.expectRevert("Raffle: not succeeded");
        raffle.claimPrize();
        vm.prank(seller);
        vm.expectRevert("Raffle: not succeeded");
        raffle.withdrawSeller();

        _afterEnd(); // ended, sold out, but nobody finalized
        vm.prank(buyer1);
        vm.expectRevert("Raffle: not succeeded");
        raffle.claimPrize();
        vm.prank(seller);
        vm.expectRevert("Raffle: not succeeded");
        raffle.withdrawSeller();

        // ...and still not while the seed is outstanding.
        raffle.finalize();
        _assertState(Raffle.State.RandomnessPending);
        vm.prank(buyer1);
        vm.expectRevert("Raffle: not succeeded");
        raffle.claimPrize();
        vm.prank(seller);
        vm.expectRevert("Raffle: not succeeded");
        raffle.withdrawSeller();
        vm.expectRevert("Raffle: not succeeded");
        raffle.withdrawFee();
    }

    /// Sold out + endTime passed + finalize never called: refunds and asset withdrawal are
    /// (correctly) blocked, and liveness is preserved because any third party can settle.
    function test_NotExploitable_SoldOutAfterEnd_NoFinalize_ThirdPartyCanFinalize() public {
        _createRaffle();
        _sellOutHonestly();
        _afterEnd();

        vm.prank(buyer1);
        vm.expectRevert("Raffle: not failed");
        raffle.claimRefund();
        vm.prank(seller);
        vm.expectRevert("Raffle: not failed");
        raffle.withdrawAsset();

        vm.prank(anyone);
        raffle.finalize();
        provider.fulfillLast(SEED);
        vm.prank(anyone);
        raffle.drawWinners();
        assertTrue(raffle.finalized());
        assertTrue(raffle.succeeded());

        vm.prank(seller);
        raffle.withdrawSeller();
        assertEq(paymentToken.balanceOf(seller), START_BAL + SELLER_PAYOUT);
    }

    /// Failed raffle: refunds only open once the raffle is actually Failed, and then the path
    /// closes with zero balances. (Before the rewrite the refund was allowed pre-finalization,
    /// which is what LC-1 turned into a theft.)
    function test_NotExploitable_FailedPath_RefundBeforeFinalizeThenWithdrawAsset() public {
        _createRaffle();
        _buy(buyer1, 10);
        vm.warp(raffle.endTime());

        // Under-sold and past the deadline, but nothing has been decided yet.
        vm.prank(buyer1);
        vm.expectRevert("Raffle: not failed");
        raffle.claimRefund();

        raffle.finalize();
        assertFalse(raffle.succeeded());
        assertTrue(raffle.hasFailed());

        vm.prank(buyer1);
        raffle.claimRefund();
        assertEq(paymentToken.balanceOf(buyer1), START_BAL);
        vm.prank(seller);
        raffle.withdrawAsset();
        assertEq(assetToken.balanceOf(seller), ASSET_AMOUNT);

        assertEq(paymentToken.balanceOf(address(raffle)), 0);
        assertEq(assetToken.balanceOf(address(raffle)), 0);
    }

    function test_NotExploitable_DoubleClaims_FailedPath() public {
        _createRaffle();
        _buy(buyer1, 10);
        _afterEnd();
        raffle.finalize();
        assertFalse(raffle.succeeded());

        vm.prank(buyer1);
        raffle.claimRefund();
        vm.prank(buyer1);
        vm.expectRevert("Raffle: no tickets");
        raffle.claimRefund();

        vm.prank(seller);
        raffle.withdrawAsset();
        vm.prank(seller);
        vm.expectRevert("Raffle: asset already withdrawn");
        raffle.withdrawAsset();

        vm.prank(seller);
        vm.expectRevert("Raffle: not succeeded");
        raffle.withdrawSeller();
        vm.prank(buyer1);
        vm.expectRevert("Raffle: not succeeded");
        raffle.claimPrize();

        vm.expectRevert("Raffle: not active");
        raffle.finalize();
        vm.expectRevert("Raffle: not pending");
        raffle.drawWinners();
    }

    function test_NotExploitable_DoubleClaims_SuccessPath() public {
        _createRaffle();
        _sellOutHonestly();
        _afterEnd();
        _settleWithSeed(SEED);
        assertTrue(raffle.succeeded());

        address w = raffle.getWinners()[0];
        vm.prank(w);
        raffle.claimPrize();
        vm.prank(w);
        vm.expectRevert("Raffle: no prize to claim");
        raffle.claimPrize();

        vm.prank(seller);
        raffle.withdrawSeller();
        vm.prank(seller);
        vm.expectRevert("Raffle: nothing to withdraw");
        raffle.withdrawSeller();

        raffle.withdrawFee();
        vm.expectRevert("Raffle: no fee to withdraw");
        raffle.withdrawFee();

        vm.prank(seller);
        vm.expectRevert("Raffle: not failed");
        raffle.withdrawAsset();
        vm.prank(w);
        vm.expectRevert("Raffle: not failed");
        raffle.claimRefund();

        vm.prank(anyone);
        vm.expectRevert("Raffle: no prize to claim");
        raffle.claimPrize();

        vm.expectRevert("Raffle: not active");
        raffle.finalize();
        vm.expectRevert("Raffle: not pending");
        raffle.drawWinners();
        vm.prank(buyer1);
        vm.expectRevert("Raffle: not active");
        raffle.buyTickets(1, address(0));
    }

    function test_NotExploitable_CloneCannotBeReinitialized() public {
        _createRaffle();
        Raffle.RaffleParams memory p = Raffle.RaffleParams({
            seller: attacker,
            assetToken: address(assetToken),
            assetAmount: ASSET_AMOUNT,
            paymentToken: address(paymentToken),
            ticketPrice: TICKET_PRICE,
            ticketCap: TICKET_CAP,
            sellerMin: SELLER_MIN,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 days,
            winnersCount: WINNERS_COUNT,
            feeBps: 0,
            feeRecipient: attacker,
            randomnessProvider: address(provider)
        });
        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        raffle.initialize(p);
        assertEq(raffle.seller(), seller);
    }

    /// At exactly endTime the views and the implementation now agree: canFinalize() is true and
    /// finalize() is accepted, while buyTickets() is already closed. (Before the rewrite this was
    /// a 1-second view/impl mismatch, and in combination with LC-3 an exploit.)
    function test_NotExploitable_FinalizeAtExactEndTime_ViewsDisagreeWithImpl() public {
        _createRaffle();
        _sellOutHonestly();
        _atEnd();

        assertTrue(raffle.canFinalize());
        assertFalse(raffle.succeeded());
        assertFalse(raffle.hasFailed());

        vm.startPrank(buyer1);
        paymentToken.approve(address(raffle), TICKET_PRICE);
        vm.expectRevert("Raffle: ended");
        raffle.buyTickets(1, address(0));
        vm.stopPrank();

        raffle.finalize();
        assertFalse(raffle.canFinalize());
        _assertState(Raffle.State.RandomnessPending);
        provider.fulfillLast(SEED);
        assertTrue(raffle.canDraw());
        raffle.drawWinners();
        assertTrue(raffle.finalized());
        assertTrue(raffle.succeeded());
    }

    /// The old `finalizationBlock >= winnersCount` guard existed only because the draw read
    /// blockhashes. The draw no longer reads chain history at all, so no block height can block
    /// or shape a settlement.
    function test_NotExploitable_LowBlockNumber_OnlyTemporarilyBlocksFinalize() public {
        _createRaffle();
        _sellOutHonestly();
        vm.warp(raffle.endTime());

        uint256 snap = vm.snapshotState();
        vm.roll(10_000_000);
        _settleWithSeed(SEED);
        address[] memory high = raffle.getWinners();
        vm.revertToState(snap);

        vm.roll(1); // a chain younger than winnersCount: no longer a special case
        _settleWithSeed(SEED);
        assertTrue(raffle.finalized());
        assertTrue(raffle.succeeded());

        address[] memory low = raffle.getWinners();
        assertEq(low.length, high.length);
        for (uint256 i = 0; i < low.length; i++) {
            assertEq(low[i], high[i], "block height is not an input to the draw");
        }
    }

    /// A partially-sold raffle: the cap is enforced while it is live, and once it fails a buyer
    /// can refund exactly once.
    function test_NotExploitable_RefundThenRefundAgainWithoutRebuy() public {
        _createRaffle();
        _buy(buyer1, 10);

        // No refunds while active -- that is LC-1.
        vm.prank(buyer1);
        vm.expectRevert("Raffle: not failed");
        raffle.claimRefund();

        // The cap counts every ticket ever sold.
        vm.startPrank(buyer2);
        paymentToken.approve(address(raffle), 100 * TICKET_PRICE);
        vm.expectRevert("Raffle: exceeds cap");
        raffle.buyTickets(91, address(0));
        vm.stopPrank();

        _afterEnd();
        raffle.finalize();
        _assertState(Raffle.State.Failed);

        vm.prank(buyer1);
        raffle.claimRefund();
        vm.prank(buyer1);
        vm.expectRevert("Raffle: no tickets");
        raffle.claimRefund();
        assertEq(paymentToken.balanceOf(buyer1), START_BAL);
    }
}
