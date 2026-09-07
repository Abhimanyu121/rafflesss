// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
    REGRESSION SUITE — findings C2-01 to C2-05 from the Codex v2 follow-up
    review (docs/security/FINDINGS.md).

    Naming follows test/audit/Tokens.t.sol:
        test_Fixed_*     the loss / lock / theft is now impossible.
        test_Accepted_*  the behaviour is UNCHANGED and knowingly accepted.
//////////////////////////////////////////////////////////////////////////*/

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Raffle} from "../../src/Raffle.sol";
import {RaffleFactory} from "../../src/RaffleFactory.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockRandomnessProvider} from "../mocks/MockRandomnessProvider.sol";
import {ChainlinkVRFProvider} from "../../src/randomness/ChainlinkVRFProvider.sol";

/*//////////////////////////////////////////////////////////////////////////
                    TOKENS THAT MISBEHAVE ONLY ON THE WAY OUT
//////////////////////////////////////////////////////////////////////////*/

/// @dev `transferFrom` is exact, so this token passes every inbound balance-delta check.
///      `transfer` debits the sender MORE than it credits the receiver: the surplus comes out
///      of whatever else the sender happens to hold. Inside an escrow, that is somebody
///      else's money. The tax is settable so a test can show the debt surviving the outage.
contract SenderTaxOnSendERC20 is ERC20 {
    uint256 public taxBps;
    address public immutable collector;

    constructor(uint256 _taxBps, address _collector) ERC20("SenderTax", "STAX") {
        taxBps = _taxBps;
        collector = _collector;
    }

    function setTaxBps(uint256 v) external {
        taxBps = v;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _transfer(msg.sender, to, value);
        uint256 tax = (value * taxBps) / 10000;
        if (tax > 0) _transfer(msg.sender, collector, tax);
        return true;
    }
}

/// @dev Exact on `transferFrom`, and on `transfer` the sender is debited exactly the amount
///      while the receiver nets less. The escrow stays solvent; only the receiver is short.
contract ReceiverHaircutOnSendERC20 is ERC20 {
    uint256 public immutable haircutBps;

    constructor(uint256 _haircutBps) ERC20("Haircut", "HAIR") {
        haircutBps = _haircutBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        uint256 fee = (value * haircutBps) / 10000;
        _transfer(msg.sender, to, value - fee);
        if (fee > 0) _burn(msg.sender, fee);
        return true;
    }
}

/// @dev `transfer` returns true and moves nothing at all.
contract SilentERC20 is ERC20 {
    constructor() ERC20("Silent", "SLNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return true;
    }
}

/*//////////////////////////////////////////////////////////////////////////
                              VRF COORDINATOR STUB
//////////////////////////////////////////////////////////////////////////*/

/// @dev Enough of VRF v2.5 to drive ChainlinkVRFProvider end to end. The request struct must
///      match the provider's local interface field for field, or the selector will not line up.
contract MockVRFCoordinator {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    uint256 public nextId = 1;
    uint256 public acceptedSubId = 1;

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId) {
        // The real coordinator rejects a request against a subscription that does not list this
        // consumer, or does not exist. One check is enough to reproduce that.
        require(req.subId == acceptedSubId, "coordinator: unknown subscription");
        requestId = nextId++;
    }

    function fulfill(address provider, uint256 requestId, uint256[] memory words) external {
        ChainlinkVRFProvider(provider).rawFulfillRandomWords(requestId, words);
    }
}

contract CodexV2AuditTest is Test {
    RaffleFactory internal factory;
    MockRandomnessProvider internal provider;
    MockERC20 internal asset;
    MockERC20 internal pay;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice"); // seller
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal taxman = makeAddr("taxman");

    uint256 internal constant FEE_BPS = 200;
    uint256 internal constant PRIZE = 900e18;
    uint256 internal constant PRICE = 1e18;
    uint256 internal constant SEED = uint256(keccak256("codex-v2-seed"));

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_700_000_000);
        provider = new MockRandomnessProvider();
        provider.setAutoSeed(SEED);
        factory = new RaffleFactory(owner, feeRecipient, FEE_BPS, address(provider));
        asset = new MockERC20("Wrapped Ether", "WETH");
        pay = new MockERC20("USD Coin", "USDC");
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Alice lists `cap` tickets at PRICE, prize `prizeToken`/PRIZE, `winners` winners.
    function _list(RaffleFactory f, address prizeToken, address paymentToken, uint256 cap, uint16 winners)
        internal
        returns (Raffle r)
    {
        deal(prizeToken, alice, PRIZE, true);
        vm.startPrank(alice);
        ERC20(prizeToken).approve(address(f), PRIZE);
        r = Raffle(
            f.createRaffle(
                address(0),
                prizeToken,
                PRIZE,
                paymentToken,
                PRICE,
                cap,
                PRICE * cap,
                block.timestamp + 1,
                block.timestamp + 7 days,
                winners
            )
        );
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
    }

    function _buy(Raffle r, address token, address buyer, uint256 n) internal {
        uint256 cost = PRICE * n;
        deal(token, buyer, ERC20(token).balanceOf(buyer) + cost, true);
        vm.startPrank(buyer);
        ERC20(token).approve(address(r), cost);
        r.buyTickets(n, address(0));
        vm.stopPrank();
    }

    function _settle(Raffle r) internal {
        if (block.timestamp < r.endTime()) vm.warp(r.endTime());
        r.finalize();
        if (r.state() == Raffle.State.RandomnessPending) r.drawWinners();
    }

    // ========================================================================
    // C2-01 — a token that misbehaves only on the way out
    // ========================================================================

    /// C2-01: `transferFrom` is exact so the token clears every inbound check, but `transfer`
    /// debits the escrow more than it pays out. Before the fix the first claimant was paid out
    /// of the second claimant's money and the second one was left permanently short. The payout
    /// guard cannot conjure the missing tokens, but it refuses to settle a debt at somebody
    /// else's expense, and it leaves both ledger entries standing — so when the token's tax is
    /// lifted, everyone is still made whole. That is the difference between a stalled refund
    /// and a stolen one.
    function test_Fixed_C2_01_OverDebitingTransferCannotBePaidFromAnotherClaimant() public {
        SenderTaxOnSendERC20 tax = new SenderTaxOnSendERC20(1000, taxman); // 10% on the way out
        Raffle r = _list(factory, address(asset), address(tax), 10, 3);

        _buy(r, address(tax), bob, 4);
        _buy(r, address(tax), carol, 3);

        // 7 of 10 tickets sold, so the raffle fails and both buyers are owed a refund.
        _settle(r);
        assertTrue(r.hasFailed(), "raffle failed");
        assertEq(tax.balanceOf(address(r)), 7e18, "escrow holds exactly what was paid in");

        // Bob's 4e18 refund would debit 4.4e18 — the extra 0.4e18 is Carol's.
        vm.prank(bob);
        vm.expectRevert(bytes("Raffle: unsupported token transfer"));
        r.claimRefund();

        vm.prank(carol);
        vm.expectRevert(bytes("Raffle: unsupported token transfer"));
        r.claimRefund();

        // Nothing moved and nothing was written off.
        assertEq(tax.balanceOf(address(r)), 7e18, "escrow untouched");
        assertEq(tax.balanceOf(taxman), 0, "no tax skimmed");
        assertEq(r.tickets(bob), 4, "bob's claim survives");
        assertEq(r.tickets(carol), 3, "carol's claim survives");
        assertFalse(r.refundClaimed(bob));
        assertFalse(r.refundClaimed(carol));

        // Because the debt was never marked settled, recovery is still possible.
        tax.setTaxBps(0);
        vm.prank(bob);
        r.claimRefund();
        vm.prank(carol);
        r.claimRefund();
        assertEq(tax.balanceOf(bob), 4e18, "bob made whole");
        assertEq(tax.balanceOf(carol), 3e18, "carol made whole");
        assertEq(tax.balanceOf(address(r)), 0, "escrow emptied exactly");
    }

    /// C2-01: the same guard on the asset side. A prize token that over-debits would let the
    /// first winner eat into the second winner's share.
    function test_Fixed_C2_01_OverDebitingPrizeTokenCannotShortTheOtherWinners() public {
        SenderTaxOnSendERC20 tax = new SenderTaxOnSendERC20(1000, taxman);
        Raffle r = _list(factory, address(tax), address(pay), 10, 3);

        _buy(r, address(pay), bob, 6);
        _buy(r, address(pay), carol, 4);
        _settle(r);
        assertTrue(r.succeeded(), "raffle succeeded");

        address winner = r.getWinners()[0];
        uint256 owed = r.pendingPrize(winner);
        assertGt(owed, 0);

        vm.prank(winner);
        vm.expectRevert(bytes("Raffle: unsupported token transfer"));
        r.claimPrize();

        assertEq(r.pendingPrize(winner), owed, "prize still owed");
        assertFalse(r.prizeClaimed(winner));
        assertEq(tax.balanceOf(address(r)), PRIZE, "prize pool intact");
    }

    /// C2-01: a token whose `transfer` returns true and moves nothing used to zero the ledger
    /// entry and emit a payout event for money that never left. The debt is now preserved.
    function test_Fixed_C2_01_SilentTransferDoesNotSettleTheDebt() public {
        SilentERC20 silent = new SilentERC20();
        Raffle r = _list(factory, address(asset), address(silent), 10, 3);

        _buy(r, address(silent), bob, 5);
        _settle(r);
        assertTrue(r.hasFailed());

        vm.prank(bob);
        vm.expectRevert(bytes("Raffle: unsupported token transfer"));
        r.claimRefund();

        assertEq(r.tickets(bob), 5, "refund still owed");
        assertEq(r.getTickets(bob), 5, "view agrees with the ledger");
        assertFalse(r.refundClaimed(bob));
        assertEq(silent.balanceOf(bob), 0);
        assertEq(silent.balanceOf(address(r)), 5e18, "money never left");
    }

    /// C2-01, accepted residual: a token that debits the escrow exactly and simply delivers
    /// less to the receiver is NOT blocked. The escrow stays solvent and no claimant is paid
    /// from another's share, so the guard has nothing to object to — the receiver just nets
    /// less than the ledger promised. Closing this needs token curation, not a contract check
    /// (see docs/security/OPEN-QUESTIONS.md, C2-01 allowlist).
    function test_Accepted_C2_01_ReceiverHaircutIsNotBlocked() public {
        ReceiverHaircutOnSendERC20 hair = new ReceiverHaircutOnSendERC20(100); // 1%
        Raffle r = _list(factory, address(asset), address(hair), 10, 3);

        _buy(r, address(hair), bob, 5);
        _settle(r);
        assertTrue(r.hasFailed());

        vm.prank(bob);
        r.claimRefund();

        assertEq(hair.balanceOf(bob), 4.95e18, "receiver bears the token's own fee");
        assertEq(hair.balanceOf(address(r)), 0, "escrow debited exactly the liability");
        assertTrue(r.refundClaimed(bob));
    }

    // ========================================================================
    // C2-02 — an unwired provider costs liveness, never funds
    // ========================================================================

    /// C2-02: until the provider is bound to its factory, `finalize()` reverts and a sold-out
    /// raffle cannot settle. This pins the blast radius: the abandonment hatch still releases
    /// every buyer, so a missed deployment step delays people, it does not trap them.
    /// `script/SetupProvider.s.sol` is what stops a deployment shipping in this state.
    function test_Fixed_C2_02_UnwiredProviderStallsSettlementButRefundsStillWork() public {
        MockVRFCoordinator coordinator = new MockVRFCoordinator();
        ChainlinkVRFProvider vrf =
            new ChainlinkVRFProvider(owner, address(coordinator), bytes32("gaslane"), 1, 3, 200000, false);
        RaffleFactory f = new RaffleFactory(owner, feeRecipient, FEE_BPS, address(vrf));

        Raffle r = _list(f, address(asset), address(pay), 10, 3);
        _buy(r, address(pay), bob, 10); // sold out: settlement needs randomness

        vm.warp(r.endTime());
        vm.expectRevert(ChainlinkVRFProvider.FactoryNotSet.selector);
        r.finalize();

        vm.warp(r.endTime() + r.FINALIZE_GRACE() + 1);
        r.failIfAbandoned();
        assertTrue(r.hasFailed(), "abandonment hatch releases the raffle");

        vm.prank(bob);
        r.claimRefund();
        assertEq(pay.balanceOf(bob), 10e18, "buyer made whole");

        vm.prank(alice);
        r.withdrawAsset();
        assertEq(asset.balanceOf(alice), PRIZE, "seller made whole");
    }

    // ========================================================================
    // C2-03 — the provider's factory binding is set once
    // ========================================================================

    /// C2-03: repointing a live provider at a new factory made every existing raffle unknown to
    /// it, so their `finalize()` reverted and sold-out raffles could only be released by
    /// refunding everyone. The binding is now write-once; a second factory needs its own
    /// provider. Note this removes the owner's ability to strand raffles by REBINDING only —
    /// `setRequestConfig` remains a liveness lever, recorded as a trust assumption in
    /// docs/security/DECISIONS.md.
    function test_Fixed_C2_03_ProviderFactoryBindingIsWriteOnce() public {
        MockVRFCoordinator coordinator = new MockVRFCoordinator();
        ChainlinkVRFProvider vrf =
            new ChainlinkVRFProvider(owner, address(coordinator), bytes32("gaslane"), 1, 3, 200000, false);
        RaffleFactory f = new RaffleFactory(owner, feeRecipient, FEE_BPS, address(vrf));

        vm.prank(owner);
        vrf.setFactory(address(f));

        // Not to a different factory...
        RaffleFactory rival = new RaffleFactory(owner, feeRecipient, FEE_BPS, address(vrf));
        vm.prank(owner);
        vm.expectRevert(ChainlinkVRFProvider.FactoryAlreadySet.selector);
        vrf.setFactory(address(rival));

        // ...and not even to the same one again.
        vm.prank(owner);
        vm.expectRevert(ChainlinkVRFProvider.FactoryAlreadySet.selector);
        vrf.setFactory(address(f));

        assertEq(address(vrf.factory()), address(f), "binding unchanged");

        // A raffle created under the original factory can still reach the coordinator.
        Raffle r = _list(f, address(asset), address(pay), 10, 3);
        _buy(r, address(pay), bob, 10);
        vm.warp(r.endTime());
        r.finalize();
        assertEq(uint8(r.state()), uint8(Raffle.State.RandomnessPending), "request went through");
    }

    /// C2-03, the residual: freezing the factory binding does NOT make the provider owner
    /// harmless. `setRequestConfig` points the provider at a different gas lane or subscription,
    /// and a subscription the coordinator rejects stalls every settlement. This is asserted
    /// rather than merely documented, because a trust assumption nobody has exercised is a guess.
    /// The bound on the damage is what makes it acceptable: raffles release and refund, so the
    /// owner can stall people, never take from them (B-8).
    ///
    /// This mock models the subscription case, which the real coordinator does reject. It does
    /// NOT reject an unknown gas lane — that request is accepted and silently never answered.
    /// `test/fork/VRFBaseSepolia.t.sol` covers that half against real bytecode.
    function test_Accepted_C2_03_ProviderOwnerCanStallSettlementViaRequestConfig() public {
        MockVRFCoordinator coordinator = new MockVRFCoordinator();
        ChainlinkVRFProvider vrf =
            new ChainlinkVRFProvider(owner, address(coordinator), bytes32("gaslane"), 1, 3, 200000, false);
        RaffleFactory f = new RaffleFactory(owner, feeRecipient, FEE_BPS, address(vrf));
        vm.prank(owner);
        vrf.setFactory(address(f));

        Raffle r = _list(f, address(asset), address(pay), 10, 3);
        _buy(r, address(pay), bob, 10);

        // Only the owner can touch the request config...
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vrf.setRequestConfig(bytes32("other"), 99, 3, 200000, false);

        // ...and pointing it at a subscription the coordinator does not know stalls settlement.
        vm.prank(owner);
        vrf.setRequestConfig(bytes32("other"), 99, 3, 200000, false);
        assertEq(vrf.subscriptionId(), 99);
        assertEq(vrf.keyHash(), bytes32("other"));

        vm.warp(r.endTime());
        vm.expectRevert(bytes("coordinator: unknown subscription"));
        r.finalize();

        // Bounded: buyers are not trapped, they are delayed.
        vm.warp(r.endTime() + r.FINALIZE_GRACE() + 1);
        r.failIfAbandoned();
        vm.prank(bob);
        r.claimRefund();
        assertEq(pay.balanceOf(bob), 10e18, "buyer made whole");

        // And correcting the config restores settlement for later raffles.
        vm.prank(owner);
        vrf.setRequestConfig(bytes32("gaslane"), 1, 3, 200000, false);
        Raffle r2 = _list(f, address(asset), address(pay), 10, 3);
        _buy(r2, address(pay), carol, 10);
        vm.warp(r2.endTime());
        r2.finalize();
        assertEq(uint8(r2.state()), uint8(Raffle.State.RandomnessPending), "settlement recovered");
    }

    /// The provider refuses to deploy without an owner or a coordinator: neither can be set
    /// afterwards, so a mistake here is permanent.
    function test_Fixed_ProviderRejectsZeroAddressesAtDeployment() public {
        vm.expectRevert(ChainlinkVRFProvider.InvalidAddress.selector);
        new ChainlinkVRFProvider(owner, address(0), bytes32("gaslane"), 1, 3, 200000, false);

        // A zero owner is caught by OpenZeppelin first.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ChainlinkVRFProvider(address(0), makeAddr("coord"), bytes32("gaslane"), 1, 3, 200000, false);
    }

    // ========================================================================
    // C2-04 — both tokens must be contracts
    // ========================================================================

    /// C2-04: an EOA payment token used to produce a listed raffle that could never sell a
    /// ticket. Creation now refuses, before anything is escrowed.
    function test_Fixed_C2_04_TokenAddressesMustHaveCode() public {
        address eoa = makeAddr("notAToken");
        deal(address(asset), alice, PRIZE, true);

        vm.startPrank(alice);
        asset.approve(address(factory), PRIZE);

        vm.expectRevert(bytes("Raffle: asset token not a contract"));
        factory.createRaffle(
            address(0),
            eoa,
            PRIZE,
            address(pay),
            PRICE,
            10,
            PRICE * 10,
            block.timestamp + 1,
            block.timestamp + 7 days,
            3
        );

        vm.expectRevert(bytes("Raffle: payment token not a contract"));
        factory.createRaffle(
            address(0),
            address(asset),
            PRIZE,
            eoa,
            PRICE,
            10,
            PRICE * 10,
            block.timestamp + 1,
            block.timestamp + 7 days,
            3
        );
        vm.stopPrank();

        assertEq(factory.getRaffles(0, 100).length, 0, "nothing listed");
        assertEq(asset.balanceOf(alice), PRIZE, "nothing escrowed");
    }

    // ========================================================================
    // C2-05 — the provider only records fulfilments it asked for
    // ========================================================================

    /// C2-05: the coordinator is trusted, so this is about keeping the request history
    /// truthful rather than about theft. An id this provider never issued is now rejected
    /// instead of stored and emitted, and an empty word array reverts with a named error
    /// rather than an array-bounds panic.
    function test_Fixed_C2_05_UnknownAndEmptyFulfilmentsRejected() public {
        MockVRFCoordinator coordinator = new MockVRFCoordinator();
        ChainlinkVRFProvider vrf =
            new ChainlinkVRFProvider(owner, address(coordinator), bytes32("gaslane"), 1, 3, 200000, false);
        RaffleFactory f = new RaffleFactory(owner, feeRecipient, FEE_BPS, address(vrf));
        vm.prank(owner);
        vrf.setFactory(address(f));

        uint256[] memory word = new uint256[](1);
        word[0] = SEED;

        // An id this provider never requested, arriving from the real coordinator.
        vm.expectRevert(ChainlinkVRFProvider.UnknownRequest.selector);
        coordinator.fulfill(address(vrf), 4242, word);
        assertEq(vrf.getRandomness(bytes32(uint256(4242))), 0, "nothing recorded");

        // A real request, so the id is known from here on.
        Raffle r = _list(f, address(asset), address(pay), 10, 3);
        _buy(r, address(pay), bob, 10);
        vm.warp(r.endTime());
        r.finalize();
        uint256 id = uint256(r.randomnessRequestId());
        assertEq(vrf.requestedBy(bytes32(id)), address(r), "request attributed to the raffle");

        // Known id, but no words.
        uint256[] memory empty = new uint256[](0);
        vm.expectRevert(ChainlinkVRFProvider.EmptyRandomWords.selector);
        coordinator.fulfill(address(vrf), id, empty);

        // Still nobody but the coordinator may answer.
        vm.prank(bob);
        vm.expectRevert(ChainlinkVRFProvider.OnlyCoordinator.selector);
        vrf.rawFulfillRandomWords(id, word);

        // The honest path still works end to end.
        coordinator.fulfill(address(vrf), id, word);
        assertEq(vrf.getRandomness(bytes32(id)), SEED);
        r.drawWinners();
        assertTrue(r.succeeded(), "raffle settled on real VRF plumbing");
        assertEq(r.getWinners().length, 3);
    }

    /// C2-05: a fulfilled word of zero is stored as one, because zero is the "not ready"
    /// sentinel. Left unguarded, a zero answer would leave the raffle waiting for a seed that
    /// had already arrived, until the timeout refunded everybody.
    function test_Fixed_C2_05_ZeroWordIsStoredAsTheSentinelPlusOne() public {
        MockVRFCoordinator coordinator = new MockVRFCoordinator();
        ChainlinkVRFProvider vrf =
            new ChainlinkVRFProvider(owner, address(coordinator), bytes32("gaslane"), 1, 3, 200000, false);
        RaffleFactory f = new RaffleFactory(owner, feeRecipient, FEE_BPS, address(vrf));
        vm.prank(owner);
        vrf.setFactory(address(f));

        Raffle r = _list(f, address(asset), address(pay), 10, 3);
        _buy(r, address(pay), bob, 10);
        vm.warp(r.endTime());
        r.finalize();

        uint256 id = uint256(r.randomnessRequestId());
        uint256[] memory zero = new uint256[](1);
        coordinator.fulfill(address(vrf), id, zero);

        assertEq(vrf.getRandomness(bytes32(id)), 1, "zero stored as one");
        r.drawWinners();
        assertTrue(r.succeeded());
    }
}
