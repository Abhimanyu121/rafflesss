// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
    FORK TEST — the provider against the REAL Chainlink VRF v2.5 coordinator
    deployed on Base Sepolia.

    Everything else in this repo tests our Chainlink integration against a mock we
    wrote ourselves, which can only ever confirm that we agree with us.
    `test/audit/VRFConformance.t.sol` narrows that by pinning our wire format against
    Chainlink's published source, but published source is still not deployed bytecode.
    This is the only test where the other side of the call is Chainlink's.

    Requires network access:
        forge test --match-path 'test/fork/*' -vv
    It is skipped automatically when BASE_SEPOLIA_RPC_URL is unset, so the offline
    suite stays deterministic.
//////////////////////////////////////////////////////////////////////////*/

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../../src/Raffle.sol";
import {RaffleFactory} from "../../src/RaffleFactory.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {ChainlinkVRFProvider} from "../../src/randomness/ChainlinkVRFProvider.sol";

/// @dev Chainlink's subscription-management surface, used only to stand up a funded
///      subscription on the fork the way a real operator would.
interface IVRFSubscription {
    function createSubscription() external returns (uint256 subId);
    function addConsumer(uint256 subId, address consumer) external;
    function fundSubscriptionWithNative(uint256 subId) external payable;
    function pendingRequestExists(uint256 subId) external view returns (bool);
    function getSubscription(uint256 subId)
        external
        view
        returns (uint96 balance, uint96 nativeBalance, uint64 reqCount, address owner, address[] memory consumers);
}

contract VRFBaseSepoliaForkTest is Test {
    /// docs.chain.link/vrf/v2-5/supported-networks, Base Sepolia.
    address internal constant COORDINATOR = 0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE;
    bytes32 internal constant KEY_HASH_30_GWEI = 0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71;

    bool internal skipped;

    IVRFSubscription internal coordinator = IVRFSubscription(COORDINATOR);
    ChainlinkVRFProvider internal provider;
    RaffleFactory internal factory;
    MockERC20 internal asset;
    MockERC20 internal pay;
    uint256 internal subId;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        string memory url = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            skipped = true;
            return;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, 84532, "not Base Sepolia");
        assertGt(COORDINATOR.code.length, 0, "coordinator has no code at the documented address");

        // Stand up a subscription exactly as an operator would: create, add the consumer,
        // fund it. This test contract is the subscription owner.
        vm.deal(address(this), 10 ether);
        subId = coordinator.createSubscription();

        provider = new ChainlinkVRFProvider(
            address(this),
            COORDINATOR,
            KEY_HASH_30_GWEI,
            subId,
            3,
            200_000,
            true /* pay in native */
        );
        coordinator.addConsumer(subId, address(provider));
        coordinator.fundSubscriptionWithNative{value: 1 ether}(subId);

        factory = new RaffleFactory(address(this), feeRecipient, 200, address(provider));
        provider.setFactory(address(factory));

        asset = new MockERC20("Wrapped Ether", "WETH");
        pay = new MockERC20("USD Coin", "USDC");
    }

    /// The assertion the whole suite was missing: a request built by our contract, with our
    /// locally declared struct and our hand-rolled `extraArgs`, accepted by the coordinator
    /// Chainlink actually deployed. A wrong field order, a wrong tag or a rejected gas lane all
    /// revert here and nowhere else.
    function test_Fork_RealCoordinatorAcceptsOurRequest() public {
        if (skipped) return _skip();

        Raffle r = _soldOutRaffle();
        vm.warp(r.endTime());
        r.finalize();

        assertEq(uint8(r.state()), uint8(Raffle.State.RandomnessPending), "settlement moved on");
        bytes32 requestId = r.randomnessRequestId();
        assertTrue(requestId != bytes32(0), "coordinator returned a request id");
        assertEq(provider.requestedBy(requestId), address(r), "request attributed to the raffle");
        assertTrue(coordinator.pendingRequestExists(subId), "coordinator has the request queued");

        // Not yet answerable: the seed comes from Chainlink's offchain nodes, which do not run
        // against a fork. Everything up to that boundary is now proven against real bytecode.
        assertEq(provider.getRandomness(requestId), 0, "no seed yet, as expected on a fork");
        assertFalse(r.canDraw());
    }

    /// `script/SetupProvider.s.sol` reads the subscription through a low-level call and decodes
    /// the result by hand, which is the one place a coordinator ABI mismatch would pass silently
    /// rather than revert. Checked here against the real contract.
    function test_Fork_SetupProviderSubscriptionCheckDecodesCorrectly() public {
        if (skipped) return _skip();

        (bool ok, bytes memory data) =
            COORDINATOR.staticcall(abi.encodeWithSignature("getSubscription(uint256)", subId));
        assertTrue(ok, "getSubscription reverted");
        assertGe(data.length, 160, "return data shorter than the script's guard allows");

        (uint96 balance, uint96 nativeBalance,, address subOwner, address[] memory consumers) =
            abi.decode(data, (uint96, uint96, uint64, address, address[]));

        assertEq(subOwner, address(this), "decoded owner");
        assertEq(balance, 0, "funded in native, so the LINK balance is zero");
        assertEq(nativeBalance, 1 ether, "decoded native balance");
        assertEq(consumers.length, 1, "decoded consumer list");
        assertEq(consumers[0], address(provider), "provider is the registered consumer");
    }

    /// The real coordinator DOES validate the subscription: an id it does not know reverts at
    /// request time, so `finalize()` reverts and the raffle never leaves `Active`. The
    /// abandonment hatch releases it after the finalize grace period.
    function test_Fork_UnknownSubscriptionIsRejectedByTheRealCoordinator() public {
        if (skipped) return _skip();

        provider.setRequestConfig(KEY_HASH_30_GWEI, subId + 999_999, 3, 200_000, true);
        Raffle r = _soldOutRaffle();
        vm.warp(r.endTime());

        vm.expectRevert();
        r.finalize();
        assertEq(uint8(r.state()), uint8(Raffle.State.Active), "raffle untouched by the failure");

        vm.warp(r.endTime() + r.FINALIZE_GRACE() + 1);
        r.failIfAbandoned();
        vm.prank(bob);
        r.claimRefund();
        assertEq(pay.balanceOf(bob), 10e18, "buyer made whole against real bytecode");
    }

    /// The real coordinator does NOT validate the gas lane. A key hash no node serves is accepted
    /// on-chain and simply never answered, so the failure is silent rather than loud: the raffle
    /// sits in `RandomnessPending` with a request id that will never be fulfilled.
    ///
    /// This corrects an assumption made before this test existed — that a wrong key hash would
    /// make `finalize()` revert. It does not, and the two failure modes need different hatches:
    /// a rejected subscription leaves the raffle `Active` and needs `failIfAbandoned()` after the
    /// finalize grace, while an unserved gas lane leaves it `RandomnessPending` and is released
    /// by `failOnTimeout()` after one day. Both refund; neither locks.
    function test_Fork_UnservedGasLaneIsAcceptedThenNeverAnswered() public {
        if (skipped) return _skip();

        provider.setRequestConfig(bytes32("not a real gas lane"), subId, 3, 200_000, true);
        Raffle r = _soldOutRaffle();
        vm.warp(r.endTime());

        r.finalize(); // accepted on-chain, to nobody's benefit
        assertEq(uint8(r.state()), uint8(Raffle.State.RandomnessPending), "request was accepted");
        assertTrue(coordinator.pendingRequestExists(subId), "and queued, forever");

        bytes32 requestId = r.randomnessRequestId();
        assertEq(provider.getRandomness(requestId), 0, "no node will serve this lane");
        assertFalse(r.canDraw());

        // The randomness timeout, not the abandonment hatch, is what releases this one.
        vm.warp(block.timestamp + r.RANDOMNESS_TIMEOUT() + 1);
        r.failOnTimeout();
        assertTrue(r.hasFailed());

        vm.prank(bob);
        r.claimRefund();
        assertEq(pay.balanceOf(bob), 10e18, "buyer made whole");
        vm.prank(alice);
        r.withdrawAsset();
        assertEq(asset.balanceOf(alice), 900e18, "seller made whole");
    }

    // ------------------------------------------------------------------ helpers

    function _skip() internal {
        emit log("SKIPPED: set BASE_SEPOLIA_RPC_URL to run the fork tests");
        vm.skip(true);
    }

    function _soldOutRaffle() internal returns (Raffle r) {
        asset.mint(alice, 900e18);
        vm.startPrank(alice);
        asset.approve(address(factory), 900e18);
        r = Raffle(
            factory.createRaffle(
                address(0),
                address(asset),
                900e18,
                address(pay),
                1e18,
                10,
                10e18,
                block.timestamp + 1,
                block.timestamp + 7 days,
                3
            )
        );
        vm.stopPrank();
        vm.warp(block.timestamp + 1);

        pay.mint(bob, 10e18);
        vm.startPrank(bob);
        pay.approve(address(r), 10e18);
        r.buyTickets(10, address(0));
        vm.stopPrank();
    }
}
