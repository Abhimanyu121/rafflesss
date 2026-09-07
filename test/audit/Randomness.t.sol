// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 * Randomness / winner selection / prize math REGRESSION suite.
 *
 * These tests began life as adversarial PoCs against the pre-rewrite contracts, where every
 * `test_Exploit_*` PASSED because the attack worked (see docs/security/FINDINGS.md, findings
 * R-04, R-05, R-12, R-13, R-15, R-23). The contracts were then rewritten:
 *
 *   - `blockhash` is not used anywhere any more. One seed arrives from an IRandomnessProvider
 *     and is stretched with keccak256(abi.encode(seed, i)).
 *   - Settling the sale (`finalize`) and drawing the winners (`drawWinners`) are separate
 *     transactions, so whoever settles cannot see the seed when they do it.
 *   - The draw is a partial Fisher-Yates WITHOUT replacement, so no ticket index can win twice.
 *   - A pending seed request has a deadline (`failOnTimeout`, RANDOMNESS_TIMEOUT = 1 day).
 *
 * The grinding PoCs cannot be expressed the same way any more, because there is no chain data to
 * grind. They have been converted into the inverse statement: the outcome is a pure function of
 * the provider's seed, and of nothing else.
 *
 *   test_Fixed_*          -> the attack is now blocked / the property now holds
 *   test_NotExploitable_* -> an attack that never worked and still does not
 *
 * Run: forge test --match-path test/audit/Randomness.t.sol -vvv
 */

import {Test, console2} from "forge-std/Test.sol";
import {Raffle} from "../../src/Raffle.sol";
import {RaffleFactory} from "../../src/RaffleFactory.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockRandomnessProvider} from "../mocks/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../../src/interfaces/IRandomnessProvider.sol";

/// @dev A randomness provider that reverts if anything ever talks to it. Before the rewrite a
///      raffle could still settle with this provider configured, which proved the provider hook
///      was dead code. Now `finalize()` reverts, which proves the hook is live.
contract RevertingProvider is IRandomnessProvider {
    function requestRandomness(address, bytes32) external pure returns (bytes32) {
        revert("provider was called");
    }

    function getRandomness(bytes32) external pure returns (uint256) {
        revert("provider was called");
    }
}

contract RandomnessAuditTest is Test {
    RaffleFactory internal factory;
    MockERC20 internal assetToken;
    MockERC20 internal paymentToken;
    MockRandomnessProvider internal provider;

    address internal seller = address(0x1);
    address internal attacker = address(0xBAD);
    address internal honest1 = address(0x2);
    address internal honest2 = address(0x3);
    address internal feeRecipient = address(0x5);
    address internal anyone = address(0xBEEF);

    uint256 internal constant FEE_BPS = 200; // 2%, same as production tests
    uint256 internal constant HOLDER_BASE = 0xA0000; // distinct holder per ticket index: address(HOLDER_BASE + index)
    uint256 internal constant SEED = uint256(keccak256("randomness-audit-seed"));

    function setUp() public {
        assetToken = new MockERC20("Asset Token", "ASSET");
        paymentToken = new MockERC20("Payment Token", "PAY");
        provider = new MockRandomnessProvider();
        factory = new RaffleFactory(address(this), feeRecipient, FEE_BPS, address(provider));
        // Start on a "real" chain height. Nothing in the draw depends on it any more, which is
        // what test_NotExploitable_ChainHeightIsNotAnInputToTheDraw asserts.
        vm.roll(10_000);
        vm.warp(1_700_000_000);
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _create(uint256 assetAmount, uint256 ticketPrice, uint256 ticketCap, uint16 winnersCount)
        internal
        returns (Raffle r)
    {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;
        assetToken.mint(seller, assetAmount);
        vm.startPrank(seller);
        assetToken.approve(address(factory), assetAmount);
        address addr = factory.createRaffle(
            address(0),
            address(assetToken),
            assetAmount,
            address(paymentToken),
            ticketPrice,
            ticketCap,
            ticketPrice * ticketCap,
            startTime,
            endTime,
            winnersCount
        );
        vm.stopPrank();
        r = Raffle(addr);
        vm.warp(startTime);
    }

    /// @dev `payer` pays for `n` tickets credited to `recipient` (address(0) => payer).
    function _buyFor(Raffle r, address payer, address recipient, uint256 n) internal {
        uint256 cost = r.ticketPrice() * n;
        paymentToken.mint(payer, cost);
        vm.startPrank(payer);
        paymentToken.approve(address(r), cost);
        r.buyTickets(n, recipient);
        vm.stopPrank();
    }

    function _buy(Raffle r, address who, uint256 n) internal {
        _buyFor(r, who, address(0), n);
    }

    /// @dev Give every ticket index its own unique holder so winners[] can be decoded back to indices.
    function _fillWithDistinctHolders(Raffle r, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            _buy(r, _holder(i), 1);
        }
    }

    function _holder(uint256 index) internal pure returns (address) {
        return address(uint160(HOLDER_BASE + index));
    }

    function _indexOf(address holder) internal pure returns (uint256) {
        return uint256(uint160(holder)) - HOLDER_BASE;
    }

    /// @dev Settlement is two transactions now. The seed is only visible after finalize() has run.
    function _settle(Raffle r, uint256 s) internal {
        r.finalize();
        provider.fulfillLast(s);
        r.drawWinners();
    }

    /// @dev Test-only seed search. NOT an attack: no on-chain actor can pick the seed, because the
    ///      provider hands it out after finalize(). This only lets a test reach a specific winner
    ///      shape deterministically. Requires state == RandomnessPending with no seed delivered.
    function _drawUntilWins(Raffle r, address who, uint256 minWins, uint256 maxWins, uint256 maxSeeds)
        internal
        returns (uint256 seedUsed)
    {
        for (uint256 i = 1; i <= maxSeeds; i++) {
            uint256 snap = vm.snapshotState();
            uint256 s = uint256(keccak256(abi.encode("seed", i)));
            provider.fulfillLast(s);
            r.drawWinners();
            uint256 w = _countIn(r.getWinners(), who);
            if (w >= minWins && w <= maxWins) {
                return s;
            }
            vm.revertToState(snap);
        }
        revert("no seed produces the required winner pattern");
    }

    /// @dev Pure replica of Raffle._pickWinners()'s index selection: partial Fisher-Yates over a
    ///      virtual identity array, one seed stretched per draw. Used to enumerate far more seeds
    ///      than we could afford to run on-chain.
    function _replicaDraw(uint256 s, uint256 n, uint256 w) internal pure returns (uint256[] memory idx) {
        uint256[] memory arr = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            arr[i] = i;
        }
        idx = new uint256[](w);
        for (uint256 i = 0; i < w; i++) {
            uint256 j = i + (uint256(keccak256(abi.encode(s, i))) % (n - i));
            idx[i] = arr[j];
            arr[j] = arr[i];
        }
    }

    function _countIn(address[] memory arr, address who) internal pure returns (uint256 c) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == who) c++;
        }
    }

    function _sumPrizes(Raffle r, uint256 n) internal view returns (uint256 sum) {
        for (uint256 i = 0; i < n; i++) {
            sum += r.pendingPrize(_holder(i));
        }
    }

    // ============================================================
    // RN-1  (R-04, Critical) Grinding the finalization block.
    //
    //       WAS: every input to _pickWinners() at block B was the hash of blocks B-1..B-W, all of
    //       which are public before any transaction in block B is built. finalize() was
    //       permissionless and had no deadline, so an attacker simply waited for a block in which
    //       they won and finalized then. Measured: 10 of 100 tickets took ~1000 blocks to sweep
    //       all three prizes; 1 of 100 tickets took ~100 blocks to take the single prize.
    //
    //       NOW: the outcome is a pure function of the provider's seed. The block a transaction
    //       lands in, the timestamp, and the identity of the caller are not inputs, so there is
    //       nothing to grind.
    // ============================================================

    /// Same raffle, same seed, settled in wildly different blocks: identical winners every time.
    function test_Fixed_OutcomeIndependentOfFinalizeBlock() public {
        uint256 N = 100;
        uint16 W = 3;
        uint256 A = 1000 ether;
        Raffle r = _create(A, 1 ether, N, W);

        // honest buyers take indices 0..89, attacker takes 90..99 (10% of tickets)
        _buy(r, honest1, 45);
        _buy(r, honest2, 45);
        _buy(r, attacker, 10);
        assertEq(r.totalTickets(), N);

        vm.warp(r.endTime() + 1);
        uint256 base = block.number;

        // Reference run: the first eligible block, exactly what an honest keeper would do.
        uint256 snap = vm.snapshotState();
        vm.roll(base + 1);
        _settle(r, SEED);
        address[] memory baseline = r.getWinners();
        uint256 refAttackerWins = _countIn(baseline, attacker);
        uint256 refAttackerPrize = r.pendingPrize(attacker);
        console2.log("attacker prizes under the baseline settlement:", refAttackerWins, "of", W);
        vm.revertToState(snap);

        // The old attack was "wait for a better block". Sweep 120 candidate blocks spread over
        // 250k blocks and 40 days: not one of them changes a single winner.
        for (uint256 it = 0; it < 120; it++) {
            uint256 s2 = vm.snapshotState();
            vm.roll(base + 1 + it * 2_083);
            vm.warp(r.endTime() + 1 + it * 8 hours);

            vm.prank(attacker);
            r.finalize();
            provider.fulfillLast(SEED);
            // Splitting the draw into yet another block does not help either.
            vm.roll(block.number + it);
            vm.prank(attacker);
            r.drawWinners();

            address[] memory cur = r.getWinners();
            assertEq(cur.length, baseline.length);
            for (uint256 i = 0; i < cur.length; i++) {
                assertEq(cur[i], baseline[i], "winner set must not depend on the settlement block");
            }
            assertEq(_countIn(cur, attacker), refAttackerWins, "grinding cannot buy the attacker a prize");
            assertEq(r.pendingPrize(attacker), refAttackerPrize);
            vm.revertToState(s2);
        }
    }

    /// The counterpart of the old single-ticket grind: choosing the moment, and choosing who sends
    /// the transaction, cannot influence the result, because the seed comes from the provider and
    /// is not observable when finalize() is sent.
    function test_Fixed_CallerAndTimingCannotInfluenceOutcome() public {
        uint256 N = 100;
        Raffle r = _create(1 ether, 1 ether, N, 1);
        _buy(r, honest1, 99);
        _buy(r, attacker, 1); // index 99
        vm.warp(r.endTime() + 1);
        uint256 base = block.number;

        uint256 snap = vm.snapshotState();
        _settle(r, SEED);
        address baseline = r.getWinners()[0];
        vm.revertToState(snap);

        address[4] memory callers = [attacker, honest1, seller, anyone];
        for (uint256 it = 0; it < 200; it++) {
            uint256 s2 = vm.snapshotState();
            vm.roll(base + 1 + it);
            vm.warp(r.endTime() + 1 + it * 37 seconds);
            vm.prevrandao(bytes32(uint256(0xDEAD0000 + it)));

            address caller = callers[it % 4];
            vm.prank(caller);
            r.finalize();
            provider.fulfillLast(SEED);
            vm.prank(caller);
            r.drawWinners();

            assertEq(r.getWinners()[0], baseline, "the moment and the caller are not inputs");
            assertEq(r.seed(), SEED, "the raffle used exactly the seed the provider supplied");
            vm.revertToState(s2);
        }

        // Nobody can re-roll by finalizing "again" in a better block: the state machine is one-way.
        _settle(r, SEED);
        assertEq(r.getWinners()[0], baseline);
        vm.expectRevert("Raffle: not active");
        r.finalize();
        vm.expectRevert("Raffle: not pending");
        r.drawWinners();
    }

    // ============================================================
    // RN-2  (R-04) No finalization deadline: unlimited re-rolls, one per block.
    //
    //       WAS: the outcome changed in 49 of 49 consecutive blocks and finalize() was still
    //       accepted 5,000,000 blocks later, so an attacker could wait indefinitely for a
    //       favourable roll.
    //
    //       NOW: a raffle waiting for a seed re-rolls nothing, and the wait itself is bounded.
    //       Anyone may fail it after RANDOMNESS_TIMEOUT, and everyone is repaid.
    // ============================================================

    function test_Fixed_RandomnessTimeoutBoundsTheWait() public {
        uint256 N = 20;
        uint16 W = 3;
        Raffle r = _create(1000 ether, 1 ether, N, W);
        _fillWithDistinctHolders(r, N);
        vm.warp(r.endTime() + 1);

        r.finalize(); // sold out -> RandomnessPending, seed requested
        assertEq(uint8(r.state()), uint8(Raffle.State.RandomnessPending));
        uint256 requestedAt = r.randomnessRequestedAt();

        // (1) Waiting does not re-roll anything: with no seed there is simply no draw.
        for (uint256 b = 1; b <= 50; b++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            assertFalse(r.canDraw());
            vm.expectRevert("Raffle: randomness not ready");
            r.drawWinners();
        }
        assertEq(r.getWinners().length, 0);

        // (2) The wait is bounded. Not a second before the deadline...
        vm.warp(requestedAt + r.RANDOMNESS_TIMEOUT());
        vm.expectRevert("Raffle: not timed out");
        r.failOnTimeout();

        // ...and the hatch is not a race against a late seed either: once the answer is there,
        // the raffle must be drawn, not refunded, no matter who calls first.
        vm.warp(requestedAt + r.RANDOMNESS_TIMEOUT() + 1);
        uint256 snap = vm.snapshotState();
        provider.fulfillLast(SEED);
        vm.prank(anyone);
        vm.expectRevert("Raffle: randomness arrived, draw instead");
        r.failOnTimeout();
        r.drawWinners();
        assertEq(uint8(r.state()), uint8(Raffle.State.Succeeded));
        vm.revertToState(snap);

        // With no answer at all, anyone can free the money.
        vm.prank(anyone);
        r.failOnTimeout();
        assertEq(uint8(r.state()), uint8(Raffle.State.Failed));

        // (3) Everyone is repaid, and the seller gets the prize back.
        for (uint256 i = 0; i < N; i++) {
            vm.prank(_holder(i));
            r.claimRefund();
            assertEq(paymentToken.balanceOf(_holder(i)), r.ticketPrice());
        }
        vm.prank(seller);
        r.withdrawAsset();
        assertEq(assetToken.balanceOf(seller), 1000 ether);
        assertEq(paymentToken.balanceOf(address(r)), 0);
        assertEq(assetToken.balanceOf(address(r)), 0);

        // (4) A seed that shows up late cannot resurrect the raffle.
        provider.fulfillLast(SEED);
        vm.expectRevert("Raffle: not pending");
        r.drawWinners();
    }

    // ============================================================
    // RN-3  (R-28) Bounded draw cost and chain-height independence.
    // ============================================================

    function RAFFLE_IMPL_MAX_WINNERS() internal view returns (uint256) {
        return Raffle(factory.RAFFLE_IMPLEMENTATION()).MAX_WINNERS_COUNT();
    }

    /// @dev MAX_WINNERS_COUNT was reduced from 200 to 100 after this test measured a
    ///      200-winner draw at roughly 28M gas, which does not fit a 30M block on every
    ///      chain and had no partial-draw fallback. Read the constant so the measurement
    ///      always tracks the real ceiling.
    function test_NotExploitable_MaxWinnersGas() public {
        uint16 W = uint16(RAFFLE_IMPL_MAX_WINNERS());
        uint256 N = W;
        Raffle r = _create(1000 ether, 1 ether, N, W);
        _fillWithDistinctHolders(r, N);
        vm.warp(r.endTime() + 1);

        uint256 g = gasleft();
        r.finalize();
        g -= gasleft();
        console2.log("finalize() gas (no draw, just state + seed request):", g);

        provider.fulfillLast(SEED);
        g = gasleft();
        r.drawWinners();
        g -= gasleft();
        console2.log("drawWinners() gas at MAX_WINNERS_COUNT:", g);
        assertLt(g, 20_000_000, "full draw must fit a 30M gas block with margin");
        assertEq(r.getWinners().length, W);

        // claimPrize is now a single mapping read; no winners-array scan.
        address w0 = r.getWinners()[0];
        g = gasleft();
        vm.prank(w0);
        r.claimPrize();
        g -= gasleft();
        console2.log("claimPrize() gas at MAX_WINNERS_COUNT:", g);
    }

    /// The old `finalizationBlock >= winnersCount` guard existed only because the draw read
    /// blockhash(finalizationBlock - 1 - i). The draw reads no chain history at all now, so the
    /// height of the chain neither blocks nor shapes a settlement.
    function test_NotExploitable_ChainHeightIsNotAnInputToTheDraw() public {
        Raffle r = _create(3 ether, 1 ether, 3, 3);
        _fillWithDistinctHolders(r, 3);
        vm.warp(r.endTime() + 1);

        uint256 snap = vm.snapshotState();
        vm.roll(50_000_000);
        _settle(r, SEED);
        address[] memory high = r.getWinners();
        vm.revertToState(snap);

        vm.roll(2); // a chain younger than winnersCount: used to revert "insufficient blocks"
        _settle(r, SEED);
        address[] memory low = r.getWinners();
        assertEq(low.length, high.length);
        for (uint256 i = 0; i < low.length; i++) {
            assertEq(low[i], high[i], "chain height is not an input");
        }
    }

    // ============================================================
    // RN-4  (R-13, Medium) Zero blockhash degenerate case.
    //
    //       WAS: if every hash was 0 (out-of-window read, or an L2/VM whose BLOCKHASH returns 0),
    //       the draw degenerated to indices 0,1,2,3,3,3,3...: ticket #3 won every prize after the
    //       fourth and tickets 4..9 could never win.
    //
    //       NOW: a provider that answers zero has not answered. The raffle stays in
    //       RandomnessPending and drawWinners() refuses; it never produces a degenerate list.
    // ============================================================

    function test_Fixed_ZeroSeedRejected() public {
        uint256 N = 10;
        uint16 W = 10;
        uint256 A = 1000 ether;
        Raffle r = _create(A, 1 ether, N, W);
        _fillWithDistinctHolders(r, N);
        vm.warp(r.endTime() + 1);

        r.finalize();
        assertEq(uint8(r.state()), uint8(Raffle.State.RandomnessPending));

        // The provider answers zero, repeatedly.
        provider.fulfillLast(0);
        assertEq(provider.getRandomness(r.randomnessRequestId()), 0);
        assertFalse(r.canDraw());

        for (uint256 i = 0; i < 5; i++) {
            vm.roll(block.number + 1);
            vm.expectRevert("Raffle: randomness not ready");
            r.drawWinners();
        }

        // Nothing was decided: no winners, no credits, still waiting.
        assertEq(uint8(r.state()), uint8(Raffle.State.RandomnessPending));
        assertEq(r.getWinners().length, 0);
        assertEq(r.seed(), 0);
        for (uint256 i = 0; i < N; i++) {
            assertEq(r.pendingPrize(_holder(i)), 0, "no ticket may be credited from a zero seed");
        }

        // A real seed then produces a proper draw: 10 prizes over 10 distinct tickets.
        provider.fulfillLast(SEED);
        assertTrue(r.canDraw());
        r.drawWinners();
        assertEq(r.seed(), SEED);
        for (uint256 i = 0; i < N; i++) {
            assertEq(r.pendingPrize(_holder(i)), A / W, "every ticket wins exactly one prize");
        }
        assertEq(_sumPrizes(r, N), A);
    }

    // ============================================================
    // RN-5  (R-12, Medium) Collision fallback paid one ticket index twice and excluded another.
    //
    //       WAS: on a collision the loop stepped to random+1 at most three times and then assigned
    //       the index anyway, even if it had already won. With 5 tickets, 5 prizes and hashes
    //       congruent to 2 mod 5 the sequence was 2,3,4,0,0: ticket #0 was paid twice and ticket
    //       #1 never won although there were as many prizes as tickets. 1 in 5 full draws did this.
    //
    //       NOW: the draw is a partial Fisher-Yates over the not-yet-drawn range [i, n), so a
    //       drawn ticket leaves the pool. No ticket index can win twice.
    // ============================================================

    function test_Fixed_NoTicketIndexWinsTwice() public {
        uint256 N = 5;
        uint16 W = 5;
        uint256 A = 500 ether;

        // Include the exact residue pattern that used to break it: a seed whose first stretched
        // hash is congruent to 2 mod 5, which under the old code started the 2,3,4,0,0 sequence.
        uint256 residue2Seed;
        for (uint256 s = 1; s < 10_000; s++) {
            if (uint256(keccak256(abi.encode(s, uint256(0)))) % N == 2) {
                residue2Seed = s;
                break;
            }
        }
        assertGt(residue2Seed, 0, "expected to find a residue-2 seed");

        uint256[6] memory seeds =
            [residue2Seed, uint256(1), uint256(2), uint256(12345), uint256(keccak256("another")), SEED];

        for (uint256 c = 0; c < seeds.length; c++) {
            Raffle r = _create(A, 1 ether, N, W);
            _fillWithDistinctHolders(r, N);
            vm.warp(r.endTime() + 1);
            _settle(r, seeds[c]);

            address[] memory winners = r.getWinners();
            assertEq(winners.length, W);

            // Every ticket index wins exactly once: the draw is a permutation.
            uint256 seen;
            for (uint256 i = 0; i < W; i++) {
                uint256 idx = _indexOf(winners[i]);
                assertLt(idx, N);
                assertEq((seen >> idx) & 1, 0, "a ticket index won twice");
                seen |= (uint256(1) << idx);
            }
            assertEq(seen, (uint256(1) << N) - 1, "some ticket index was excluded");

            // Every winner is credited an equal share, and the shares sum to assetAmount exactly.
            assertEq(_sumPrizes(r, N), A, "credited total must equal assetAmount");
            for (uint256 i = 0; i < N; i++) {
                assertEq(r.pendingPrize(_holder(i)), A / W);
                vm.prank(_holder(i));
                r.claimPrize(); // every winner can claim; nobody's claim reverts
            }
            assertEq(assetToken.balanceOf(address(r)), 0, "no asset dust");
        }
    }

    /// The exhaustive counterpart of the old collision-bias enumeration. The on-chain draw is
    /// cross-checked against a pure replica for a few seeds, and the replica is then enumerated
    /// over thousands of seeds to show the draw is always without replacement.
    function test_Fixed_DrawIsWithoutReplacement() public {
        uint256 N = 5;
        uint16 W = 5;
        uint256 A = 500 ether;

        // (a) the replica really is the contract
        uint256[3] memory checkSeeds = [uint256(7), uint256(99), SEED];
        for (uint256 c = 0; c < checkSeeds.length; c++) {
            Raffle r = _create(A, 1 ether, N, W);
            _fillWithDistinctHolders(r, N);
            vm.warp(r.endTime() + 1);
            _settle(r, checkSeeds[c]);
            uint256[] memory predicted = _replicaDraw(checkSeeds[c], N, W);
            address[] memory winners = r.getWinners();
            for (uint256 i = 0; i < W; i++) {
                assertEq(_indexOf(winners[i]), predicted[i], "replica must match the contract");
            }
            assertEq(_sumPrizes(r, N), A);
        }

        // (b) enumerate 3125 seeds at N=W=5 -- the same population size the old PoC used to show
        //     that 1 in 5 draws double-paid a ticket. Now the rate of duplicates is exactly zero.
        uint256 duplicates;
        for (uint256 s = 0; s < 3125; s++) {
            uint256[] memory idx = _replicaDraw(s, 5, 5);
            uint256 seen;
            for (uint256 i = 0; i < idx.length; i++) {
                if ((seen >> idx[i]) & 1 == 1) duplicates++;
                seen |= (uint256(1) << idx[i]);
            }
            assertEq(seen, uint256(31), "every full draw must be a permutation of all 5 tickets");
        }
        assertEq(duplicates, 0, "no seed may pay a ticket index twice");

        // (c) a full draw over a larger pool is still without replacement
        for (uint256 s = 0; s < 100; s++) {
            uint256[] memory idx = _replicaDraw(s, 200, 200);
            uint256 seenLo;
            uint256 seenHi;
            for (uint256 i = 0; i < idx.length; i++) {
                assertLt(idx[i], 200);
                if (idx[i] < 128) {
                    assertEq((seenLo >> idx[i]) & 1, 0, "duplicate in a 200-ticket draw");
                    seenLo |= (uint256(1) << idx[i]);
                } else {
                    assertEq((seenHi >> (idx[i] - 128)) & 1, 0, "duplicate in a 200-ticket draw");
                    seenHi |= (uint256(1) << (idx[i] - 128));
                }
            }
        }
    }

    /// An ADDRESS holding several tickets can still win more than once. That is deliberate product
    /// behaviour ("one ticket, one entry"), not the R-12 bug, and it must not regress: the fix
    /// removes duplicate TICKET INDICES, not duplicate winners.
    function test_Fixed_MultipleTicketsSameAddressCanStillWinTwice() public {
        uint256 N = 10;
        uint16 W = 3;
        uint256 A = 900 ether;
        Raffle r = _create(A, 1 ether, N, W);
        _buy(r, honest1, 8); // one address, eight tickets
        _buy(r, honest2, 2);
        vm.warp(r.endTime() + 1);

        r.finalize();
        _drawUntilWins(r, honest1, 2, W, 200);

        address[] memory winners = r.getWinners();
        assertEq(winners.length, W);
        uint256 wins = _countIn(winners, honest1);
        assertGe(wins, 2, "an address with many tickets must be able to win several prizes");
        assertEq(r.pendingPrize(honest1), wins * (A / W));

        uint256 before = assetToken.balanceOf(honest1);
        vm.prank(honest1);
        r.claimPrize();
        assertEq(assetToken.balanceOf(honest1) - before, wins * (A / W));

        if (r.pendingPrize(honest2) > 0) {
            vm.prank(honest2);
            r.claimPrize();
        }
        assertEq(assetToken.balanceOf(address(r)), 0);
    }

    // ============================================================
    // RN-6  (R-15, Low) assetAmount < winnersCount produced winners whose claimPrize() reverted.
    //
    //       WAS: assetAmount = 2 wei with 3 winners was accepted; draws 0 and 1 got 1 wei and
    //       draw 2 got nothing, so the third winner's claimPrize() reverted "no prize to claim".
    //
    //       NOW: rejected at creation. Every declared winner must be able to receive a non-zero
    //       share, so the raffle can never exist in that shape.
    // ============================================================

    function test_Fixed_PrizeTooSmallRejectedAtCreation() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        assetToken.mint(seller, 10);
        vm.startPrank(seller);
        assetToken.approve(address(factory), 10);

        // 2 wei of asset for 3 winners: refused.
        vm.expectRevert("Raffle: prize too small for winners");
        factory.createRaffle(
            address(0), address(assetToken), 2, address(paymentToken), 1 ether, 3, 3 ether, startTime, endTime, 3
        );

        // Exactly one wei per winner is the boundary, and it is allowed.
        address addr = factory.createRaffle(
            address(0), address(assetToken), 3, address(paymentToken), 1 ether, 3, 3 ether, startTime, endTime, 3
        );
        vm.stopPrank();

        Raffle r = Raffle(addr);
        vm.warp(startTime);
        _fillWithDistinctHolders(r, 3);
        vm.warp(r.endTime() + 1);
        _settle(r, SEED);

        // Every winner has a non-zero prize and every winner can claim it.
        address[] memory winners = r.getWinners();
        assertEq(winners.length, 3);
        for (uint256 i = 0; i < winners.length; i++) {
            assertEq(r.pendingPrize(winners[i]), 1);
            vm.prank(winners[i]);
            r.claimPrize();
            assertEq(assetToken.balanceOf(winners[i]), 1);
        }
        assertEq(assetToken.balanceOf(address(r)), 0);
    }

    /// Sum of credited prizes always equals assetAmount (W*(A/W) + A%W == A). No dust is stuck.
    function test_NotExploitable_PrizeSumEqualsAssetAmount() public {
        uint256[4] memory amounts = [uint256(1000 ether), 7, 1e18 + 1, 999_999_999_999];
        uint16[4] memory ws = [uint16(3), 5, 7, 13];
        for (uint256 c = 0; c < 4; c++) {
            uint256 N = 20;
            Raffle r = _create(amounts[c], 1 ether, N, ws[c]);
            _fillWithDistinctHolders(r, N);
            vm.warp(r.endTime() + 1);
            _settle(r, uint256(keccak256(abi.encode(SEED, c))));

            assertEq(_sumPrizes(r, N), amounts[c], "credited == assetAmount");
            // every winner can claim, and the contract ends with 0 asset
            address[] memory winners = r.getWinners();
            for (uint256 i = 0; i < winners.length; i++) {
                if (r.pendingPrize(winners[i]) > 0) {
                    vm.prank(winners[i]);
                    r.claimPrize();
                }
            }
            assertEq(assetToken.balanceOf(address(r)), 0, "no asset dust");
        }
    }

    // ============================================================
    // RN-7  (R-05, High) One `pendingWithdrawals` mapping held the seller payout (payment-token
    //       units) and the winners' prizes (asset-token units).
    //
    //       WAS: a seller holding a winning ticket ended up with one number equal to
    //       sellerPayout + prize. claimPrize() paid it all in ASSET (robbing the other winners)
    //       and withdrawSeller() tried to pay it all in PAYMENT (reverting forever).
    //
    //       NOW: sellerProceeds and protocolFeeOwed are payment-token ledgers; pendingPrize is an
    //       asset-token ledger. They are never combined.
    // ============================================================

    /// The seller buys the last unsold ticket so the raffle can succeed, and that ticket wins.
    function test_Fixed_SellerLedgersStaySeparate() public {
        uint256 N = 100;
        uint16 W = 3;
        uint256 A = 1000 ether;
        Raffle r = _create(A, 1 ether, N, W);
        _buy(r, honest1, 50); // idx 0..49
        _buy(r, honest2, 49); // idx 50..98
        _buy(r, seller, 1); // idx 99  <- seller buys the last unsold ticket so the raffle can succeed
        vm.warp(r.endTime() + 1);

        r.finalize();
        _drawUntilWins(r, seller, 1, W, 3000);

        uint256 sellerWins = _countIn(r.getWinners(), seller);
        assertGe(sellerWins, 1);
        uint256 per = A / W;
        uint256 sellerPayout = 100 ether - (100 ether * FEE_BPS) / 10_000; // 98e18 PAY
        uint256 fee = (100 ether * FEE_BPS) / 10_000; // 2e18 PAY

        // (1) The two credits are in different ledgers, each in its own token.
        uint256 prize = r.pendingPrize(seller);
        assertGe(prize, sellerWins * per);
        assertLe(prize, sellerWins * per + (A % W));
        assertEq(r.sellerProceeds(), sellerPayout, "proceeds are exactly the payment-token payout");
        assertEq(r.protocolFeeOwed(), fee);
        assertEq(paymentToken.balanceOf(address(r)), sellerPayout + fee);

        // (2) withdrawSeller() pays PAY only, and works.
        uint256 sellerPayBefore = paymentToken.balanceOf(seller);
        vm.prank(seller);
        r.withdrawSeller();
        assertEq(paymentToken.balanceOf(seller) - sellerPayBefore, sellerPayout);
        assertEq(assetToken.balanceOf(seller), 0, "no asset leaked through the payment ledger");

        // (3) claimPrize() pays ASSET only, and exactly the prize entitlement.
        vm.prank(seller);
        r.claimPrize();
        assertEq(assetToken.balanceOf(seller), prize);
        assertEq(paymentToken.balanceOf(seller) - sellerPayBefore, sellerPayout);

        // (4) the honest winners are paid in full -- the asset pool is not short.
        uint256 honestEntitlement = r.pendingPrize(honest1) + r.pendingPrize(honest2);
        assertEq(assetToken.balanceOf(address(r)), honestEntitlement, "asset pool covers every claim");
        if (r.pendingPrize(honest1) > 0) {
            uint256 owed = r.pendingPrize(honest1);
            vm.prank(honest1);
            r.claimPrize();
            assertEq(assetToken.balanceOf(honest1), owed);
        }
        if (r.pendingPrize(honest2) > 0) {
            uint256 owed = r.pendingPrize(honest2);
            vm.prank(honest2);
            r.claimPrize();
            assertEq(assetToken.balanceOf(honest2), owed);
        }
        assertEq(prize + honestEntitlement, A);

        // (5) nothing is stranded.
        r.withdrawFee();
        assertEq(paymentToken.balanceOf(feeRecipient), fee);
        assertEq(assetToken.balanceOf(address(r)), 0);
        assertEq(paymentToken.balanceOf(address(r)), 0);
    }

    /// Griefing variant: the seller never opts in. Anyone can still gift a ticket to the seller via
    /// buyTickets(1, seller). Under the shared ledger that one gift locked the seller's entire
    /// payout AND their prize. Now a gifted winning ticket locks nothing at all.
    function test_Fixed_GiftedTicketToSellerLocksNothing() public {
        uint256 N = 100;
        uint16 W = 3;
        uint256 A = 1000 ether;
        Raffle r = _create(A, 1 ether, N, W);
        _buyFor(r, attacker, seller, 1); // attacker pays 1e18 PAY, ticket index 0 is credited to the seller
        assertEq(r.tickets(seller), 1);
        _buy(r, honest1, 50); // idx 1..50
        _buy(r, honest2, 49); // idx 51..99
        vm.warp(r.endTime() + 1);

        r.finalize();
        _drawUntilWins(r, seller, 1, W, 3000);
        assertGe(_countIn(r.getWinners(), seller), 1);

        uint256 sellerPayout = 100 ether - (100 ether * FEE_BPS) / 10_000; // 98e18 PAY
        uint256 sellerPrize = r.pendingPrize(seller);
        assertGt(sellerPrize, 0);
        assertEq(r.sellerProceeds(), sellerPayout);

        // The honest winners claim promptly and are paid in full.
        uint256 h1 = r.pendingPrize(honest1);
        uint256 h2 = r.pendingPrize(honest2);
        if (h1 > 0) {
            vm.prank(honest1);
            r.claimPrize();
            assertEq(assetToken.balanceOf(honest1), h1);
        }
        if (h2 > 0) {
            vm.prank(honest2);
            r.claimPrize();
            assertEq(assetToken.balanceOf(honest2), h2);
        }
        assertEq(r.pendingPrize(honest1) + r.pendingPrize(honest2), 0, "honest winners fully paid");

        // The seller, who never asked for the ticket, can still take both exits.
        vm.prank(seller);
        r.withdrawSeller();
        vm.prank(seller);
        r.claimPrize();
        assertEq(paymentToken.balanceOf(seller), sellerPayout, "seller receives its proceeds");
        assertEq(assetToken.balanceOf(seller), sellerPrize, "seller receives its prize too");

        r.withdrawFee();
        assertEq(paymentToken.balanceOf(address(r)), 0, "nothing locked");
        assertEq(assetToken.balanceOf(address(r)), 0, "nothing locked");
    }

    // ============================================================
    // RN-8  (R-23, Info) IRandomnessProvider / setRandomnessProvider were dead code.
    //
    //       WAS: the factory stored a provider but Raffle never read it. A provider that reverted
    //       on every call had zero effect: finalize() used blockhashes and produced exactly the
    //       outcome predicted from public data.
    //
    //       NOW: the provider is on the critical path. A raffle cannot settle without it, and the
    //       seed the draw uses is the one the provider supplied.
    // ============================================================

    function test_Fixed_RandomnessProviderIsUsed() public {
        // (1) A provider that refuses to answer stops settlement dead.
        RevertingProvider bad = new RevertingProvider();
        factory.setRandomnessProvider(address(bad));
        assertEq(address(factory.randomnessProvider()), address(bad));

        uint256 N = 20;
        Raffle rBad = _create(100 ether, 1 ether, N, 4);
        assertEq(address(rBad.randomnessProvider()), address(bad), "the provider is frozen into the raffle");
        _fillWithDistinctHolders(rBad, N);
        vm.warp(rBad.endTime() + 1);

        vm.expectRevert("provider was called");
        rBad.finalize(); // was: settled happily, proving the hook was dead
        assertEq(uint8(rBad.state()), uint8(Raffle.State.Active));
        assertEq(rBad.getWinners().length, 0);

        // A dead provider cannot strand the money either: the abandonment hatch still applies.
        vm.warp(rBad.endTime() + rBad.FINALIZE_GRACE() + 1);
        vm.prank(anyone);
        rBad.failIfAbandoned();
        assertEq(uint8(rBad.state()), uint8(Raffle.State.Failed));
        vm.prank(_holder(0));
        rBad.claimRefund();
        assertEq(paymentToken.balanceOf(_holder(0)), 1 ether);

        // (2) With a live provider, the raffle really does route through it.
        factory.setRandomnessProvider(address(provider));
        Raffle r = _create(100 ether, 1 ether, N, 4);
        _fillWithDistinctHolders(r, N);
        vm.warp(r.endTime() + 1);

        uint256 requestsBefore = provider.requestCount();
        r.finalize();
        assertEq(provider.requestCount(), requestsBefore + 1, "finalize() must request a seed");
        assertEq(r.randomnessRequestId(), provider.lastRequestId(), "the raffle tracks its own request");
        assertEq(provider.requester(provider.lastRequestId()), address(r));
        assertEq(r.randomnessRequestedAt(), block.timestamp);

        // (3) It cannot succeed until the provider answers.
        vm.expectRevert("Raffle: randomness not ready");
        r.drawWinners();
        assertEq(uint8(r.state()), uint8(Raffle.State.RandomnessPending));

        // (4) The seed the raffle used is exactly the one the provider supplied.
        uint256 supplied = uint256(keccak256("supplied-by-the-provider"));
        provider.fulfillLast(supplied);
        r.drawWinners();
        assertEq(r.seed(), supplied, "the draw used the provider's seed");
        assertEq(r.seed(), provider.getRandomness(r.randomnessRequestId()));
        assertEq(uint8(r.state()), uint8(Raffle.State.Succeeded));

        // ...and that seed alone determines the winners.
        uint256[] memory predicted = _replicaDraw(supplied, N, 4);
        address[] memory winners = r.getWinners();
        for (uint256 i = 0; i < winners.length; i++) {
            assertEq(_indexOf(winners[i]), predicted[i], "outcome == f(provider seed)");
        }
    }

    // ============================================================
    // Attacks tried that do NOT work
    // ============================================================

    /// A seller with proceeds but no ticket has nothing in the prize ledger.
    function test_NotExploitable_SellerWithoutTicketCannotClaimPrize() public {
        Raffle r = _create(100 ether, 1 ether, 10, 2);
        _fillWithDistinctHolders(r, 10);
        vm.warp(r.endTime() + 1);
        _settle(r, SEED);

        assertGt(r.sellerProceeds(), 0);
        assertEq(r.pendingPrize(seller), 0);
        vm.prank(seller);
        vm.expectRevert("Raffle: no prize to claim");
        r.claimPrize();
    }

    /// Winners cannot be re-rolled after the draw: the state machine is one-way and a second seed
    /// delivered afterwards changes nothing.
    function test_NotExploitable_CannotRerollAfterFinalize() public {
        Raffle r = _create(100 ether, 1 ether, 10, 2);
        _fillWithDistinctHolders(r, 10);
        vm.warp(r.endTime() + 1);
        _settle(r, SEED);
        address[] memory w1 = r.getWinners();

        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert("Raffle: not active");
        r.finalize();
        vm.expectRevert("Raffle: not pending");
        r.drawWinners();

        provider.fulfillLast(uint256(keccak256("a much better seed")));
        vm.expectRevert("Raffle: not pending");
        r.drawWinners();

        address[] memory w2 = r.getWinners();
        assertEq(w1[0], w2[0]);
        assertEq(w1[1], w2[1]);
        assertEq(r.seed(), SEED);
    }

    /// prevrandao and block.timestamp are not inputs; only the provider's seed is.
    function test_NotExploitable_PrevrandaoAndTimestampNotInputs() public {
        Raffle r = _create(100 ether, 1 ether, 10, 3);
        _fillWithDistinctHolders(r, 10);
        vm.warp(r.endTime() + 1);

        uint256 snap = vm.snapshotState();
        _settle(r, SEED);
        address[] memory baseline = r.getWinners();
        vm.revertToState(snap);

        vm.prevrandao(bytes32(uint256(0xDEADBEEF)));
        vm.warp(block.timestamp + 12345);
        r.finalize();
        vm.prevrandao(bytes32(uint256(0xFEEDFACE)));
        vm.warp(block.timestamp + 999);
        provider.fulfillLast(SEED);
        r.drawWinners();

        address[] memory w = r.getWinners();
        for (uint256 i = 0; i < w.length; i++) {
            assertEq(w[i], baseline[i]);
        }
    }
}
