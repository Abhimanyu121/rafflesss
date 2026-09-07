// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Factory / initialization / clone / admin / approval-abuse REGRESSION suite
/// @notice These started life as adversarial proofs-of-concept against the pre-rewrite
///         contracts (see docs/security/FINDINGS.md). Every attack is still performed
///         step for step, with the original commentary intact; only the final assertions
///         were inverted once the contracts were fixed.
///
///         `test_Fixed_*`          the attack is now blocked. The test proves the specific
///                                 revert AND that the victim's position is untouched.
///         `test_NotExploitable_*` attack attempted before and after the rewrite, never worked.
///         `test_Fixed_OutOfScope_*` severe Raffle.sol bugs found while probing the factory
///                                 surface; kept here because they broke factory-level promises.

import {Test} from "forge-std/Test.sol";
import {RaffleFactory} from "../../src/RaffleFactory.sol";
import {Raffle} from "../../src/Raffle.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IRandomnessProvider} from "../../src/interfaces/IRandomnessProvider.sol";
import {ChainlinkVRFProvider} from "../../src/randomness/ChainlinkVRFProvider.sol";
import {MockRandomnessProvider} from "../mocks/MockRandomnessProvider.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// ============================================================================
// Helper contracts (attacker tooling / token models)
// ============================================================================

/// @dev USDC-style token: issuer can blacklist addresses; transfers to/from them revert.
contract BlacklistERC20 is ERC20 {
    mapping(address => bool) public blacklisted;
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlacklist(address who, bool v) external {
        blacklisted[who] = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[from] && !blacklisted[to], "USDC: blacklisted");
        super._update(from, to, value);
    }
}

/// @dev Attacker-controlled "factory". Before the rewrite `initialize` stored
///      `factory = msg.sender`, so driving it through this contract handed the attacker the
///      fee parameters. `initialize` is now `onlyFactory` against an IMMUTABLE address, so
///      this contract can no longer initialize anything.
contract FakeFactory {
    uint256 public feeBps;
    address public feeRecipient;

    constructor(uint256 _feeBps, address _feeRecipient) {
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
    }

    /// @dev Calls initialize() so that the target would treat this contract as its factory.
    function hijack(Raffle target, Raffle.RaffleParams calldata p) external {
        target.initialize(p);
    }
}

/// @dev ERC20 whose transferFrom re-enters the factory / raffle (models ERC777 tokensToSend hooks
///      or an outright malicious asset token).
contract ReenteringAssetToken is ERC20 {
    RaffleFactory public factory;
    address public paymentToken;
    uint8 public mode; // 0 = none, 1 = nested createRaffle, 2 = withdrawAsset on the raffle being funded
    address public nestedRaffle;
    bool public reentryReverted;
    string public reentryReason;

    constructor() ERC20("Hooked", "HOOK") {
        _mint(address(this), 1_000_000e18);
    }

    function arm(RaffleFactory f, address p, uint8 m) external {
        factory = f;
        paymentToken = p;
        mode = m;
    }

    function approveFactory(uint256 amount) external {
        _approve(address(this), address(factory), amount);
    }

    function createAsSeller(uint256 amount, uint256 start, uint256 end) external returns (address) {
        return factory.createRaffle(address(0), address(this), amount, paymentToken, 1e18, 10, 10e18, start, end, 1);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        uint8 m = mode;
        mode = 0;
        if (m == 1) {
            _approve(address(this), address(factory), allowance(address(this), address(factory)) + 1);
            nestedRaffle = factory.createRaffle(
                address(this), address(this), 1, paymentToken, 1, 1, 1, block.timestamp, block.timestamp + 10 minutes, 1
            );
        } else if (m == 2) {
            // Seller (this contract) tries to pull the prize back before it has even arrived.
            try Raffle(to).withdrawAsset() {}
            catch Error(string memory reason) {
                reentryReverted = true;
                reentryReason = reason;
            }
        }
        return super.transferFrom(from, to, value);
    }
}

/// @dev Faithful model of the deterministic CREATE2 deployer proxy at 0x4e59b4...956C that
///      `forge script` routes `new X{salt: s}()` through: calldata = salt ++ initcode.
contract Create2ProxyModel {
    fallback() external payable {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let addr := create2(callvalue(), 32, sub(calldatasize(), 32), mload(0))
            if iszero(addr) { revert(0, 0) }
            mstore(0, addr)
            return(12, 20)
        }
    }
}

contract SpyRandomnessProvider is IRandomnessProvider {
    uint256 public calls;

    function requestRandomness(address, bytes32) external returns (bytes32) {
        calls++;
        return bytes32(uint256(1));
    }

    function getRandomness(bytes32) external pure returns (uint256) {
        return 0;
    }
}

// ============================================================================
// Test suite
// ============================================================================

contract FactoryAuditTest is Test {
    RaffleFactory internal factory;
    MockRandomnessProvider internal provider;
    MockERC20 internal asset; // "WETH"-like prize token
    MockERC20 internal pay; // "USDC"-like payment token

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice"); // honest seller / victim
    address internal bob = makeAddr("bob"); // attacker
    address internal carol = makeAddr("carol"); // honest buyer
    address internal dave = makeAddr("dave"); // honest buyer

    uint256 internal constant FEE_BPS = 200;
    uint256 internal constant PRIZE = 1000e18;
    uint256 internal constant SEED = uint256(keccak256("factory-audit-seed"));
    address internal constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_700_000_000);
        provider = new MockRandomnessProvider();
        provider.setAutoSeed(SEED);
        factory = new RaffleFactory(owner, feeRecipient, FEE_BPS, address(provider));
        asset = new MockERC20("Wrapped Ether", "WETH");
        pay = new MockERC20("USD Coin", "USDC");
        asset.mint(alice, PRIZE);
    }

    // ------------------------------------------------------------------ helpers
    function _buy(Raffle r, MockERC20 tok, address buyer, uint256 n) internal {
        tok.mint(buyer, r.ticketPrice() * n);
        vm.startPrank(buyer);
        tok.approve(address(r), r.ticketPrice() * n);
        r.buyTickets(n, address(0));
        vm.stopPrank();
    }

    /// @dev Settlement is now two transactions (P-5): finalize decides the outcome, drawWinners
    ///      picks the winners from a seed that did not exist when finalize was sent.
    function _settle(Raffle r) internal {
        if (block.timestamp < r.endTime()) vm.warp(r.endTime());
        r.finalize();
        if (r.state() == Raffle.State.RandomnessPending) r.drawWinners();
    }

    /// @dev Honest raffle: Alice sells PRIZE asset, `ticketCap` tickets x 1e18 pay.
    function _aliceRaffle(address paymentToken, uint256 ticketCap, uint16 winners) internal returns (Raffle r) {
        vm.startPrank(alice);
        asset.approve(address(factory), PRIZE);
        r = Raffle(
            factory.createRaffle(
                address(0),
                address(asset),
                PRIZE,
                paymentToken,
                1e18,
                ticketCap,
                1e18 * ticketCap,
                block.timestamp + 1,
                block.timestamp + 7 days,
                winners
            )
        );
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
    }

    /// @dev The FA-1 attack, verbatim: Bob names `victim` as the seller so the factory pulls the
    ///      victim's approved asset into a raffle whose economics Bob chose. It must now revert
    ///      before anything is touched.
    function _bobDrainAttempt(address victim, MockERC20 tok, uint256 amount) internal {
        vm.startPrank(bob);
        MockERC20 junk = new MockERC20("Junk", "JUNK"); // Bob mints 1M JUNK to himself
        vm.expectRevert(RaffleFactory.SellerMustBeCaller.selector);
        factory.createRaffle(
            victim, // <-- arbitrary seller, never consented
            address(tok),
            amount, // <-- victim's approved asset
            address(junk), // <-- worthless payment token Bob controls
            1,
            1,
            1, // ticketPrice=1 wei, ticketCap=1, sellerMin=1
            block.timestamp,
            block.timestamp + 10 minutes,
            1
        );
        vm.stopPrank();
    }

    function _unique(address[] memory a) internal pure returns (address[] memory u) {
        address[] memory tmp = new address[](a.length);
        uint256 n;
        for (uint256 i = 0; i < a.length; i++) {
            bool seen;
            for (uint256 j = 0; j < n; j++) {
                if (tmp[j] == a[i]) seen = true;
                break;
            }
            if (!seen) tmp[n++] = a[i];
        }
        u = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            u[i] = tmp[i];
        }
    }

    function _params(address seller_, uint256 assetAmount_, uint16 winners_)
        internal
        view
        returns (Raffle.RaffleParams memory)
    {
        return Raffle.RaffleParams({
            seller: seller_,
            assetToken: address(asset),
            assetAmount: assetAmount_,
            paymentToken: address(pay),
            ticketPrice: 100e18,
            ticketCap: 10,
            sellerMin: 1000e18,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 days,
            winnersCount: winners_,
            feeBps: 0,
            feeRecipient: seller_,
            randomnessProvider: address(provider)
        });
    }

    // ========================================================================
    // 1. APPROVAL ABUSE via createRaffle(raffleSeller = victim)
    // ========================================================================

    /// FA-1 / R-03: an ERC20 allowance to the factory used to be authorisation for ANYONE to
    /// spend it on terms they chose. `raffleSeller` must now be the caller (or zero).
    function test_Fixed_ApprovalAbuse_DrainVictimApprovalViaCustomSeller() public {
        // Alice approved the factory once with max allowance (common wallet UX) intending to
        // create her own raffle later. She has NOT called createRaffle.
        vm.prank(alice);
        asset.approve(address(factory), type(uint256).max);

        uint256 bobBefore = asset.balanceOf(bob);
        _bobDrainAttempt(alice, asset, PRIZE);

        // Nothing moved: the victim keeps both the tokens and the allowance, and no raffle
        // was ever registered in her name.
        assertEq(asset.balanceOf(alice), PRIZE, "victim's balance untouched");
        assertEq(asset.balanceOf(bob), bobBefore, "attacker gained nothing");
        assertEq(asset.allowance(alice, address(factory)), type(uint256).max, "allowance untouched");
        assertEq(factory.getRaffleCount(), 0, "no raffle created in the victim's name");

        // Repeating it (the old attack worked once per top-up) changes nothing.
        asset.mint(alice, 500e18);
        _bobDrainAttempt(alice, asset, 500e18);
        assertEq(asset.balanceOf(alice), PRIZE + 500e18, "still untouched");
        assertEq(asset.balanceOf(bob), bobBefore);

        // Bob can still create a raffle - but only ever with his own tokens.
        asset.mint(bob, 10e18);
        vm.startPrank(bob);
        asset.approve(address(factory), 10e18);
        Raffle own = Raffle(
            factory.createRaffle(
                address(0),
                address(asset),
                10e18,
                address(pay),
                1e18,
                10,
                10e18,
                block.timestamp,
                block.timestamp + 1 days,
                1
            )
        );
        vm.stopPrank();
        assertEq(own.seller(), bob, "the prize always comes from the caller");
        assertEq(asset.balanceOf(alice), PRIZE + 500e18);
    }

    /// FA-1 (variant): exact-amount approve + createRaffle in two txs used to be front-runnable.
    function test_Fixed_ApprovalAbuse_FrontRunPendingCreateRaffle() public {
        // tx1 (mined): Alice approves exactly the prize amount for her upcoming raffle
        vm.prank(alice);
        asset.approve(address(factory), PRIZE);

        // Bob sees the approval (or Alice's pending createRaffle) in the mempool and lands first
        _bobDrainAttempt(alice, asset, PRIZE);
        assertEq(asset.balanceOf(bob), 0, "front-run produced nothing");
        assertEq(asset.balanceOf(alice), PRIZE, "victim's balance untouched");
        assertEq(asset.allowance(alice, address(factory)), PRIZE, "allowance untouched");

        // tx2: Alice's own createRaffle now goes through exactly as she intended
        vm.prank(alice);
        Raffle r = Raffle(
            factory.createRaffle(
                address(0),
                address(asset),
                PRIZE,
                address(pay),
                1e18,
                100,
                100e18,
                block.timestamp + 1,
                block.timestamp + 7 days,
                3
            )
        );
        assertEq(r.seller(), alice);
        assertEq(r.paymentToken(), address(pay), "her parameters, not Bob's");
        assertEq(asset.balanceOf(address(r)), PRIZE);
    }

    /// FA-1 (variant): the documented "relayer creates on behalf of seller" flow gave the relayer
    /// full control over the economics because the seller signed nothing. The feature is gone:
    /// a relayer cannot name someone else as the seller at all.
    function test_Fixed_ApprovalAbuse_RelayerSubstitutesParameters() public {
        vm.prank(alice);
        asset.approve(address(factory), PRIZE);
        // Alice asked relayer Bob for: 100 tickets @ 100 USDC. Bob submits 1 ticket @ 1 wei JUNK.
        _bobDrainAttempt(alice, asset, PRIZE);
        assertEq(asset.balanceOf(bob), 0, "no substituted raffle exists");
        assertEq(asset.balanceOf(alice), PRIZE, "victim's balance untouched");
        assertEq(asset.allowance(alice, address(factory)), PRIZE, "allowance untouched");

        // Even the honest-looking version - Bob naming Alice with her real parameters - is refused.
        vm.prank(bob);
        vm.expectRevert(RaffleFactory.SellerMustBeCaller.selector);
        factory.createRaffle(
            alice,
            address(asset),
            PRIZE,
            address(pay),
            1e18,
            100,
            100e18,
            block.timestamp + 1,
            block.timestamp + 7 days,
            3
        );
        assertEq(factory.getRaffleCount(), 0);
    }

    // ========================================================================
    // 2. INITIALIZATION / CLONES / IMPLEMENTATION
    // ========================================================================

    /// Clones are initialized in the same tx they are created: no front-run window.
    function test_NotExploitable_CloneInitializeFrontRun() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        assertEq(predicted.code.length, 0);

        // Bob tries to pre-initialize the predicted clone address. Nothing happens (no code yet).
        vm.prank(bob);
        (bool ok,) = predicted.call(abi.encodeCall(Raffle.initialize, (_params(bob, 1000e18, 1))));
        ok; // call to a codeless address "succeeds" but stores nothing

        Raffle r = _aliceRaffle(address(pay), 100, 3);
        assertEq(address(r), predicted, "address was predictable");
        assertEq(r.FACTORY(), address(factory));
        assertEq(r.seller(), alice);
        assertEq(uint256(r.state()), uint256(Raffle.State.Active));

        // Re-initialization after creation is blocked by OpenZeppelin's Initializable.
        vm.prank(bob);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        r.initialize(_params(bob, 1000e18, 1));
        assertEq(r.seller(), alice, "terms unchanged");
    }

    /// FA-2 / R-10: RAFFLE_IMPLEMENTATION used to be left uninitialized, so anyone could
    /// initialize it through a fake factory and run a raffle at the protocol's own published
    /// implementation address, with a prize that was never deposited.
    /// The constructor now calls _disableInitializers().
    function test_Fixed_ImplementationHijack_PhantomPrizeAtOfficialAddress() public {
        Raffle impl = Raffle(factory.RAFFLE_IMPLEMENTATION());
        assertEq(impl.FACTORY(), address(factory), "implementation is bound to the real factory");
        assertEq(uint256(impl.state()), uint256(Raffle.State.Uninitialized));

        vm.startPrank(bob);
        FakeFactory fake = new FakeFactory(0, bob);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fake.hijack(impl, _params(bob, PRIZE, 1));
        // ...and directly, as an EOA, for the same reason.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(_params(bob, PRIZE, 1));
        vm.stopPrank();

        // The published implementation address is permanently inert.
        assertEq(uint256(impl.state()), uint256(Raffle.State.Uninitialized), "never initialized");
        assertEq(impl.seller(), address(0));
        assertEq(impl.assetAmount(), 0, "no phantom prize advertised");
        assertFalse(factory.isRaffle(address(impl)), "and it is not in the registry");

        // The victim cannot even be lured into paying: there is nothing to buy.
        pay.mint(carol, 1000e18);
        vm.startPrank(carol);
        pay.approve(address(impl), 1000e18);
        vm.expectRevert("Raffle: not active");
        impl.buyTickets(10, address(0));
        vm.stopPrank();
        assertEq(pay.balanceOf(carol), 1000e18, "victim keeps their money");
    }

    /// FA-2 (variant): anyone can still CLONE the official implementation, but a clone made
    /// outside the factory can never be initialized, because initialize() requires
    /// msg.sender == FACTORY, and FACTORY is immutable bytecode shared by every clone.
    function test_Fixed_RogueCloneOfOfficialImplementation() public {
        vm.startPrank(bob);
        address rogue = Clones.clone(factory.RAFFLE_IMPLEMENTATION());
        FakeFactory fake = new FakeFactory(10000, bob); // 100% "fee" to attacker

        // Through an attacker "factory": msg.sender is the fake, not the real FACTORY.
        vm.expectRevert("Raffle: only factory");
        fake.hijack(Raffle(rogue), _params(bob, PRIZE, 1));

        // Directly, as an EOA: same.
        vm.expectRevert("Raffle: only factory");
        Raffle(rogue).initialize(_params(bob, PRIZE, 1));
        vm.stopPrank();

        Raffle r = Raffle(rogue);
        assertEq(r.FACTORY(), address(factory), "clones inherit the real factory address");
        assertEq(uint256(r.state()), uint256(Raffle.State.Uninitialized));
        assertFalse(factory.isRaffle(rogue), "and isRaffle stays false for it");

        // Nothing can be sold from it, so there is no victim to acquire.
        pay.mint(carol, 1000e18);
        vm.startPrank(carol);
        pay.approve(rogue, 1000e18);
        vm.expectRevert("Raffle: not active");
        r.buyTickets(10, address(0));
        vm.stopPrank();
        assertEq(pay.balanceOf(carol), 1000e18);
    }

    // ========================================================================
    // 3. FEE MANIPULATION
    // ========================================================================

    /// FA-3 / R-06: the fee used to be read at finalize time from live factory storage, and the
    /// setter accepted 10000 bps. Terms are now copied into the raffle at creation (P-3) and the
    /// factory itself is capped at MAX_FEE_BPS.
    function test_Fixed_OwnerRugsInFlightRaffleWith100PercentFee() public {
        Raffle r = _aliceRaffle(address(pay), 100, 3);
        // Buyers commit under the advertised 2% fee
        _buy(r, pay, carol, 60);
        _buy(r, pay, dave, 40);
        assertEq(r.totalFunds(), 100e18);
        assertEq(r.feeBps(), FEE_BPS, "the raffle froze the fee at creation");

        // After the last sale, owner tries to flip the fee and recipient.
        address ownerWallet = makeAddr("ownerWallet");
        uint256 cap = factory.MAX_FEE_BPS();
        vm.startPrank(owner);
        vm.expectRevert(RaffleFactory.InvalidFeeBps.selector);
        factory.setFeeBps(10000); // the old 100% rug
        vm.expectRevert(RaffleFactory.InvalidFeeBps.selector);
        factory.setFeeBps(cap + 1); // one bp over the cap
        factory.setFeeBps(cap); // the very most the owner can ever set
        factory.setFeeRecipient(ownerWallet);
        vm.stopPrank();
        assertEq(factory.feeBps(), 1000);

        _settle(r);

        // The in-flight raffle is unaffected by both changes.
        assertEq(r.feeBps(), FEE_BPS, "fee frozen");
        assertEq(r.feeRecipient(), feeRecipient, "recipient frozen");
        assertEq(r.protocolFeeOwed(), 2e18, "still 2%");
        assertEq(r.sellerProceeds(), 98e18, "seller keeps 98%");

        r.withdrawFee();
        assertEq(pay.balanceOf(ownerWallet), 0, "the owner's new wallet gets nothing");
        assertEq(pay.balanceOf(feeRecipient), 2e18);

        vm.prank(alice);
        r.withdrawSeller();
        assertEq(pay.balanceOf(alice), 98e18, "seller was NOT rugged");
        assertEq(pay.balanceOf(address(r)), 0);
    }

    function test_NotExploitable_FeeBpsAboveCapRejected() public {
        vm.startPrank(owner);
        vm.expectRevert(RaffleFactory.InvalidFeeBps.selector);
        factory.setFeeBps(10001);
        vm.expectRevert(RaffleFactory.InvalidFeeBps.selector);
        factory.setFeeBps(1001);
        factory.setFeeBps(1000); // MAX_FEE_BPS exactly
        vm.stopPrank();
        assertEq(factory.MAX_FEE_BPS(), 1000);

        vm.expectRevert(RaffleFactory.InvalidFeeBps.selector);
        new RaffleFactory(owner, feeRecipient, 10001, address(provider));
        vm.expectRevert(RaffleFactory.InvalidFeeBps.selector);
        new RaffleFactory(owner, feeRecipient, 1001, address(provider));

        // Non-owners cannot move the fee at all (Ownable2Step).
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        factory.setFeeBps(0);
    }

    /// FA-4 / R-08: the fee used to be PUSHED inside finalize(). If the payment token refused the
    /// fee recipient (USDC blacklist, paused token, hook revert), finalize reverted forever and
    /// EVERY exit path - refunds, prizes, the seller's asset - was closed with it.
    /// The fee is now pull-based: a hostile fee recipient can only ever block their own fee.
    function test_Fixed_FeeRecipientBlacklist_AllFundsStuck() public {
        BlacklistERC20 usdc = new BlacklistERC20();
        Raffle r = _aliceRaffle(address(usdc), 100, 3);
        usdc.mint(carol, 100e18);
        vm.startPrank(carol);
        usdc.approve(address(r), 100e18);
        r.buyTickets(100, address(0));
        vm.stopPrank();

        // Token issuer blacklists the protocol's fee wallet (or the owner points feeRecipient at a
        // blacklisted / reverting address). Then the owner key is thrown away, so the old
        // "only the owner can unstick it" rescue is unavailable.
        usdc.setBlacklist(feeRecipient, true);
        vm.prank(owner);
        factory.renounceOwnership();

        // Settlement still completes, in both of its steps.
        vm.warp(r.endTime());
        r.finalize();
        assertEq(uint256(r.state()), uint256(Raffle.State.RandomnessPending));
        r.drawWinners();
        assertTrue(r.succeeded(), "settlement is not hostage to the fee recipient");

        // Winners still get paid (asset token).
        address[] memory w = _unique(r.getWinners());
        for (uint256 i = 0; i < w.length; i++) {
            vm.prank(w[i]);
            r.claimPrize();
        }
        assertEq(asset.balanceOf(carol), PRIZE, "winner claimed in full");
        assertEq(asset.balanceOf(address(r)), 0);

        // The seller still gets paid (payment token).
        vm.prank(alice);
        r.withdrawSeller();
        assertEq(usdc.balanceOf(alice), 98e18, "seller withdrew in full");

        // ONLY withdrawFee() reverts, and only the 2e18 fee is affected.
        vm.expectRevert("USDC: blacklisted");
        r.withdrawFee();
        assertEq(r.protocolFeeOwed(), 2e18, "the fee is still owed, not lost");
        assertEq(usdc.balanceOf(address(r)), 2e18, "nothing but the fee is left in the raffle");

        // And even that is recoverable the moment the token stops refusing the recipient.
        usdc.setBlacklist(feeRecipient, false);
        r.withdrawFee();
        assertEq(usdc.balanceOf(feeRecipient), 2e18);
        assertEq(usdc.balanceOf(address(r)), 0, "fully drained");
    }

    /// The same scenario from the admin side: the recipient is frozen per raffle, so rotating it
    /// on the factory neither rescues nor endangers a live raffle - it only shapes new ones.
    function test_NotExploitable_FeeBlacklist_OwnerRotationOnlyAffectsNewRaffles() public {
        BlacklistERC20 usdc = new BlacklistERC20();
        Raffle r = _aliceRaffle(address(usdc), 100, 3);
        usdc.mint(carol, 100e18);
        vm.startPrank(carol);
        usdc.approve(address(r), 100e18);
        r.buyTickets(100, address(0));
        vm.stopPrank();
        usdc.setBlacklist(feeRecipient, true);

        _settle(r);
        assertTrue(r.succeeded());

        address fresh = makeAddr("fresh");
        vm.prank(owner);
        factory.setFeeRecipient(fresh);
        assertEq(r.feeRecipient(), feeRecipient, "live raffle keeps its frozen recipient");
        vm.expectRevert("USDC: blacklisted");
        r.withdrawFee();

        // A raffle created after the rotation pays the fresh recipient and is unaffected.
        asset.mint(alice, PRIZE);
        Raffle r2 = _aliceRaffle(address(usdc), 100, 3);
        assertEq(r2.feeRecipient(), fresh);
        usdc.mint(dave, 100e18);
        vm.startPrank(dave);
        usdc.approve(address(r2), 100e18);
        r2.buyTickets(100, address(0));
        vm.stopPrank();
        _settle(r2);
        r2.withdrawFee();
        assertEq(usdc.balanceOf(fresh), 2e18);
    }

    // ========================================================================
    // 4. OWNERSHIP / DEPLOYMENT
    // ========================================================================

    /// FA-6 / R-07: script/Deploy.s.sol used `new RaffleFactory{salt: ...}` with `Ownable(msg.sender)`.
    /// forge routes CREATE2 through the deterministic deployer proxy, so the PROXY became the owner
    /// and the factory was permanently un-administrable. The constructor now takes the owner
    /// explicitly, exactly so that the deployment route cannot decide it.
    function test_Fixed_Deploy_Create2ProxyBecomesOwner() public {
        vm.etch(DETERMINISTIC_DEPLOYER, address(new Create2ProxyModel()).code);
        address deployerEOA = makeAddr("deployerEOA");
        address intendedOwner = makeAddr("factoryOwnerSafe"); // a Safe / timelock in production

        bytes32 salt = bytes32(uint256(9)); // same salt as script/Deploy.s.sol
        bytes memory initCode = abi.encodePacked(
            type(RaffleFactory).creationCode, abi.encode(intendedOwner, feeRecipient, uint256(200), address(provider))
        );
        vm.prank(deployerEOA);
        (bool ok, bytes memory ret) = DETERMINISTIC_DEPLOYER.call(abi.encodePacked(salt, initCode));
        assertTrue(ok);
        address deployed;
        assembly { deployed := shr(96, mload(add(ret, 32))) }
        assertEq(deployed, vm.computeCreate2Address(salt, keccak256(initCode), DETERMINISTIC_DEPLOYER));

        RaffleFactory f = RaffleFactory(deployed);
        assertEq(f.owner(), intendedOwner, "owner is the intended operator, not the CREATE2 proxy");
        assertTrue(f.owner() != DETERMINISTIC_DEPLOYER);
        assertTrue(f.owner() != deployerEOA, "and not the broadcasting key either");
        assertEq(f.feeBps(), 200, "the documented 2% default, not 0.1%");

        // The proxy cannot administer it...
        vm.prank(DETERMINISTIC_DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DETERMINISTIC_DEPLOYER));
        f.setFeeBps(300);
        // ...and the intended owner can.
        vm.prank(intendedOwner);
        f.setFeeBps(300);
        assertEq(f.feeBps(), 300, "admin surface is live");

        // Ownership hand-over is two-step, so a typo cannot brick it (R-17).
        address newOwner = makeAddr("newOwner");
        vm.prank(intendedOwner);
        f.transferOwnership(newOwner);
        assertEq(f.owner(), intendedOwner, "not transferred until accepted");
        vm.prank(newOwner);
        f.acceptOwnership();
        assertEq(f.owner(), newOwner);
    }

    // ========================================================================
    // 5. PARAMETER VALIDATION
    // ========================================================================

    /// OZ SafeERC20 / the balance-delta check reject codeless token addresses at creation.
    /// A codeless payment token is accepted at creation but nobody can buy, so the raffle
    /// simply fails and the seller gets the asset back. No victim.
    /// C2-04 (Codex v2): both token addresses must contain code. An EOA payment token used to
    /// produce a listed raffle that could never sell a ticket, so the prize sat escrowed until
    /// the seller noticed. Creation now refuses before anything is escrowed.
    function test_Fixed_EOATokenAddressesRejected() public {
        address eoaToken = makeAddr("eoaToken");
        uint256 aliceBefore = asset.balanceOf(alice);

        vm.startPrank(alice);
        asset.approve(address(factory), PRIZE);

        vm.expectRevert(bytes("Raffle: asset token not a contract"));
        factory.createRaffle(
            address(0),
            eoaToken,
            PRIZE,
            address(pay),
            1e18,
            100,
            100e18,
            block.timestamp + 1,
            block.timestamp + 7 days,
            3
        );

        vm.expectRevert(bytes("Raffle: payment token not a contract"));
        factory.createRaffle(
            address(0),
            address(asset),
            PRIZE,
            eoaToken,
            1e18,
            100,
            100e18,
            block.timestamp + 1,
            block.timestamp + 7 days,
            3
        );
        vm.stopPrank();

        // Nothing was listed and nothing was escrowed.
        assertEq(factory.getRaffles(0, 100).length, 0, "no raffle registered");
        assertEq(asset.balanceOf(alice), aliceBefore, "prize never left the seller");
    }

    /// FA-10 / R-16: startTime and endTime used to be unchecked against block.timestamp, so a
    /// raffle could be born dead - and, crucially, a one-second window is what let the FA-1
    /// approval drain complete inside two blocks. Both are now rejected.
    function test_Fixed_TimeWindowValidated() public {
        vm.startPrank(alice);
        asset.approve(address(factory), PRIZE);

        // Entirely in the past: used to be accepted and instantly failed.
        vm.expectRevert("Raffle: start in past");
        factory.createRaffle(
            address(0),
            address(asset),
            PRIZE,
            address(pay),
            1e18,
            100,
            100e18,
            block.timestamp - 100,
            block.timestamp - 1,
            3
        );

        // Starting now but ending one second later: the FA-1 enabler.
        vm.expectRevert("Raffle: duration too short");
        factory.createRaffle(
            address(0), address(asset), PRIZE, address(pay), 1e18, 100, 100e18, block.timestamp, block.timestamp + 1, 3
        );

        // One second under MIN_DURATION is still refused.
        vm.expectRevert("Raffle: duration too short");
        factory.createRaffle(
            address(0),
            address(asset),
            PRIZE,
            address(pay),
            1e18,
            100,
            100e18,
            block.timestamp,
            block.timestamp + 10 minutes - 1,
            3
        );

        // Exactly MIN_DURATION is the floor and is accepted.
        Raffle r = Raffle(
            factory.createRaffle(
                address(0),
                address(asset),
                PRIZE,
                address(pay),
                1e18,
                100,
                100e18,
                block.timestamp,
                block.timestamp + 10 minutes,
                3
            )
        );
        vm.stopPrank();
        assertEq(r.endTime() - r.startTime(), 10 minutes);
        assertEq(r.startTime(), block.timestamp);
        assertEq(asset.balanceOf(alice), 0, "and only this one pulled the prize");
    }

    /// assetToken == paymentToken is STILL accepted, deliberately: with the three separate
    /// ledgers and the measured deposits, the shared balance always covers every liability.
    /// This is a recorded decision, not an oversight.
    function test_NotExploitable_SameAssetAndPaymentToken() public {
        Raffle r = _aliceRaffle(address(asset), 100, 3);
        _buy(r, asset, carol, 100);
        _settle(r);
        address[] memory w = _unique(r.getWinners());
        for (uint256 i = 0; i < w.length; i++) {
            vm.prank(w[i]);
            r.claimPrize();
        }
        vm.prank(alice);
        r.withdrawSeller();
        r.withdrawFee();
        assertEq(asset.balanceOf(address(r)), 0, "fully drained, solvent");
        assertEq(asset.balanceOf(feeRecipient), 2e18);
        assertEq(asset.balanceOf(alice), 98e18);
        assertEq(asset.balanceOf(carol), PRIZE);
    }

    /// FA-10 / R-15: assetAmount < winnersCount used to be accepted, producing "winners" credited
    /// zero whose claimPrize() always reverted. It is now rejected at initialize.
    function test_Fixed_AssetAmountBelowWinnersCount() public {
        vm.startPrank(alice);
        asset.approve(address(factory), 3);
        vm.expectRevert("Raffle: prize too small for winners");
        factory.createRaffle(
            address(0), address(asset), 2, address(pay), 1e18, 3, 3e18, block.timestamp, block.timestamp + 1 days, 3
        );

        // One wei per winner is the floor, and every winner really can claim it.
        Raffle r = Raffle(
            factory.createRaffle(
                address(0), address(asset), 3, address(pay), 1e18, 3, 3e18, block.timestamp, block.timestamp + 1 days, 3
            )
        );
        vm.stopPrank();
        _buy(r, pay, carol, 1);
        _buy(r, pay, dave, 1);
        _buy(r, pay, bob, 1);
        _settle(r);

        address[] memory w = _unique(r.getWinners());
        assertEq(w.length, 3, "3 tickets, 3 winners, drawn without replacement");
        uint256 paid;
        for (uint256 i = 0; i < w.length; i++) {
            assertGt(r.pendingPrize(w[i]), 0, "no winner is credited zero");
            vm.prank(w[i]);
            r.claimPrize();
            paid++;
        }
        assertEq(paid, 3, "every winner could claim");
        assertEq(asset.balanceOf(address(r)), 0);
    }

    // ========================================================================
    // 6. REGISTRY
    // ========================================================================

    /// isRaffle/getRaffles carry no trust: anyone can register raffles with arbitrary tokens.
    /// Unchanged by the rewrite; the registry is a directory, not an endorsement.
    function test_NotExploitable_RegistryIsPermissionless() public {
        vm.startPrank(bob);
        MockERC20 fakeUsdc = new MockERC20("USD Coin", "USDC");
        MockERC20 fakeWeth = new MockERC20("Wrapped Ether", "WETH");
        for (uint256 i = 0; i < 50; i++) {
            fakeWeth.approve(address(factory), 1);
            factory.createRaffle(
                address(0),
                address(fakeWeth),
                1,
                address(fakeUsdc),
                1,
                1,
                1,
                block.timestamp,
                block.timestamp + 10 minutes,
                1
            );
        }
        vm.stopPrank();
        assertEq(factory.getRaffleCount(), 50);
        assertTrue(factory.isRaffle(factory.getRaffle(0)));
        // getAllRaffles() is gone; the paged view is the supported way to read the registry.
        assertEq(factory.getRaffles(0, 10).length, 10);
        assertEq(factory.getRaffles(45, 100).length, 5, "limit is clamped to the end");
        assertEq(factory.getRaffles(50, 10).length, 0, "past the end is empty, not a revert");
    }

    // ========================================================================
    // 7. RANDOMNESS PROVIDER (was dead code, R-23)
    // ========================================================================

    /// The provider is now really used, and - like the fee - it is frozen per raffle, so the
    /// owner cannot swap the randomness source under a sale that is already running.
    function test_NotExploitable_RandomnessProviderFrozenPerRaffle() public {
        Raffle r = _aliceRaffle(address(pay), 100, 3);
        _buy(r, pay, carol, 100);

        // Owner points the factory at a provider that never answers.
        SpyRandomnessProvider spy = new SpyRandomnessProvider();
        vm.prank(owner);
        factory.setRandomnessProvider(address(spy));
        assertEq(address(r.randomnessProvider()), address(provider), "frozen at creation");

        _settle(r);
        assertTrue(r.succeeded());
        assertEq(spy.calls(), 0, "the live raffle never touched the swapped-in provider");
        assertEq(r.seed(), SEED, "the draw really consumed the provider's seed");

        // A raffle created afterwards does use the new provider - and if it never answers,
        // the timeout escape hatch (P-4) returns everyone's money.
        asset.mint(alice, PRIZE);
        Raffle r2 = _aliceRaffle(address(pay), 100, 3);
        _buy(r2, pay, dave, 100);
        vm.warp(r2.endTime());
        r2.finalize();
        assertEq(spy.calls(), 1, "provider consulted");
        assertEq(uint256(r2.state()), uint256(Raffle.State.RandomnessPending));
        vm.expectRevert("Raffle: randomness not ready");
        r2.drawWinners();
        vm.expectRevert("Raffle: not timed out");
        r2.failOnTimeout();

        vm.warp(block.timestamp + 1 days + 1);
        r2.failOnTimeout();
        assertTrue(r2.hasFailed());
        vm.prank(dave);
        r2.claimRefund();
        assertEq(pay.balanceOf(dave), 100e18, "buyer made whole");
        vm.prank(alice);
        r2.withdrawAsset();
        assertEq(asset.balanceOf(alice), PRIZE, "seller made whole");
    }

    /// FA-8 (new): the Chainlink provider will only serve raffles its own factory created, so a
    /// stranger cannot drain the VRF subscription. Every path below reverts before the
    /// coordinator is ever called, which is why a dummy coordinator address is enough.
    function test_Fixed_ProviderOnlyServesKnownRaffles() public {
        address coordinator = makeAddr("vrfCoordinator");
        ChainlinkVRFProvider vrf = new ChainlinkVRFProvider(owner, coordinator, bytes32("gaslane"), 1, 3, 200000, false);

        // Before the factory is wired up, nobody at all can spend the subscription.
        vm.prank(bob);
        vm.expectRevert(ChainlinkVRFProvider.FactoryNotSet.selector);
        vrf.requestRandomness(bob, bytes32(0));

        // Only the owner can point it at a factory.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vrf.setFactory(address(factory));
        vm.prank(owner);
        vrf.setFactory(address(factory));

        // (a) A stranger asking for themselves: not a registered raffle.
        vm.prank(bob);
        vm.expectRevert(ChainlinkVRFProvider.OnlyKnownRaffle.selector);
        vrf.requestRandomness(bob, bytes32(0));

        // (b) A stranger asking on behalf of a REAL raffle: the caller is not that raffle.
        Raffle r = _aliceRaffle(address(pay), 100, 3);
        assertTrue(factory.isRaffle(address(r)));
        vm.prank(bob);
        vm.expectRevert(ChainlinkVRFProvider.OnlyKnownRaffle.selector);
        vrf.requestRandomness(address(r), bytes32(0));

        // (c) A rogue clone of the official implementation, asking for itself.
        address rogue = Clones.clone(factory.RAFFLE_IMPLEMENTATION());
        vm.prank(rogue);
        vm.expectRevert(ChainlinkVRFProvider.OnlyKnownRaffle.selector);
        vrf.requestRandomness(rogue, bytes32(0));

        // Nothing was ever recorded, so no subscription spend happened.
        assertEq(vrf.requestedBy(bytes32(0)), address(0));
    }

    // ========================================================================
    // 8. REENTRANCY FROM FACTORY INTO RAFFLE DURING ASSET TRANSFER
    // ========================================================================

    function test_NotExploitable_ReentrancyNestedCreateRaffle() public {
        ReenteringAssetToken hook = new ReenteringAssetToken();
        hook.arm(factory, address(pay), 1);
        hook.approveFactory(10e18);
        address outer = hook.createAsSeller(10e18, block.timestamp, block.timestamp + 1 days);
        address inner = hook.nestedRaffle();
        // Both raffles exist and are registered; the token created both FOR ITSELF, which is the
        // only thing createRaffle now permits. The only artefact is ordering.
        assertTrue(factory.isRaffle(outer) && factory.isRaffle(inner));
        assertEq(factory.getRaffle(0), outer, "outer registered first (before transfer)");
        assertEq(factory.getRaffle(1), inner);
        assertEq(hook.balanceOf(outer), 10e18, "outer funded in full despite the re-entry");
        assertEq(hook.balanceOf(inner), 1);
        assertEq(Raffle(outer).seller(), address(hook));
        assertEq(Raffle(inner).seller(), address(hook), "and never anybody else");
    }

    function test_NotExploitable_ReentrancyWithdrawAssetBeforeFunding() public {
        ReenteringAssetToken hook = new ReenteringAssetToken();
        hook.arm(factory, address(pay), 2);
        hook.approveFactory(10e18);
        address r = hook.createAsSeller(10e18, block.timestamp, block.timestamp + 1 days);
        assertTrue(hook.reentryReverted(), "withdrawAsset during funding reverted");
        // It is now refused on STATE, not on a balance accident: the raffle is Active.
        assertEq(hook.reentryReason(), "Raffle: not failed");
        assertFalse(Raffle(r).assetWithdrawnBySeller());
        assertEq(hook.balanceOf(r), 10e18, "asset correctly locked after the call");
    }

    // ========================================================================
    // OUT OF SCOPE (Raffle.sol) but contradicts factory docs: "From that moment, the prize is
    // locked in the raffle contract until the raffle is finalized" (docs/PRODUCT_FLOW_AND_DECISIONS.md:36)
    // ========================================================================

    /// R-02: _succeeded() was false before endTime, so withdrawAsset()/claimRefund() were open
    /// mid-raffle. Both are now gated on the explicit Failed state (P-1/P-2).
    function test_Fixed_OutOfScope_SellerPullsPrizeMidRaffle() public {
        Raffle r = _aliceRaffle(address(pay), 100, 3);
        _buy(r, pay, carol, 50);

        vm.prank(alice);
        vm.expectRevert("Raffle: not failed");
        r.withdrawAsset(); // prize CANNOT walk out while tickets are on sale
        assertEq(asset.balanceOf(address(r)), PRIZE, "prize still escrowed");

        _buy(r, pay, dave, 50); // sells out

        // Still locked at the deadline, and still locked once it has succeeded.
        vm.warp(r.endTime());
        vm.prank(alice);
        vm.expectRevert("Raffle: not failed");
        r.withdrawAsset();
        r.finalize();
        r.drawWinners();
        assertTrue(r.succeeded());
        vm.prank(alice);
        vm.expectRevert("Raffle: not failed");
        r.withdrawAsset();

        // The seller gets the proceeds and the winners get the prize. Both, in full.
        vm.prank(alice);
        r.withdrawSeller();
        assertEq(pay.balanceOf(alice), 98e18);
        address[] memory w = _unique(r.getWinners());
        for (uint256 i = 0; i < w.length; i++) {
            vm.prank(w[i]);
            r.claimPrize();
        }
        assertEq(asset.balanceOf(address(r)), 0, "prize fully distributed");
        assertEq(asset.balanceOf(alice), 0, "seller kept nothing of it");
    }

    /// R-01: claimRefund() used to work before finalization while leaving the refunded tickets in
    /// the draw. Refunds are now Failed-only, so the ghost-ticket accounting cannot arise.
    function test_Fixed_OutOfScope_RefundMidRaffleKeepsTicketsInDraw() public {
        Raffle r = _aliceRaffle(address(pay), 2, 2); // 2 tickets, 2 winners => each holder wins once
        _buy(r, pay, carol, 1);

        vm.prank(carol);
        vm.expectRevert("Raffle: not failed");
        r.claimRefund(); // no money back, so no ticket can be "free"
        assertEq(pay.balanceOf(carol), 0);
        assertEq(r.tickets(carol), 1, "the ticket is still hers, and still paid for");
        assertEq(r.totalTickets(), 1);
        assertEq(pay.balanceOf(address(r)), 1e18, "accounting and balance agree");

        _buy(r, pay, dave, 1);
        _settle(r);
        assertTrue(r.succeeded());

        vm.prank(carol);
        r.claimPrize();
        vm.prank(dave);
        r.claimPrize();
        assertEq(asset.balanceOf(carol), PRIZE / 2);
        assertEq(asset.balanceOf(dave), PRIZE / 2);

        // The raffle is solvent: the seller really can withdraw.
        vm.prank(alice);
        r.withdrawSeller();
        r.withdrawFee();
        assertEq(pay.balanceOf(alice), 1.96e18);
        assertEq(pay.balanceOf(address(r)), 0);
    }

    /// R-05: one pendingWithdrawals mapping used to hold the seller payout (payment token) and
    /// the winner prizes (asset token), so a seller who also held a ticket drained the other
    /// winners. There are now three ledgers, each denominated in exactly one token.
    function test_Fixed_OutOfScope_SharedPendingWithdrawalsCrossTokenTheft() public {
        vm.startPrank(alice);
        asset.approve(address(factory), PRIZE);
        Raffle r = Raffle(
            factory.createRaffle(
                address(0),
                address(asset),
                PRIZE,
                address(pay),
                100e18,
                2,
                200e18,
                block.timestamp,
                block.timestamp + 1 days,
                2
            )
        );
        vm.stopPrank();
        _buy(r, pay, alice, 1); // seller buys one of the two tickets
        _buy(r, pay, bob, 1);
        _settle(r);

        // Seller payout 196e18 (payment) and prize 500e18 (asset) never touch each other.
        assertEq(r.sellerProceeds(), 196e18, "payment-token ledger");
        assertEq(r.protocolFeeOwed(), 4e18, "payment-token ledger");
        assertEq(r.pendingPrize(alice), PRIZE / 2, "asset-token ledger");
        assertEq(r.pendingPrize(bob), PRIZE / 2, "asset-token ledger");

        vm.prank(alice);
        r.claimPrize();
        assertEq(asset.balanceOf(alice), PRIZE / 2, "exactly the prize, no payment-token spillover");

        vm.prank(bob);
        r.claimPrize(); // the other winner is still fully covered
        assertEq(asset.balanceOf(bob), PRIZE / 2);
        assertEq(asset.balanceOf(address(r)), 0);

        vm.prank(alice);
        r.withdrawSeller();
        r.withdrawFee();
        assertEq(pay.balanceOf(alice), 196e18);
        assertEq(pay.balanceOf(feeRecipient), 4e18);
        assertEq(pay.balanceOf(address(r)), 0);
    }
}
