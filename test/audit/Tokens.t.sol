// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
    REGRESSION SUITE — ERC20 token behaviour / accounting / solvency /
    reentrancy / gas surface of Raffle + RaffleFactory.

    These were adversarial proofs-of-concept against the pre-rewrite contracts
    (docs/security/FINDINGS.md). The attacks are still performed step for step,
    with the original commentary; only the final assertions were inverted.

    Run everything:
        forge test --via-ir --match-path test/audit/Tokens.t.sol -vvv
    Stateful-fuzz solvency invariants (must now HOLD):
        FOUNDRY_INVARIANT_RUNS=128 FOUNDRY_INVARIANT_DEPTH=64 \
        forge test --via-ir --match-path test/audit/Tokens.t.sol --match-test invariant -vvv

    Naming:
        test_Fixed_*           the loss / lock / theft is now impossible. Asserts the specific
                               revert AND that nobody else's money moved.
        test_Accepted_*        the behaviour is UNCHANGED and is a knowingly accepted risk.
                               These are honest records, not fixes.
        test_NotExploitable_*  attack attempted; the contract held up, before and after.
        invariant_*            stateful-fuzz solvency invariants. They found the refund and
                               asset-withdrawal holes; they must now hold.
//////////////////////////////////////////////////////////////////////////*/

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Raffle} from "../../src/Raffle.sol";
import {RaffleFactory} from "../../src/RaffleFactory.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockRandomnessProvider} from "../mocks/MockRandomnessProvider.sol";

/*//////////////////////////////////////////////////////////////////////////
                              MALICIOUS / ODD TOKENS
//////////////////////////////////////////////////////////////////////////*/

/// @dev Burns `feeBps` of every wallet-to-wallet transfer (STA / PAXG style).
contract FeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 _feeBps) ERC20("FeeOnTransfer", "FOT") {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / 10000;
            super._update(from, address(0), fee); // burn
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @dev Shares-based rebasing token (stETH / AMPL style). balanceOf = shares * factor / 1e18.
contract RebasingERC20 {
    string public constant name = "Rebasing";
    string public constant symbol = "RBS";
    uint8 public constant decimals = 18;
    uint256 public factor = 1e18;
    mapping(address => uint256) public shares;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function balanceOf(address a) public view returns (uint256) {
        return (shares[a] * factor) / 1e18;
    }

    function mint(address to, uint256 amount) external {
        shares[to] += (amount * 1e18) / factor;
    }

    /// @dev newFactor < 1e18 == negative rebase, > 1e18 == positive rebase
    function rebase(uint256 newFactor) external {
        factor = newFactor;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        emit Approval(msg.sender, s, a);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        require(al >= amount, "Rebase: allowance");
        if (al != type(uint256).max) allowance[from][msg.sender] = al - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 s = (amount * 1e18) / factor;
        require(shares[from] >= s, "Rebase: insufficient balance");
        shares[from] -= s;
        shares[to] += s;
        emit Transfer(from, to, amount);
    }
}

interface ITransferHook {
    function onTransfer(address from, address to, uint256 amount) external;
}

/// @dev ERC777-style: calls an arbitrary hook after every wallet-to-wallet transfer.
contract HookERC20 is ERC20 {
    ITransferHook public hook;

    constructor() ERC20("Hook", "HOOK") {}

    function setHook(ITransferHook h) external {
        hook = h;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(hook) != address(0) && from != address(0) && to != address(0)) {
            hook.onTransfer(from, to, value);
        }
    }
}

/// @dev USDC-style: admin can pause all transfers and blacklist addresses.
contract PausableBlacklistERC20 is ERC20 {
    bool public paused;
    mapping(address => bool) public blacklisted;

    error EnforcedPause();
    error Blacklisted(address account);

    constructor() ERC20("USDC-like", "USDCL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setBlacklisted(address a, bool b) external {
        blacklisted[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert EnforcedPause();
        if (blacklisted[from]) revert Blacklisted(from);
        if (blacklisted[to]) revert Blacklisted(to);
        super._update(from, to, value);
    }
}

/// @dev USDT-style: transfer / transferFrom / approve return nothing.
contract NoReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    function transfer(address to, uint256 a) external {
        _t(msg.sender, to, a);
    }

    function transferFrom(address f, address to, uint256 a) external {
        require(allowance[f][msg.sender] >= a, "USDT: allowance");
        allowance[f][msg.sender] -= a;
        _t(f, to, a);
    }

    function _t(address f, address to, uint256 a) internal {
        require(balanceOf[f] >= a, "USDT: balance");
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

/// @dev Some tokens (e.g. LEND, old BNB) revert on zero-value transfers.
contract RevertOnZeroERC20 is ERC20 {
    constructor() ERC20("RevertOnZero", "RZ") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(value > 0, "RZ: zero transfer");
        super._update(from, to, value);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                              HOOK ATTACKERS
//////////////////////////////////////////////////////////////////////////*/

library Sel {
    function selectorOf(bytes memory r) internal pure returns (bytes4 s) {
        if (r.length >= 4) {
            assembly {
                s := mload(add(r, 32))
            }
        }
    }
}

/// @dev Fires inside RaffleFactory.createRaffle's funding transferFrom (factory has NO guard).
///      The nested create names the SELLER, not itself: that used to be the R-03 allowance
///      hijack, reached from inside the victim's own transaction.
contract FactoryReentrantHook is ITransferHook {
    RaffleFactory public factory;
    HookERC20 public asset;
    MockERC20 public pay;
    address public seller;

    bool public fired;
    address public nestedRaffle;
    bytes4 public nestedErr;
    bool public buyOk;
    bytes4 public buyErr;

    constructor(RaffleFactory f, HookERC20 a, MockERC20 p, address s) {
        factory = f;
        asset = a;
        pay = p;
        seller = s;
    }

    function onTransfer(address from, address to, uint256 amount) external {
        if (fired || from != seller) return; // only the factory's funding transfer
        fired = true;
        // (1) re-enter the factory while the outer createRaffle is mid-flight, naming the
        //     seller so the factory spends the seller's remaining allowance
        try factory.createRaffle(
            seller,
            address(asset),
            amount,
            address(pay),
            1e18,
            100,
            100e18,
            block.timestamp,
            block.timestamp + 7 days,
            3
        ) returns (
            address a
        ) {
            nestedRaffle = a;
        } catch (bytes memory r) {
            nestedErr = Sel.selectorOf(r);
        }
        // (2) buy on the OUTER raffle before its funding transfer has finished
        pay.approve(to, 1e18);
        try Raffle(to).buyTickets(1, address(0)) {
            buyOk = true;
        } catch (bytes memory r) {
            buyErr = Sel.selectorOf(r);
        }
    }
}

/// @dev Fires inside withdrawFee()'s transfer. Before the rewrite the fee was PUSHED during
///      finalize(), which exposed a `finalized && succeeded && winners == []` read-only window.
///      The fee is now pulled, after the draw, so that window no longer exists.
contract FeeWithdrawHook is ITransferHook {
    Raffle public raffle;
    address public feeRecipient;
    address public seller;

    bool public fired;
    bool public sawSucceeded;
    uint256 public sawWinners;
    uint256 public sawSellerProceeds;
    uint256 public sawFeeOwed;
    bytes4 public claimPrizeErr;
    bytes4 public withdrawSellerErr;
    bytes4 public claimRefundErr;
    bytes4 public withdrawFeeErr;
    bytes4 public drawWinnersErr;
    bytes4 public buyErr;

    constructor(Raffle r, address f, address s) {
        raffle = r;
        feeRecipient = f;
        seller = s;
    }

    function onTransfer(address, address to, uint256) external {
        if (fired || to != feeRecipient) return;
        fired = true;
        sawSucceeded = raffle.succeeded();
        sawWinners = raffle.getWinners().length;
        sawSellerProceeds = raffle.sellerProceeds();
        sawFeeOwed = raffle.protocolFeeOwed();
        try raffle.claimPrize() {}
        catch (bytes memory r) {
            claimPrizeErr = Sel.selectorOf(r);
        }
        try raffle.withdrawSeller() {}
        catch (bytes memory r) {
            withdrawSellerErr = Sel.selectorOf(r);
        }
        try raffle.claimRefund() {}
        catch (bytes memory r) {
            claimRefundErr = Sel.selectorOf(r);
        }
        try raffle.withdrawFee() {}
        catch (bytes memory r) {
            withdrawFeeErr = Sel.selectorOf(r);
        }
        try raffle.drawWinners() {}
        catch (bytes memory r) {
            drawWinnersErr = Sel.selectorOf(r);
        }
        try raffle.buyTickets(1, address(0)) {}
        catch (bytes memory r) {
            buyErr = Sel.selectorOf(r);
        }
    }
}

/// @dev Buyer contract that tries to re-buy inside its own claimRefund() transfer.
contract RefundRebuyAttacker is ITransferHook {
    Raffle public raffle;
    HookERC20 public pay;
    bool public fired;
    bytes4 public err;

    constructor(Raffle r, HookERC20 p) {
        raffle = r;
        pay = p;
    }

    function buy(uint256 n) external {
        pay.approve(address(raffle), n * raffle.ticketPrice());
        raffle.buyTickets(n, address(0));
    }

    function refund() external {
        raffle.claimRefund();
    }

    function onTransfer(address, address to, uint256) external {
        if (fired || to != address(this)) return;
        fired = true;
        try raffle.buyTickets(1, address(0)) {}
        catch (bytes memory r) {
            err = Sel.selectorOf(r);
        }
    }
}

/*//////////////////////////////////////////////////////////////////////////
                              DETERMINISTIC PoCs
//////////////////////////////////////////////////////////////////////////*/

contract TokensAuditTest is Test {
    RaffleFactory public factory;
    MockRandomnessProvider public provider;

    address public seller = address(0x1);
    address public buyer1 = address(0x2);
    address public buyer2 = address(0x3);
    address public buyer3 = address(0x4);
    address public feeRecipient = address(0x5);

    uint256 public constant ASSET_AMOUNT = 1000e18;
    uint256 public constant TICKET_PRICE = 1e18;
    uint256 public constant TICKET_CAP = 100;
    uint256 public constant SELLER_MIN = TICKET_PRICE * TICKET_CAP;
    uint16 public constant WINNERS_COUNT = 3;
    uint256 public constant FEE_BPS = 200;
    uint256 public constant SEED = uint256(keccak256("tokens-audit-seed"));

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.roll(1_000);
        provider = new MockRandomnessProvider();
        provider.setAutoSeed(SEED);
        factory = new RaffleFactory(address(this), feeRecipient, FEE_BPS, address(provider));
    }

    // ---------------------------------------------------------------- helpers

    function _create(
        address assetTok,
        uint256 assetAmt,
        address payTok,
        uint256 price,
        uint256 cap,
        uint16 winners,
        address who
    ) internal returns (Raffle r) {
        vm.prank(who);
        r = Raffle(
            factory.createRaffle(
                address(0),
                assetTok,
                assetAmt,
                payTok,
                price,
                cap,
                price * cap,
                block.timestamp,
                block.timestamp + 7 days,
                winners
            )
        );
    }

    /// @dev works for every OZ-based mock in this file (all expose mint/approve with the same ABI)
    function _buy(Raffle r, address buyer, uint256 n) internal {
        uint256 cost = n * r.ticketPrice();
        MockERC20 pay = MockERC20(r.paymentToken());
        pay.mint(buyer, cost);
        vm.startPrank(buyer);
        pay.approve(address(r), cost);
        r.buyTickets(n, address(0));
        vm.stopPrank();
    }

    function _sellOut(Raffle r) internal {
        _buy(r, buyer1, 34);
        _buy(r, buyer2, 33);
        _buy(r, buyer3, 33);
    }

    function _end(Raffle r) internal {
        vm.roll(block.number + 300);
        vm.warp(r.endTime() + 1);
    }

    /// @dev Settlement is two transactions now (P-5). drawWinners only applies to a sell-out.
    function _settle(Raffle r) internal {
        _end(r);
        r.finalize();
        if (r.state() == Raffle.State.RandomnessPending) r.drawWinners();
    }

    function _unique(address[] memory a) internal pure returns (address[] memory u) {
        address[] memory tmp = new address[](a.length);
        uint256 n;
        for (uint256 i = 0; i < a.length; i++) {
            bool seen;
            for (uint256 j = 0; j < n; j++) {
                if (tmp[j] == a[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) tmp[n++] = a[i];
        }
        u = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            u[i] = tmp[i];
        }
    }

    function _claimAllPrizes(Raffle r) internal returns (uint256 count) {
        address[] memory w = _unique(r.getWinners());
        for (uint256 i = 0; i < w.length; i++) {
            vm.prank(w[i]);
            r.claimPrize();
            count++;
        }
    }

    /// @dev proves that, on a FAILED and fully drained raffle, no entry point can move a token
    ///      for any of the listed callers - and names the exact reason each one gives.
    function _assertAllLockedOnFailed(Raffle r, address[] memory callers) internal {
        address s = r.seller();
        address at = r.assetToken();
        for (uint256 i = 0; i < callers.length; i++) {
            address c = callers[i];
            vm.prank(c);
            vm.expectRevert("Raffle: not active");
            r.buyTickets(1, address(0));
            vm.prank(c);
            vm.expectRevert("Raffle: not active");
            r.finalize();
            vm.prank(c);
            vm.expectRevert("Raffle: not pending");
            r.drawWinners();
            vm.prank(c);
            vm.expectRevert("Raffle: no tickets");
            r.claimRefund();
            vm.prank(c);
            vm.expectRevert("Raffle: not succeeded");
            r.claimPrize();
            vm.prank(c);
            vm.expectRevert("Raffle: not succeeded");
            r.withdrawFee();
            vm.prank(c);
            vm.expectRevert(c == s ? bytes("Raffle: not succeeded") : bytes("Raffle: not seller"));
            r.withdrawSeller();
            vm.prank(c);
            vm.expectRevert(c == s ? bytes("Raffle: asset already withdrawn") : bytes("Raffle: not seller"));
            r.withdrawAsset();
            vm.prank(c);
            vm.expectRevert(c == s ? bytes("Raffle: protected token") : bytes("Raffle: not seller"));
            r.recoverToken(at, c);
        }
    }

    function _stdAsset() internal returns (MockERC20 asset) {
        asset = new MockERC20("Asset", "AST");
        asset.mint(seller, ASSET_AMOUNT);
        vm.prank(seller);
        asset.approve(address(factory), ASSET_AMOUNT);
    }

    /*====================================================================
        1. FEE-ON-TRANSFER PAYMENT TOKEN  (H-03 / R-09)
    ====================================================================*/

    /// totalFunds used to be credited with the NOMINAL amount while only 99% arrived, so
    /// finalize() succeeded on nominal accounting and the seller's payout became unclaimable.
    /// buyTickets now measures the balance delta and refuses the token outright.
    function test_Fixed_FoTPayment_SellerPayoutStuck() public {
        FeeOnTransferERC20 pay = new FeeOnTransferERC20(100); // 1 % burned per transfer
        MockERC20 asset = _stdAsset();
        Raffle r = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);

        pay.mint(buyer1, 34e18);
        vm.startPrank(buyer1);
        pay.approve(address(r), 34e18);
        vm.expectRevert("Raffle: unsupported payment token");
        r.buyTickets(34, address(0));
        vm.stopPrank();

        // Nothing was recorded and nothing was taken: the mismatch is caught inside the same call.
        assertEq(r.totalTickets(), 0, "no nominal credit");
        assertEq(r.totalFunds(), 0);
        assertEq(r.tickets(buyer1), 0);
        assertEq(pay.balanceOf(address(r)), 0, "not a single wei entered the raffle");
        assertEq(pay.balanceOf(buyer1), 34e18, "buyer keeps their money");

        // With no purchase possible the raffle can only fail, and the seller gets the prize back.
        // The old "seller credited 98e18 against 97e18 on hand" state is unreachable.
        _settle(r);
        assertTrue(r.hasFailed());
        assertEq(r.sellerProceeds(), 0);
        vm.prank(seller);
        r.withdrawAsset();
        assertEq(asset.balanceOf(seller), ASSET_AMOUNT, "seller made whole");
        assertEq(asset.balanceOf(address(r)), 0);
    }

    /// Failed FoT raffle: refunds used to be paid at nominal price out of a balance that was 1%
    /// short, so the LAST claimant reverted and lost their ENTIRE refund. The scenario can no
    /// longer be set up, because no purchase in this token is ever recorded.
    function test_Fixed_FoTPayment_FailedRaffle_LastRefundReverts() public {
        FeeOnTransferERC20 pay = new FeeOnTransferERC20(100);
        MockERC20 asset = _stdAsset();
        Raffle r = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);

        address[3] memory buyers = [buyer1, buyer2, buyer3];
        uint8[3] memory amounts = [34, 33, 32];
        for (uint256 i = 0; i < 3; i++) {
            pay.mint(buyers[i], uint256(amounts[i]) * 1e18);
            vm.startPrank(buyers[i]);
            pay.approve(address(r), uint256(amounts[i]) * 1e18);
            vm.expectRevert("Raffle: unsupported payment token");
            r.buyTickets(amounts[i], address(0));
            vm.stopPrank();
            assertEq(pay.balanceOf(buyers[i]), uint256(amounts[i]) * 1e18, "buyer untouched");
        }
        assertEq(pay.balanceOf(address(r)), 0);
        assertEq(r.totalTickets(), 0);

        _settle(r);
        assertTrue(r.hasFailed());
        // There is no under-funded refund queue to be last in.
        vm.prank(buyer3);
        vm.expectRevert("Raffle: no tickets");
        r.claimRefund();
        vm.prank(seller);
        r.withdrawAsset();
        assertEq(asset.balanceOf(seller), ASSET_AMOUNT);
    }

    /*====================================================================
        2. FEE-ON-TRANSFER / DEFLATIONARY ASSET TOKEN
    ====================================================================*/

    /// The factory used to transfer assetAmount and never verify what arrived, so _pickWinners
    /// credited more than was escrowed and the last winner could not claim. The escrow transfer
    /// is now balance-delta checked, and the whole creation is rejected.
    function test_Fixed_FoTAsset_LastWinnerCannotClaim() public {
        FeeOnTransferERC20 asset = new FeeOnTransferERC20(100);
        MockERC20 pay = new MockERC20("Pay", "PAY");
        asset.mint(seller, ASSET_AMOUNT);
        vm.prank(seller);
        asset.approve(address(factory), ASSET_AMOUNT);

        vm.prank(seller);
        vm.expectRevert(RaffleFactory.UnsupportedAssetToken.selector);
        factory.createRaffle(
            address(0),
            address(asset),
            ASSET_AMOUNT,
            address(pay),
            TICKET_PRICE,
            TICKET_CAP,
            SELLER_MIN,
            block.timestamp,
            block.timestamp + 7 days,
            WINNERS_COUNT
        );

        // No raffle was registered and no prize left the seller's wallet, so there is no
        // over-credited winner list to be the last member of.
        assertEq(factory.getRaffleCount(), 0, "nothing registered");
        assertEq(asset.balanceOf(seller), ASSET_AMOUNT, "seller keeps the prize");
        assertEq(asset.allowance(seller, address(factory)), ASSET_AMOUNT, "allowance untouched");
    }

    /// A failed FoT raffle used to lock the seller's whole 990e18, because withdrawAsset()
    /// transferred the nominal assetAmount out of a short balance and there was no partial exit.
    /// Rejected at creation now, so the lock cannot be reached.
    function test_Fixed_FoTAsset_FailedRaffle_SellerAssetLocked() public {
        // Even a 0.01 % cut - small enough to look like rounding - is refused.
        FeeOnTransferERC20 asset = new FeeOnTransferERC20(1);
        MockERC20 pay = new MockERC20("Pay", "PAY");
        asset.mint(seller, ASSET_AMOUNT);
        vm.prank(seller);
        asset.approve(address(factory), ASSET_AMOUNT);

        vm.prank(seller);
        vm.expectRevert(RaffleFactory.UnsupportedAssetToken.selector);
        factory.createRaffle(
            address(0),
            address(asset),
            ASSET_AMOUNT,
            address(pay),
            TICKET_PRICE,
            TICKET_CAP,
            SELLER_MIN,
            block.timestamp,
            block.timestamp + 7 days,
            WINNERS_COUNT
        );
        assertEq(asset.balanceOf(seller), ASSET_AMOUNT, "the prize never left, so nothing is locked");

        // The check is on delivery, not on the token's shape: the same contract with its fee
        // switched off delivers in full and is accepted, and the failed-raffle exit works.
        FeeOnTransferERC20 clean = new FeeOnTransferERC20(0);
        clean.mint(seller, ASSET_AMOUNT);
        vm.prank(seller);
        clean.approve(address(factory), ASSET_AMOUNT);
        Raffle r = _create(address(clean), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        assertEq(clean.balanceOf(address(r)), ASSET_AMOUNT);
        _buy(r, buyer1, 10);
        _settle(r);
        assertTrue(r.hasFailed());
        vm.prank(seller);
        r.withdrawAsset();
        assertEq(clean.balanceOf(seller), ASSET_AMOUNT);
        vm.prank(buyer1);
        r.claimRefund();
        assertEq(pay.balanceOf(buyer1), 10e18);
        assertEq(clean.balanceOf(address(r)), 0);
        assertEq(pay.balanceOf(address(r)), 0);
    }

    /// Same FoT token for asset AND payment: the shared balance used to let the seller's
    /// shortfall be paid out of buyers' money, migrating the loss to the last refunders.
    /// The asset leg is measured first, so the raffle never comes into existence.
    function test_Fixed_SameFoTToken_SellerShortfallPaidByBuyers() public {
        FeeOnTransferERC20 tok = new FeeOnTransferERC20(100);
        tok.mint(seller, ASSET_AMOUNT);
        vm.prank(seller);
        tok.approve(address(factory), ASSET_AMOUNT);

        vm.prank(seller);
        vm.expectRevert(RaffleFactory.UnsupportedAssetToken.selector);
        factory.createRaffle(
            address(0),
            address(tok),
            ASSET_AMOUNT,
            address(tok),
            TICKET_PRICE,
            TICKET_CAP,
            SELLER_MIN,
            block.timestamp,
            block.timestamp + 7 days,
            WINNERS_COUNT
        );
        assertEq(factory.getRaffleCount(), 0);
        assertEq(tok.balanceOf(seller), ASSET_AMOUNT, "no buyer money to migrate a loss onto");
    }

    /*====================================================================
        3. REBASING TOKENS — ACCEPTED, DOCUMENTED RISK
    ====================================================================*/

    /// ACCEPTED RISK, NOT FIXED. The deposit is measured at deposit time and 1000e18 really did
    /// arrive; a rebase happening LATER is invisible to any deposit-time check, so a raffle in a
    /// rebasing asset can still end up short. Recorded honestly: the fix for fee-on-transfer
    /// does not and cannot cover this, and rebasing tokens are out of scope for the escrow.
    function test_Accepted_RebasingAssetNegativeRebaseLocksSellerAsset() public {
        RebasingERC20 asset = new RebasingERC20();
        MockERC20 pay = new MockERC20("Pay", "PAY");
        asset.mint(seller, ASSET_AMOUNT);
        vm.prank(seller);
        asset.approve(address(factory), ASSET_AMOUNT);
        Raffle r = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        // The delta check passes: at deposit time the full amount was delivered.
        assertEq(asset.balanceOf(address(r)), 1000e18);

        asset.rebase(0.9e18); // -10 % (slashing / negative rebase), AFTER the deposit
        assertEq(asset.balanceOf(address(r)), 900e18);

        _buy(r, buyer1, 10);
        _settle(r);
        assertTrue(r.hasFailed());

        // Still broken, and knowingly so: the nominal 1000e18 exceeds the 900e18 on hand.
        vm.prank(seller);
        vm.expectRevert("Rebase: insufficient balance");
        r.withdrawAsset();

        // What DID improve: the flag is set before the transfer and the whole call reverts
        // atomically, so a failed attempt does not burn the seller's one chance. Once the token
        // recovers, the exit still works.
        assertFalse(r.assetWithdrawnBySeller(), "not marked withdrawn by a reverted attempt");
        asset.rebase(1e18);
        vm.prank(seller);
        r.withdrawAsset();
        assertEq(asset.balanceOf(seller), 1000e18);
        assertTrue(r.assetWithdrawnBySeller());

        // Buyers were never exposed to it: payments live in a different, well-behaved ledger.
        vm.prank(buyer1);
        r.claimRefund();
        assertEq(pay.balanceOf(buyer1), 10e18);
    }

    /// ACCEPTED RISK, NOT FIXED. Positive-rebase yield on the escrowed asset is still stranded:
    /// recoverToken() deliberately refuses the asset and payment tokens in every state, because
    /// it must never be able to reach an escrowed liability. Sweeping yield safely would need a
    /// share-aware accounting model, which this contract does not have.
    function test_Accepted_RebasingAssetPositiveRebaseDustStrandedForever() public {
        RebasingERC20 asset = new RebasingERC20();
        MockERC20 pay = new MockERC20("Pay", "PAY");
        asset.mint(seller, ASSET_AMOUNT);
        vm.prank(seller);
        asset.approve(address(factory), ASSET_AMOUNT);
        Raffle r = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);

        asset.rebase(1.1e18); // +10 %
        assertApproxEqAbs(asset.balanceOf(address(r)), 1100e18, 1e6);

        _buy(r, buyer1, 10);
        _settle(r);
        vm.prank(seller);
        r.withdrawAsset();
        vm.prank(buyer1);
        r.claimRefund();
        assertApproxEqAbs(asset.balanceOf(address(r)), 100e18, 1e6, "100e18 of yield left behind");

        // recoverToken() exists now, but by design it cannot touch either escrowed token.
        vm.prank(seller);
        vm.expectRevert("Raffle: protected token");
        r.recoverToken(address(asset), seller);
        vm.prank(seller);
        vm.expectRevert("Raffle: protected token");
        r.recoverToken(address(pay), seller);
        vm.prank(buyer1);
        vm.expectRevert("Raffle: not seller");
        r.recoverToken(address(asset), buyer1);

        address[] memory callers = new address[](3);
        callers[0] = seller;
        callers[1] = buyer1;
        callers[2] = feeRecipient;
        _assertAllLockedOnFailed(r, callers); // nobody can ever move it
        assertApproxEqAbs(asset.balanceOf(address(r)), 100e18, 1e6);
    }

    /*====================================================================
        4. SAME TOKEN FOR ASSET AND PAYMENT  (shared balance)
    ====================================================================*/

    /// Honest flows: the shared balance always covers liabilities in every claim ordering.
    /// Still deliberately permitted, now backed by three separate per-token ledgers.
    function test_NotExploitable_SameToken_HonestFlowsBalance() public {
        MockERC20 tok = new MockERC20("Same", "SAME");
        tok.mint(seller, 4 * ASSET_AMOUNT);
        vm.prank(seller);
        tok.approve(address(factory), 4 * ASSET_AMOUNT);

        // ---- failed raffle, ordering A: seller first, then refunds
        Raffle a = _create(address(tok), ASSET_AMOUNT, address(tok), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        _buy(a, buyer1, 30);
        _buy(a, buyer2, 20);
        _settle(a);
        vm.prank(seller);
        a.withdrawAsset();
        vm.prank(buyer1);
        a.claimRefund();
        vm.prank(buyer2);
        a.claimRefund();
        assertEq(tok.balanceOf(address(a)), 0, "failed/A balanced");

        // ---- failed raffle, ordering B: refunds first, then seller
        Raffle b = _create(address(tok), ASSET_AMOUNT, address(tok), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        _buy(b, buyer1, 30);
        _buy(b, buyer2, 20);
        _settle(b);
        vm.prank(buyer1);
        b.claimRefund();
        vm.prank(buyer2);
        b.claimRefund();
        vm.prank(seller);
        b.withdrawAsset();
        assertEq(tok.balanceOf(address(b)), 0, "failed/B balanced");

        // ---- succeeded raffle, ordering A: seller and fee first, then winners
        Raffle c = _create(address(tok), ASSET_AMOUNT, address(tok), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        _sellOut(c);
        _settle(c);
        vm.prank(seller);
        c.withdrawSeller();
        c.withdrawFee();
        _claimAllPrizes(c);
        assertEq(tok.balanceOf(address(c)), 0, "succeeded/A balanced");

        // ---- succeeded raffle, ordering B: winners first, then seller and fee
        Raffle d = _create(address(tok), ASSET_AMOUNT, address(tok), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        _sellOut(d);
        _settle(d);
        _claimAllPrizes(d);
        vm.prank(seller);
        d.withdrawSeller();
        d.withdrawFee();
        assertEq(tok.balanceOf(address(d)), 0, "succeeded/B balanced");
    }

    /*====================================================================
        5. REENTRANCY VIA TOKEN HOOKS
    ====================================================================*/

    /// (a) factory.createRaffle has no reentrancy guard; the hook re-enters createRaffle and buys
    ///     on the not-yet-funded raffle. The nested create names the SELLER, which is exactly the
    ///     R-03 hijack reached from inside the victim's own transaction - and it is now refused
    ///     even there. Funding still completes atomically.
    function test_NotExploitable_FactoryCreateRaffleHookReentrancy() public {
        HookERC20 asset = new HookERC20();
        MockERC20 pay = new MockERC20("Pay", "PAY");
        asset.mint(seller, 2 * ASSET_AMOUNT);
        vm.prank(seller);
        asset.approve(address(factory), 2 * ASSET_AMOUNT);

        FactoryReentrantHook hook = new FactoryReentrantHook(factory, asset, pay, seller);
        pay.mint(address(hook), 10e18);
        asset.setHook(hook);

        Raffle outer =
            _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);

        assertTrue(hook.fired());
        assertEq(hook.nestedErr(), RaffleFactory.SellerMustBeCaller.selector, "nested hijack refused");
        assertEq(hook.nestedRaffle(), address(0), "no nested raffle exists");
        assertEq(factory.getRaffleCount(), 1, "only the seller's own raffle was registered");
        assertEq(factory.getRaffle(0), address(outer));
        assertEq(asset.balanceOf(address(outer)), ASSET_AMOUNT, "outer funded in full");
        assertEq(asset.balanceOf(seller), ASSET_AMOUNT, "the seller's remaining allowance was not spent");

        assertTrue(hook.buyOk(), "buy on the not-yet-funded raffle accepted but harmless (same tx)");
        assertEq(outer.tickets(address(hook)), 1);
        assertEq(outer.totalFunds(), 1e18);
        assertEq(pay.balanceOf(address(outer)), 1e18, "accounting and balance agree");
    }

    /// (b) the protocol fee is no longer pushed inside finalize(); it is pulled by withdrawFee()
    ///     AFTER the draw. Every state-changing re-entry is still blocked, and the old read-only
    ///     window (`finalized && succeeded && winners == []`) no longer exists.
    function test_NotExploitable_FeeWithdrawHookReentrancy_StateConsistent() public {
        HookERC20 pay = new HookERC20();
        MockERC20 asset = _stdAsset();
        Raffle r = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        _sellOut(r);

        FeeWithdrawHook hook = new FeeWithdrawHook(r, feeRecipient, seller);
        pay.setHook(hook);

        // Settlement itself never touches the payment token, so the hook cannot fire during it.
        _settle(r);
        assertFalse(hook.fired(), "no fee push during settlement");
        assertEq(r.getWinners().length, WINNERS_COUNT, "winners exist the moment the raffle succeeds");

        r.withdrawFee();
        assertTrue(hook.fired());

        bytes4 g = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        assertEq(hook.claimPrizeErr(), g, "claimPrize guarded");
        assertEq(hook.withdrawSellerErr(), g, "withdrawSeller guarded");
        assertEq(hook.claimRefundErr(), g, "claimRefund guarded");
        assertEq(hook.withdrawFeeErr(), g, "withdrawFee guarded");
        assertEq(hook.drawWinnersErr(), g, "drawWinners guarded");
        assertEq(hook.buyErr(), g, "buyTickets guarded");

        // An integrator called from the token hook sees a CONSISTENT raffle.
        assertTrue(hook.sawSucceeded());
        assertEq(hook.sawWinners(), WINNERS_COUNT, "succeeded implies winners are already set");
        assertEq(hook.sawSellerProceeds(), 98e18, "seller ledger visible and correct");
        assertEq(hook.sawFeeOwed(), 0, "fee ledger zeroed before the transfer (CEI)");
        assertEq(pay.balanceOf(feeRecipient), 2e18);
    }

    /// (c) the claimRefund transfer hook cannot re-buy in the same tx (guard). What used to make
    ///     the guard irrelevant was that the identical re-buy succeeded in the NEXT tx, because
    ///     refunds were possible mid-raffle. Refunds are Failed-only now, and Failed is
    ///     permanent, so the cross-transaction version is closed too.
    function test_NotExploitable_RefundHookCannotRebuySameTx() public {
        HookERC20 pay = new HookERC20();
        MockERC20 asset = _stdAsset();
        Raffle r = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);

        RefundRebuyAttacker atk = new RefundRebuyAttacker(r, pay);
        pay.mint(address(atk), 200e18);
        pay.setHook(atk);

        atk.buy(10);
        // A refund before the raffle has failed is refused outright (R-01).
        vm.expectRevert("Raffle: not failed");
        atk.refund();
        assertEq(r.tickets(address(atk)), 10);

        _settle(r); // 10 of 100 sold -> Failed
        assertTrue(r.hasFailed());

        atk.refund(); // hook attempts a re-buy mid-transfer
        assertTrue(atk.fired());
        assertEq(atk.err(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "same-tx rebuy blocked");
        assertEq(r.tickets(address(atk)), 0);
        assertEq(pay.balanceOf(address(atk)), 200e18, "refunded in full, nothing extra");
        assertEq(pay.balanceOf(address(r)), 0);

        // The cross-transaction version is now blocked as well.
        vm.expectRevert("Raffle: not active");
        atk.buy(10);
        assertEq(r.tickets(address(atk)), 0);
        assertEq(pay.balanceOf(address(r)), 0, "no ghost accounting to exploit");
    }

    /*====================================================================
        6. PAUSABLE / BLACKLIST TOKENS  (M-02 / R-08)
    ====================================================================*/

    /// The payment token is paused after sell-out and before settlement. finalize() used to push
    /// the protocol fee, so it reverted and EVERY other function reverted with it: 100e18 of
    /// payments plus 1000e18 of prize frozen with no escape. Settlement no longer moves the
    /// payment token at all.
    function test_Fixed_PausedPaymentTokenAtFinalize_LocksAllFunds() public {
        PausableBlacklistERC20 pay = new PausableBlacklistERC20();
        MockERC20 asset = _stdAsset();
        Raffle r = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        _sellOut(r);
        _end(r);

        pay.setPaused(true);

        // Both settlement steps go through while the token is frozen.
        r.finalize();
        assertEq(uint256(r.state()), uint256(Raffle.State.RandomnessPending));
        r.drawWinners();
        assertTrue(r.succeeded(), "settlement is not hostage to the payment token");
        assertEq(r.sellerProceeds(), 98e18);
        assertEq(r.protocolFeeOwed(), 2e18);

        // Winners are paid in the ASSET token and are completely unaffected.
        assertEq(_claimAllPrizes(r), _unique(r.getWinners()).length);
        assertEq(asset.balanceOf(address(r)), 0, "prize fully distributed while pay is paused");

        // Payment-token claims simply wait their turn. Nothing is lost, no state is corrupted.
        vm.prank(seller);
        vm.expectRevert(PausableBlacklistERC20.EnforcedPause.selector);
        r.withdrawSeller();
        vm.expectRevert(PausableBlacklistERC20.EnforcedPause.selector);
        r.withdrawFee();
        assertEq(pay.balanceOf(address(r)), 100e18);
        assertEq(r.sellerProceeds(), 98e18, "ledger intact after the failed attempt");
        assertEq(r.protocolFeeOwed(), 2e18);

        pay.setPaused(false);
        vm.prank(seller);
        r.withdrawSeller();
        r.withdrawFee();
        assertEq(pay.balanceOf(seller), 98e18);
        assertEq(pay.balanceOf(feeRecipient), 2e18);
        assertEq(pay.balanceOf(address(r)), 0, "nothing was permanently lost");
    }

    /// feeRecipient blacklisted permanently. This used to lock every raffle in that token and was
    /// recoverable only by the factory owner (and not at all after renounceOwnership or R-07).
    /// The fee is pull-based and the recipient is frozen per raffle, so a hostile fee recipient
    /// can now only ever block their own fee.
    function test_Fixed_BlacklistedFeeRecipient_LockedUntilAdminAction() public {
        PausableBlacklistERC20 pay = new PausableBlacklistERC20();
        MockERC20 asset = new MockERC20("Asset", "AST");
        asset.mint(seller, 3 * ASSET_AMOUNT);
        vm.prank(seller);
        asset.approve(address(factory), 3 * ASSET_AMOUNT);

        Raffle r1 = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        Raffle r2 = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        Raffle r3 = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        _sellOut(r1);
        _sellOut(r2);
        _sellOut(r3);
        _end(r1); // all three share an endTime

        pay.setBlacklisted(feeRecipient, true);
        bytes memory bl = abi.encodeWithSelector(PausableBlacklistERC20.Blacklisted.selector, feeRecipient);

        // Settlement completes for both raffles despite the blacklist.
        r1.finalize();
        r1.drawWinners();
        r2.finalize();
        r2.drawWinners();
        assertTrue(r1.succeeded() && r2.succeeded());

        // Seller and winners are paid in full out of r1...
        vm.prank(seller);
        r1.withdrawSeller();
        assertEq(pay.balanceOf(seller), 98e18);
        _claimAllPrizes(r1);
        assertEq(asset.balanceOf(address(r1)), 0);

        // ...and only the fee is blocked, and only its own 2e18.
        vm.expectRevert(bl);
        r1.withdrawFee();
        assertEq(r1.protocolFeeOwed(), 2e18, "still owed, not lost");
        assertEq(pay.balanceOf(address(r1)), 2e18, "nothing but the fee is left");

        // The owner can no longer "rescue" a live raffle by rotating the recipient - terms are
        // frozen - and no longer needs to, because nobody else's money was ever at risk.
        factory.setFeeRecipient(address(0x55));
        assertEq(r2.feeRecipient(), feeRecipient, "frozen at creation");
        vm.expectRevert(bl);
        r2.withdrawFee();
        // Waiving the fee on the factory is equally retroactively powerless.
        factory.setFeeBps(0);
        assertEq(r2.feeBps(), FEE_BPS);
        factory.setFeeBps(FEE_BPS);
        factory.setFeeRecipient(feeRecipient);

        // The moment the issuer relents, the fee is collectable. Nothing was destroyed.
        pay.setBlacklisted(feeRecipient, false);
        r1.withdrawFee();
        r2.withdrawFee();
        assertEq(pay.balanceOf(feeRecipient), 4e18);

        // If the RAFFLE ITSELF is blacklisted, that is a token-level freeze of one address.
        // Settlement still completes and the ledgers stay correct; the asset token is a separate
        // token, so winners are still paid. Only payment-token movement waits on the issuer.
        pay.setBlacklisted(address(r3), true);
        r3.finalize();
        r3.drawWinners();
        assertTrue(r3.succeeded(), "even a frozen raffle address can settle");
        _claimAllPrizes(r3);
        assertEq(asset.balanceOf(address(r3)), 0, "winners paid");
        bytes memory bl3 = abi.encodeWithSelector(PausableBlacklistERC20.Blacklisted.selector, address(r3));
        vm.prank(seller);
        vm.expectRevert(bl3);
        r3.withdrawSeller();
        vm.expectRevert(bl3);
        r3.withdrawFee();
        pay.setBlacklisted(address(r3), false);
        vm.prank(seller);
        r3.withdrawSeller();
        r3.withdrawFee();
        assertEq(pay.balanceOf(address(r3)), 0, "fully drained once the freeze lifts");
    }

    /*====================================================================
        7 + 8. ZERO-VALUE TRANSFERS / NO-RETURN TOKENS
    ====================================================================*/

    /// No code path performs a zero-value transfer: a zero fee is rejected before the transfer
    /// by withdrawFee(), a zero prize can no longer exist (assetAmount >= winnersCount is
    /// enforced), and refunds/withdrawals are >0 by construction.
    function test_NotExploitable_NoZeroValueTransferPath() public {
        RevertOnZeroERC20 tok = new RevertOnZeroERC20();

        // (i) feeBps == 0 factory: withdrawFee() refuses before it can attempt a zero transfer
        RaffleFactory f0 = new RaffleFactory(address(this), feeRecipient, 0, address(provider));
        tok.mint(seller, 3);
        vm.startPrank(seller);
        tok.approve(address(f0), 3);
        Raffle a = Raffle(
            f0.createRaffle(
                address(0), address(tok), 3, address(tok), 1, 3, 3, block.timestamp, block.timestamp + 7 days, 3
            )
        );
        vm.stopPrank();
        tok.mint(buyer1, 3);
        vm.startPrank(buyer1);
        tok.approve(address(a), 3);
        a.buyTickets(3, address(0));
        vm.stopPrank();
        _settle(a);
        assertTrue(a.succeeded());
        assertEq(a.protocolFeeOwed(), 0);
        vm.expectRevert("Raffle: no fee to withdraw");
        a.withdrawFee();

        // Every winner is credited at least one wei, so claimPrize never reaches a zero transfer.
        address[] memory w = _unique(a.getWinners());
        uint256 credited;
        for (uint256 i = 0; i < w.length; i++) {
            assertGt(a.pendingPrize(w[i]), 0, "assetAmount >= winnersCount is enforced");
            credited += a.pendingPrize(w[i]);
        }
        assertEq(credited, 3);
        _claimAllPrizes(a);
        vm.prank(seller);
        a.withdrawSeller();
        assertEq(tok.balanceOf(address(a)), 0);

        // (ii) feeBps == 200 but totalFunds so small the fee rounds to 0 -> same refusal
        tok.mint(seller, 3);
        vm.startPrank(seller);
        tok.approve(address(factory), 3);
        Raffle b = Raffle(
            factory.createRaffle(
                address(0), address(tok), 3, address(tok), 1, 3, 3, block.timestamp, block.timestamp + 7 days, 1
            )
        );
        vm.stopPrank();
        tok.mint(buyer1, 3);
        vm.startPrank(buyer1);
        tok.approve(address(b), 3);
        b.buyTickets(3, address(0));
        vm.stopPrank();
        _settle(b);
        assertTrue(b.succeeded());
        assertEq(b.protocolFeeOwed(), 0, "3 * 200 / 10000 rounds to zero");
        assertEq(b.sellerProceeds(), 3);
        vm.expectRevert("Raffle: no fee to withdraw");
        b.withdrawFee();

        // (iii) failed path: refund + withdrawAsset are strictly positive
        tok.mint(seller, 3);
        vm.startPrank(seller);
        tok.approve(address(factory), 3);
        Raffle c = Raffle(
            factory.createRaffle(
                address(0), address(tok), 3, address(tok), 1, 3, 3, block.timestamp, block.timestamp + 7 days, 1
            )
        );
        vm.stopPrank();
        tok.mint(buyer1, 1);
        vm.startPrank(buyer1);
        tok.approve(address(c), 1);
        c.buyTickets(1, address(0));
        vm.stopPrank();
        _settle(c);
        vm.prank(seller);
        c.withdrawAsset();
        vm.prank(buyer1);
        c.claimRefund();
        assertEq(tok.balanceOf(address(c)), 0);
    }

    /// USDT-style empty return data is accepted by SafeERC20 across the full lifecycle, and the
    /// balance-delta checks work on it too.
    function test_NotExploitable_USDTStyleNoReturnValue() public {
        NoReturnERC20 tok = new NoReturnERC20();
        tok.mint(seller, ASSET_AMOUNT);
        vm.prank(seller);
        tok.approve(address(factory), ASSET_AMOUNT);
        Raffle r = _create(address(tok), ASSET_AMOUNT, address(tok), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        assertEq(tok.balanceOf(address(r)), ASSET_AMOUNT);

        tok.mint(buyer1, 100e18);
        vm.startPrank(buyer1);
        tok.approve(address(r), 100e18);
        r.buyTickets(100, address(0));
        vm.stopPrank();

        _settle(r);
        assertTrue(r.succeeded());
        vm.prank(seller);
        r.withdrawSeller();
        r.withdrawFee();
        assertEq(tok.balanceOf(feeRecipient), 2e18);
        assertEq(tok.balanceOf(seller), 98e18);
        _claimAllPrizes(r);
        assertEq(tok.balanceOf(address(r)), 0);
    }

    /*====================================================================
        9. GAS  (M-04 / R-14, R-28)
    ====================================================================*/

    function _gasBuy(Raffle r, uint256 n) internal returns (uint256 used) {
        uint256 g = gasleft();
        r.buyTickets(n, address(0));
        used = g - gasleft();
    }

    /// ACCEPTED, MEASURED, NOT FIXED. buyTickets still does one SSTORE to a fresh slot per ticket
    /// (ticketHolders.push). MAX_TICKETS_PER_ADDRESS is GONE, so the practical ceiling is no
    /// longer a contract constant at all: it is purely the block gas limit. Recorded so the
    /// number is tracked rather than assumed.
    function test_Accepted_Gas_BuyTicketsPerTicketSSTORE() public {
        MockERC20 asset = new MockERC20("Asset", "AST");
        MockERC20 pay = new MockERC20("Pay", "PAY");
        asset.mint(seller, 2 * ASSET_AMOUNT);
        vm.prank(seller);
        asset.approve(address(factory), 2 * ASSET_AMOUNT);
        Raffle a = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, 10_000, WINNERS_COUNT, seller);
        Raffle b = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, 10_000, WINNERS_COUNT, seller);

        pay.mint(buyer1, 20_000e18);
        vm.startPrank(buyer1);
        pay.approve(address(a), type(uint256).max);
        pay.approve(address(b), type(uint256).max);
        uint256 g100 = _gasBuy(a, 100);
        uint256 g1000 = _gasBuy(a, 1000);
        uint256 g10000 = _gasBuy(b, 10_000);
        vm.stopPrank();

        uint256 perTicket = (g1000 - g100) / 900;
        uint256 base = g100 - 100 * perTicket;
        console2.log("buyTickets gas  n=100    :", g100);
        console2.log("buyTickets gas  n=1000   :", g1000);
        console2.log("buyTickets gas  n=10000  :", g10000);
        console2.log("marginal gas per ticket  :", perTicket);
        console2.log("max n in a 30M block     :", (30_000_000 - base) / perTicket);
        console2.log("max n in a 100M block    :", (100_000_000 - base) / perTicket);
        // There is no per-address cap left to be unreachable; the block is the only limit.
        assertGt(g10000, 30_000_000, "10k tickets in one tx does not fit an L1 block");
        assertGt(g10000, 100_000_000, "nor a 100M block");
        // No per-address limit exists any more: one address really can hold every ticket.
        assertEq(b.tickets(buyer1), 10_000);
    }

    /// R-28: the old blockhash draw inside finalize() cost about 9.0 to 12.4 M gas at 200 winners,
    /// which put a 200-winner raffle out of reach on lower-gas-limit chains. The draw is now a
    /// separate transaction from a single seed, using partial Fisher-Yates, and MAX_WINNERS_COUNT
    /// was cut to keep it inside a block. The cap is READ FROM THE CONTRACT here, so that lifting
    /// it later cannot silently push the draw past a block limit without failing this test.
    function test_NotExploitable_Gas_DrawMaxWinners() public {
        MockERC20 asset = new MockERC20("Asset", "AST");
        MockERC20 pay = new MockERC20("Pay", "PAY");
        asset.mint(seller, 2 * ASSET_AMOUNT);
        vm.prank(seller);
        asset.approve(address(factory), 2 * ASSET_AMOUNT);

        uint256 maxWinners = Raffle(factory.RAFFLE_IMPLEMENTATION()).MAX_WINNERS_COUNT();
        console2.log("MAX_WINNERS_COUNT                        :", maxWinners);

        // A: smallest possible ticket pool for a full winner set (every ticket wins)
        Raffle a =
            _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, maxWinners, uint16(maxWinners), seller);
        _buy(a, buyer1, maxWinners);
        _end(a);
        uint256 g = gasleft();
        a.finalize();
        uint256 gFinA = g - gasleft();
        g = gasleft();
        a.drawWinners();
        uint256 gDrawA = g - gasleft();

        // B: large ticket pool, so every drawn swap slot is a cold, fresh SSTORE
        Raffle b = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, 10_000, uint16(maxWinners), seller);
        _buy(b, buyer1, 10_000);
        _end(b);
        g = gasleft();
        b.finalize();
        uint256 gFinB = g - gasleft();
        g = gasleft();
        b.drawWinners();
        uint256 gDrawB = g - gasleft();

        // claimPrize no longer scans the winners array: it reads one mapping slot.
        address w = a.getWinners()[0];
        vm.prank(w);
        g = gasleft();
        a.claimPrize();
        uint256 gClaim = g - gasleft();

        console2.log("finalize gas    (max-winner pool)         :", gFinA);
        console2.log("drawWinners gas, MAX winners / MAX tickets:", gDrawA);
        console2.log("finalize gas    (10000 tickets)           :", gFinB);
        console2.log("drawWinners gas, MAX winners / 10k tickets:", gDrawB);
        console2.log("unique winners A / B :", _unique(a.getWinners()).length, _unique(b.getWinners()).length);
        console2.log("claimPrize gas at MAX winners             :", gClaim);

        // The draw cost is dominated by STORAGE, not hashing: one `winners.push` plus up to one
        // fresh `_swap` slot per winner. The wider the ticket pool, the more of those swap slots
        // are cold, which is why B costs more than A. That is why the winner cap matters.
        assertLt(gDrawA, 20_000_000, "draw must stay well inside a block");
        assertLt(gDrawB, 20_000_000, "draw must stay well inside a block");
        // What got dramatically cheaper: finalize() is now trivial, so the expensive half is
        // isolated in its own transaction and can be retried independently of settlement.
        assertLt(gFinA, 200_000, "finalize no longer draws");
        assertLt(gFinB, 200_000);
        // And claimPrize reads one mapping slot instead of scanning the winners array (was ~164 k).
        assertLt(gClaim, 100_000, "claimPrize no longer scans the winners array");
        // Every winner is a distinct ticket now, so a full draw over an equal pool covers all.
        assertEq(a.getWinners().length, maxWinners);

        // The cap is enforced: one winner more is refused at creation.
        _assertWinnerCapEnforced(asset, pay, maxWinners);
    }

    /// @dev Split out of the gas test purely to stay inside the stack limit.
    function _assertWinnerCapEnforced(MockERC20 asset, MockERC20 pay, uint256 maxWinners) internal {
        asset.mint(seller, ASSET_AMOUNT);
        vm.startPrank(seller);
        asset.approve(address(factory), ASSET_AMOUNT);
        vm.expectRevert("Raffle: winners count too high");
        factory.createRaffle(
            address(0),
            address(asset),
            ASSET_AMOUNT,
            address(pay),
            TICKET_PRICE,
            10_000,
            TICKET_PRICE * 10_000,
            block.timestamp,
            block.timestamp + 7 days,
            uint16(maxWinners + 1)
        );
        vm.stopPrank();
    }

    /*====================================================================
        10. STUCK FUNDS / NO SWEEP / REMAINDER
    ====================================================================*/

    /// R-19: accidentally transferred tokens used to be unrecoverable by anyone. recoverToken()
    /// now exists for the seller - but it can never reach the two escrowed tokens, in any state.
    function test_Fixed_NoSweep_StrandedTokens() public {
        MockERC20 asset = _stdAsset();
        MockERC20 pay = new MockERC20("Pay", "PAY");
        Raffle r = _create(address(asset), ASSET_AMOUNT, address(pay), TICKET_PRICE, TICKET_CAP, WINNERS_COUNT, seller);
        _sellOut(r);
        _settle(r);
        vm.prank(seller);
        r.withdrawSeller();
        r.withdrawFee();
        _claimAllPrizes(r);
        assertEq(pay.balanceOf(address(r)), 0);
        assertEq(asset.balanceOf(address(r)), 0);

        // A third token sent here by mistake CAN now be rescued, by the seller only.
        MockERC20 stray = new MockERC20("Stray", "STRAY");
        stray.mint(address(r), 7e18);
        vm.prank(buyer1);
        vm.expectRevert("Raffle: not seller");
        r.recoverToken(address(stray), buyer1);
        vm.prank(seller);
        vm.expectRevert("Raffle: invalid recipient");
        r.recoverToken(address(stray), address(0));
        vm.prank(seller);
        r.recoverToken(address(stray), seller);
        assertEq(stray.balanceOf(seller), 7e18, "stranded token rescued");
        vm.prank(seller);
        vm.expectRevert("Raffle: nothing to recover");
        r.recoverToken(address(stray), seller);

        // The two escrowed tokens stay protected, so a sweep can never reach a liability.
        // Dust in them is still stranded, deliberately.
        pay.mint(address(r), 5e18);
        asset.mint(address(r), 7e18);
        vm.prank(seller);
        vm.expectRevert("Raffle: protected token");
        r.recoverToken(address(pay), seller);
        vm.prank(seller);
        vm.expectRevert("Raffle: protected token");
        r.recoverToken(address(asset), seller);
        assertEq(pay.balanceOf(address(r)), 5e18);
        assertEq(asset.balanceOf(address(r)), 7e18);
    }

    /// assetAmount % winnersCount is handed to the first `remainder` winners: nothing is lost.
    function test_NotExploitable_PrizeRemainderFullyDistributed() public {
        MockERC20 asset = new MockERC20("Asset", "AST");
        MockERC20 pay = new MockERC20("Pay", "PAY");
        asset.mint(seller, 10);
        vm.prank(seller);
        asset.approve(address(factory), 10);
        Raffle r = _create(address(asset), 10, address(pay), TICKET_PRICE, 3, 3, seller);
        _buy(r, buyer1, 3);
        _settle(r);
        address[] memory w = _unique(r.getWinners());
        uint256 credited;
        for (uint256 i = 0; i < w.length; i++) {
            credited += r.pendingPrize(w[i]);
        }
        assertEq(credited, 10, "4+3+3");
        _claimAllPrizes(r);
        assertEq(asset.balanceOf(address(r)), 0);
    }

    /*====================================================================
        11. ALLOWANCE HIJACK VIA ARBITRARY `raffleSeller`  (R-03)
    ====================================================================*/

    /// createRaffle used to pull `assetAmount` from `raffleSeller` with no authorisation from
    /// that address, so any standing allowance to the factory could be raffled off by a stranger
    /// on their own terms. The seller must now be the caller.
    function test_Fixed_ArbitrarySellerAllowanceHijack() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        MockERC20 asset = new MockERC20("Asset", "AST");
        asset.mint(alice, ASSET_AMOUNT);
        vm.prank(alice);
        asset.approve(address(factory), type(uint256).max); // standing / infinite approval

        MockERC20 junk = new MockERC20("Junk", "JUNK");
        junk.mint(bob, 1);

        vm.prank(bob);
        vm.expectRevert(RaffleFactory.SellerMustBeCaller.selector);
        factory.createRaffle(
            alice,
            address(asset),
            ASSET_AMOUNT,
            address(junk),
            1,
            1,
            1,
            block.timestamp,
            block.timestamp + 10 minutes,
            1
        );

        assertEq(asset.balanceOf(alice), ASSET_AMOUNT, "alice's 1000e18 stayed put");
        assertEq(asset.allowance(alice, address(factory)), type(uint256).max, "allowance untouched");
        assertEq(factory.getRaffleCount(), 0, "no raffle in alice's name");

        // address(0) means "me", so Bob can create raffles - but only with his own tokens.
        asset.mint(bob, 5e18);
        vm.startPrank(bob);
        asset.approve(address(factory), 5e18);
        Raffle own = Raffle(
            factory.createRaffle(
                address(0),
                address(asset),
                5e18,
                address(junk),
                1,
                1,
                1,
                block.timestamp,
                block.timestamp + 10 minutes,
                1
            )
        );
        vm.stopPrank();
        assertEq(own.seller(), bob, "the prize always comes from the caller");
        assertEq(asset.balanceOf(bob), 0);
        assertEq(asset.balanceOf(alice), ASSET_AMOUNT);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                    12. STATEFUL-FUZZ SOLVENCY INVARIANTS

    These two invariants are the point of this file. They previously FAILED,
    shrinking to (buy, refund) and (buy, withdrawAsset) - R-01 and R-02. They
    must now hold across the whole lifecycle, including the two-step settlement
    and both escape hatches.
//////////////////////////////////////////////////////////////////////////*/

contract RaffleHandler is CommonBase, StdCheats, StdUtils {
    Raffle public raffle;
    MockERC20 public asset;
    MockERC20 public pay;
    MockRandomnessProvider public provider;
    address public seller;
    address[] public actors;

    uint256 public constant PRICE = 1e18;
    uint256 public constant CAP = 5;

    constructor(Raffle r, MockERC20 a, MockERC20 p, MockRandomnessProvider prov, address s) {
        raffle = r;
        asset = a;
        pay = p;
        provider = prov;
        seller = s;
        actors.push(address(0xA1));
        actors.push(address(0xA2));
        actors.push(address(0xA3));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function buy(uint256 actorSeed, uint256 n) external {
        address a = actors[actorSeed % actors.length];
        if (raffle.state() != Raffle.State.Active) return;
        if (block.timestamp < raffle.startTime() || block.timestamp >= raffle.endTime()) return;
        uint256 remaining = CAP - raffle.totalTickets();
        if (remaining == 0) return;
        n = bound(n, 1, remaining);
        pay.mint(a, n * PRICE);
        vm.startPrank(a);
        pay.approve(address(raffle), n * PRICE);
        raffle.buyTickets(n, address(0));
        vm.stopPrank();
    }

    function refund(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        vm.prank(a);
        try raffle.claimRefund() {} catch {}
    }

    function claimPrize(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        vm.prank(a);
        try raffle.claimPrize() {} catch {}
    }

    function withdrawSeller() external {
        vm.prank(seller);
        try raffle.withdrawSeller() {} catch {}
    }

    function withdrawAsset() external {
        vm.prank(seller);
        try raffle.withdrawAsset() {} catch {}
    }

    function withdrawFee() external {
        try raffle.withdrawFee() {} catch {}
    }

    function finalize() external {
        try raffle.finalize() {} catch {}
    }

    function drawWinners() external {
        try raffle.drawWinners() {} catch {}
    }

    /// @dev The oracle answers only when the fuzzer decides it does, so BOTH branches out of
    ///      RandomnessPending are reachable: drawWinners after a seed, failOnTimeout without one.
    function deliverSeed(uint256 s) external {
        if (raffle.state() != Raffle.State.RandomnessPending) return;
        provider.fulfill(raffle.randomnessRequestId(), bound(s, 1, type(uint256).max));
    }

    function failOnTimeout() external {
        try raffle.failOnTimeout() {} catch {}
    }

    function failIfAbandoned() external {
        try raffle.failIfAbandoned() {} catch {}
    }

    function cancel() external {
        vm.prank(seller);
        try raffle.cancel() {} catch {}
    }

    function recoverToken(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        vm.prank(seller);
        try raffle.recoverToken(address(pay), a) {} catch {}
        vm.prank(seller);
        try raffle.recoverToken(address(asset), a) {} catch {}
    }

    /// @dev Wide enough to reach both escape hatches: RANDOMNESS_TIMEOUT (1 day) and
    ///      FINALIZE_GRACE (30 days past endTime).
    function warp(uint256 secs) external {
        secs = bound(secs, 1 hours, 5 days);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12);
    }
}

contract TokensInvariantTest is StdInvariant, Test {
    RaffleFactory public factory;
    MockRandomnessProvider public provider;
    Raffle public raffle;
    MockERC20 public asset;
    MockERC20 public pay;
    RaffleHandler public handler;

    address public seller = address(0x1);
    address public feeRecipient = address(0x5);
    uint256 public constant ASSET_AMOUNT = 1000e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.roll(1_000);
        asset = new MockERC20("Asset", "AST");
        pay = new MockERC20("Pay", "PAY");
        provider = new MockRandomnessProvider();
        // Deliberately NO autoSeed: the handler decides whether the oracle ever answers.
        factory = new RaffleFactory(address(this), feeRecipient, 200, address(provider));
        asset.mint(seller, ASSET_AMOUNT);
        vm.startPrank(seller);
        asset.approve(address(factory), ASSET_AMOUNT);
        raffle = Raffle(
            factory.createRaffle(
                address(0),
                address(asset),
                ASSET_AMOUNT,
                address(pay),
                1e18,
                5,
                5e18,
                block.timestamp,
                block.timestamp + 3 days,
                2
            )
        );
        vm.stopPrank();
        handler = new RaffleHandler(raffle, asset, pay, provider, seller);
        targetContract(address(handler));
    }

    /// paymentToken.balanceOf(raffle) >= unrefunded tickets + sellerProceeds + protocolFeeOwed.
    /// Tickets are a refund liability only while the raffle has not succeeded; once it has,
    /// sellerProceeds + protocolFeeOwed account for every wei that was ever paid in.
    function invariant_PaymentSolvency() public view {
        uint256 bal = pay.balanceOf(address(raffle));
        uint256 liability = raffle.sellerProceeds() + raffle.protocolFeeOwed();
        if (raffle.state() != Raffle.State.Succeeded) {
            uint256 n = handler.actorCount();
            for (uint256 i = 0; i < n; i++) {
                liability += raffle.tickets(handler.actors(i)) * handler.PRICE();
            }
        }
        assertGe(bal, liability, "PAYMENT INSOLVENT: balance < tickets + sellerProceeds + protocolFeeOwed");
    }

    /// assetToken.balanceOf(raffle) >= sum(pendingPrize) + the escrowed prize whenever the seller
    /// has not (yet) taken it back and the raffle has not paid it out as prizes.
    function invariant_AssetSolvency() public view {
        uint256 bal = asset.balanceOf(address(raffle));
        uint256 liability;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            liability += raffle.pendingPrize(handler.actors(i));
        }

        Raffle.State s = raffle.state();
        bool prizeStillEscrowed = !raffle.assetWithdrawnBySeller() && s != Raffle.State.Succeeded;
        if (prizeStillEscrowed) liability += raffle.assetAmount();

        assertGe(bal, liability, "ASSET INSOLVENT: balance < pendingPrize + un-withdrawn escrow");
    }
}
