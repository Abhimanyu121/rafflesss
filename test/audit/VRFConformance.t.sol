// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
    CONFORMANCE SUITE — src/randomness/ChainlinkVRFProvider.sol against the
    real Chainlink VRF v2.5 ABI.

    This repo does not vendor @chainlink/contracts; the coordinator interface is
    declared locally. That is cheap, but it means nothing here would notice if the
    declaration drifted from Chainlink's — the mocks would keep agreeing with us and
    the first failure would be on-chain, where a rejected request stalls every raffle.

    These tests pin our wire format against the published source, verbatim as of
    2026-09-07, so drift fails here instead:

      VRFV2PlusClient.sol        RandomWordsRequest { bytes32 keyHash; uint256 subId;
                                  uint16 requestConfirmations; uint32 callbackGasLimit;
                                  uint32 numWords; bytes extraArgs; }
                                EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"))
                                _argsToBytes = abi.encodeWithSelector(TAG, extraArgs)
      IVRFCoordinatorV2Plus.sol requestRandomWords(RandomWordsRequest calldata)
                                  external returns (uint256)
      VRFConsumerBaseV2Plus.sol rawFulfillRandomWords(uint256, uint256[] calldata) external

    Source: github.com/smartcontractkit/chainlink-brownie-contracts,
    contracts/src/v0.8/vrf/dev/
//////////////////////////////////////////////////////////////////////////*/

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../../src/Raffle.sol";
import {RaffleFactory} from "../../src/RaffleFactory.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {ChainlinkVRFProvider, IVRFCoordinatorV2Plus} from "../../src/randomness/ChainlinkVRFProvider.sol";

/// @dev Records exactly what the provider put on the wire.
contract RecordingCoordinator {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    uint256 public nextId = 1;

    bytes public lastCalldata;
    bytes public lastExtraArgs;
    bytes32 public lastKeyHash;
    uint256 public lastSubId;
    uint16 public lastConfirmations;
    uint32 public lastCallbackGas;
    uint32 public lastNumWords;

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId) {
        lastCalldata = msg.data;
        lastKeyHash = req.keyHash;
        lastSubId = req.subId;
        lastConfirmations = req.requestConfirmations;
        lastCallbackGas = req.callbackGasLimit;
        lastNumWords = req.numWords;
        lastExtraArgs = req.extraArgs;
        requestId = nextId++;
    }
}

contract VRFConformanceTest is Test {
    /// Chainlink's published limits for Base (mainnet and Sepolia), from
    /// docs.chain.link/vrf/v2-5/supported-networks.
    uint32 internal constant CHAINLINK_MAX_CALLBACK_GAS = 2_500_000;
    uint16 internal constant CHAINLINK_MAX_CONFIRMATIONS = 200;

    bytes32 internal constant KEY_HASH = 0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71;
    uint256 internal constant SUB_ID = 42;
    uint16 internal constant CONFIRMATIONS = 3;
    uint32 internal constant CALLBACK_GAS = 200_000;

    RecordingCoordinator internal coordinator;
    ChainlinkVRFProvider internal vrf;
    RaffleFactory internal factory;
    MockERC20 internal asset;
    MockERC20 internal pay;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_700_000_000);
        coordinator = new RecordingCoordinator();
        vrf =
            new ChainlinkVRFProvider(owner, address(coordinator), KEY_HASH, SUB_ID, CONFIRMATIONS, CALLBACK_GAS, false);
        factory = new RaffleFactory(owner, feeRecipient, 200, address(vrf));
        vm.prank(owner);
        vrf.setFactory(address(factory));
        asset = new MockERC20("Wrapped Ether", "WETH");
        pay = new MockERC20("USD Coin", "USDC");
    }

    function _soldOutRaffle(uint256 cap, uint16 winners) internal returns (Raffle r) {
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
                cap,
                1e18 * cap,
                block.timestamp + 1,
                block.timestamp + 7 days,
                winners
            )
        );
        vm.stopPrank();
        vm.warp(block.timestamp + 1);

        pay.mint(bob, 1e18 * cap);
        vm.startPrank(bob);
        pay.approve(address(r), 1e18 * cap);
        r.buyTickets(cap, address(0));
        vm.stopPrank();
        vm.warp(r.endTime());
    }

    // ------------------------------------------------------------------ ABI shape

    /// The struct's field order and types are what produce the selector. Reorder a field or
    /// widen a type and this fails, which is the whole point: on-chain, the coordinator would
    /// simply reject the call and every raffle would stall until the abandonment hatch.
    function test_Conformance_RequestSelectorMatchesChainlink() public pure {
        assertEq(
            IVRFCoordinatorV2Plus.requestRandomWords.selector,
            bytes4(keccak256("requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))")),
            "local RandomWordsRequest no longer matches VRFV2PlusClient"
        );
    }

    /// The coordinator fulfils by calling this exact selector on us.
    function test_Conformance_CallbackSelectorMatchesChainlink() public pure {
        assertEq(
            ChainlinkVRFProvider.rawFulfillRandomWords.selector,
            bytes4(keccak256("rawFulfillRandomWords(uint256,uint256[])")),
            "callback signature no longer matches VRFConsumerBaseV2Plus"
        );
    }

    /// Every field the provider sends, checked against the config it was given.
    function test_Conformance_RequestCarriesTheConfiguredFields() public {
        Raffle r = _soldOutRaffle(10, 3);
        r.finalize();

        assertEq(bytes4(coordinator.lastCalldata()), IVRFCoordinatorV2Plus.requestRandomWords.selector);
        assertEq(coordinator.lastKeyHash(), KEY_HASH, "key hash");
        assertEq(coordinator.lastSubId(), SUB_ID, "subscription id");
        assertEq(coordinator.lastConfirmations(), CONFIRMATIONS, "confirmations");
        assertEq(coordinator.lastCallbackGas(), CALLBACK_GAS, "callback gas");
        assertEq(coordinator.lastNumWords(), 1, "one word: the draw derives every pick from it");
        assertLe(coordinator.lastConfirmations(), CHAINLINK_MAX_CONFIRMATIONS, "above Chainlink's max");
        assertLe(coordinator.lastCallbackGas(), CHAINLINK_MAX_CALLBACK_GAS, "above Chainlink's max");
    }

    /// `extraArgs` is the one field with a hand-rolled encoding, so it is checked on the wire
    /// against VRFV2PlusClient._argsToBytes rather than against our own constant.
    function test_Conformance_ExtraArgsEncodingMatchesChainlink() public {
        bytes4 tag = bytes4(keccak256("VRF ExtraArgsV1"));

        Raffle r = _soldOutRaffle(10, 3);
        r.finalize();
        assertEq(coordinator.lastExtraArgs(), abi.encodeWithSelector(tag, false), "LINK payment encoding");

        vm.prank(owner);
        vrf.setRequestConfig(KEY_HASH, SUB_ID, CONFIRMATIONS, CALLBACK_GAS, true);
        Raffle r2 = _soldOutRaffle(10, 3);
        r2.finalize();
        assertEq(coordinator.lastExtraArgs(), abi.encodeWithSelector(tag, true), "native payment encoding");
    }

    // ------------------------------------------------------------------ callback gas

    /// Chainlink security consideration 2: confirmations are what make a validator re-roll
    /// uneconomic. Base allows a consumer to request zero of them, which for a raffle would be a
    /// mistake nobody could undo for requests already in flight, so the provider sets a floor.
    function test_Conformance_RequestConfirmationsHaveAFloor() public {
        vm.expectRevert(ChainlinkVRFProvider.TooFewConfirmations.selector);
        new ChainlinkVRFProvider(owner, address(coordinator), KEY_HASH, SUB_ID, 0, CALLBACK_GAS, false);

        vm.prank(owner);
        vm.expectRevert(ChainlinkVRFProvider.TooFewConfirmations.selector);
        vrf.setRequestConfig(KEY_HASH, SUB_ID, 2, CALLBACK_GAS, false);

        uint16 floor = vrf.MIN_REQUEST_CONFIRMATIONS();
        vm.prank(owner);
        vrf.setRequestConfig(KEY_HASH, SUB_ID, floor, CALLBACK_GAS, false);
        assertEq(vrf.requestConfirmations(), floor);
        assertLe(floor, CHAINLINK_MAX_CONFIRMATIONS, "floor must be settable everywhere");
    }

    // ------------------------------------------------------------------ security considerations

    /// Chainlink security consideration 4: record user actions, stop accepting input, THEN
    /// request randomness. Ticket sales close at the deadline, and the request happens after
    /// that, in a state where buying is rejected outright.
    function test_Conformance_NoInputIsAcceptedAfterTheRequest() public {
        Raffle r = _soldOutRaffle(10, 3);
        r.finalize();
        assertEq(uint8(r.state()), uint8(Raffle.State.RandomnessPending));

        pay.mint(bob, 1e18);
        vm.startPrank(bob);
        pay.approve(address(r), 1e18);
        vm.expectRevert(bytes("Raffle: not active"));
        r.buyTickets(1, address(0));
        vm.stopPrank();
    }

    /// Chainlink security consideration 3: no re-requesting. One raffle asks once, and a seed
    /// that has arrived must be drawn rather than discarded — the timeout refuses to fire while
    /// an answer is sitting there, so the outcome cannot depend on who calls first.
    function test_Conformance_RandomnessCannotBeReRequestedOrDiscarded() public {
        Raffle r = _soldOutRaffle(10, 3);
        r.finalize();
        uint256 id = uint256(r.randomnessRequestId());

        // No second request.
        vm.expectRevert(bytes("Raffle: not active"));
        r.finalize();

        uint256[] memory word = new uint256[](1);
        word[0] = uint256(keccak256("unfavourable"));
        vm.prank(address(coordinator));
        vrf.rawFulfillRandomWords(id, word);

        // The seed has landed, so the escape hatch refuses to void it.
        vm.warp(block.timestamp + r.RANDOMNESS_TIMEOUT() + 1);
        vm.expectRevert(bytes("Raffle: randomness arrived, draw instead"));
        r.failOnTimeout();

        r.drawWinners();
        assertTrue(r.succeeded());
    }

    /// Chainlink security consideration 1: fulfilments can arrive in any order, so each raffle
    /// keys off its own request id rather than "the last seed seen". Delivered deliberately
    /// backwards here.
    function test_Conformance_ConcurrentRafflesTrackTheirOwnRequestIds() public {
        Raffle a = _soldOutRaffle(10, 3);
        a.finalize();
        Raffle b = _soldOutRaffle(10, 3);
        b.finalize();

        uint256 idA = uint256(a.randomnessRequestId());
        uint256 idB = uint256(b.randomnessRequestId());
        assertTrue(idA != idB, "each raffle gets its own request");

        uint256[] memory wordB = new uint256[](1);
        wordB[0] = uint256(keccak256("B"));
        uint256[] memory wordA = new uint256[](1);
        wordA[0] = uint256(keccak256("A"));

        // Out of order: B answered first.
        vm.startPrank(address(coordinator));
        vrf.rawFulfillRandomWords(idB, wordB);
        vrf.rawFulfillRandomWords(idA, wordA);
        vm.stopPrank();

        b.drawWinners();
        a.drawWinners();
        assertEq(a.seed(), wordA[0], "A drew A's seed");
        assertEq(b.seed(), wordB[0], "B drew B's seed");
    }

    /// Chainlink security consideration 3, the deliberate deviation. Past `DRAW_DEADLINE` the
    /// timeout fires even if a seed did arrive, which is technically a way to discard an
    /// unfavourable outcome. It is kept because the alternative is worse: without it, a draw that
    /// could never execute would strand every participant permanently, which is the exact class
    /// of bug this rewrite exists to remove. The cost of the deviation is bounded — the raffle is
    /// voided, not stolen from, so buyers are refunded and the seller gets the prize back — and
    /// exercising it needs 30 days in which any of up to 100 winners could have called the
    /// permissionless `drawWinners()`. Recorded rather than hidden.
    function test_Accepted_ArrivedSeedCanBeVoidedAfterTheDrawDeadline() public {
        Raffle r = _soldOutRaffle(10, 3);
        r.finalize();
        uint256 id = uint256(r.randomnessRequestId());

        uint256[] memory word = new uint256[](1);
        word[0] = uint256(keccak256("unfavourable"));
        vm.prank(address(coordinator));
        vrf.rawFulfillRandomWords(id, word);

        vm.warp(block.timestamp + r.DRAW_DEADLINE() + 1);
        r.failOnTimeout();
        assertTrue(r.hasFailed(), "seed voided after the deadline");
        assertEq(r.getWinners().length, 0, "nobody won");

        // Nobody is out of pocket: the raffle is undone, not looted.
        vm.prank(bob);
        r.claimRefund();
        assertEq(pay.balanceOf(bob), 10e18, "buyer refunded in full");
        vm.prank(alice);
        r.withdrawAsset();
        assertEq(asset.balanceOf(alice), 900e18, "seller has the prize back");
    }

    /// A callback gas limit set too low is worse than one set too high: Chainlink charges the
    /// subscription, deletes the commitment, and the out-of-gas fulfilment cannot be retried, so
    /// the raffle waits out its timeout and refunds. The floor is rejected at both places the
    /// limit can be set, since neither can be corrected retroactively for a request in flight.
    function test_Fixed_CallbackGasLimitHasAFloor() public {
        vm.expectRevert(ChainlinkVRFProvider.CallbackGasTooLow.selector);
        new ChainlinkVRFProvider(owner, address(coordinator), KEY_HASH, SUB_ID, CONFIRMATIONS, 20_000, false);

        vm.prank(owner);
        vm.expectRevert(ChainlinkVRFProvider.CallbackGasTooLow.selector);
        vrf.setRequestConfig(KEY_HASH, SUB_ID, CONFIRMATIONS, 20_000, false);

        // The floor itself is accepted, and is far above what fulfilment actually costs.
        uint32 floor = vrf.MIN_CALLBACK_GAS();
        vm.prank(owner);
        vrf.setRequestConfig(KEY_HASH, SUB_ID, CONFIRMATIONS, floor, false);
        assertEq(vrf.callbackGasLimit(), floor);
        assertLe(floor, CHAINLINK_MAX_CALLBACK_GAS, "floor must be settable everywhere");
    }

    /// Chainlink deletes the request commitment BEFORE invoking the callback and charges the
    /// subscription either way, so a callback that reverts or runs out of gas loses that seed
    /// permanently — it cannot be retried. The callback is therefore kept to one store and one
    /// event, nothing that can fail on a raffle's behalf.
    function test_Conformance_CallbackFitsWellInsideItsGasLimit() public {
        Raffle r = _soldOutRaffle(10, 3);
        r.finalize();
        uint256 id = uint256(r.randomnessRequestId());

        uint256[] memory word = new uint256[](1);
        word[0] = uint256(keccak256("seed"));

        vm.prank(address(coordinator));
        uint256 before = gasleft();
        vrf.rawFulfillRandomWords(id, word);
        uint256 used = before - gasleft();

        assertLt(used, CALLBACK_GAS / 2, "callback must sit far below the configured limit");
        emit log_named_uint("rawFulfillRandomWords gas", used);
    }

    /// Why the draw is a separate transaction, stated as a measurement rather than a comment:
    /// a full draw at MAX_WINNERS_COUNT costs more than Chainlink's 2.5M callback ceiling. Had
    /// the winners been picked inside the fulfilment, the callback would revert, the seed would
    /// be gone, and the raffle would sit until it timed out and refunded.
    function test_Conformance_DrawCouldNotRunInsideTheVrfCallback() public {
        uint16 maxWinners = uint16(Raffle(factory.RAFFLE_IMPLEMENTATION()).MAX_WINNERS_COUNT());

        Raffle r = _soldOutRaffle(maxWinners, maxWinners);
        r.finalize();
        uint256 id = uint256(r.randomnessRequestId());

        uint256[] memory word = new uint256[](1);
        word[0] = uint256(keccak256("seed"));
        vm.prank(address(coordinator));
        vrf.rawFulfillRandomWords(id, word);

        uint256 before = gasleft();
        r.drawWinners();
        uint256 used = before - gasleft();

        emit log_named_uint("drawWinners gas at MAX_WINNERS_COUNT", used);
        assertGt(used, CHAINLINK_MAX_CALLBACK_GAS, "draw is only safe because it is not the callback");
        assertLt(used, 20_000_000, "and it must still fit comfortably in a block");
    }
}
