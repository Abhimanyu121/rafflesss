// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IRandomnessProvider} from "../interfaces/IRandomnessProvider.sol";
import {IRaffleFactory} from "../interfaces/IRaffleFactory.sol";

/// @dev Minimal view of the Chainlink VRF v2.5 coordinator, declared locally to avoid
///      depending on the whole Chainlink package for two functions.
interface IVRFCoordinatorV2Plus {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId);
}

/// @title ChainlinkVRFProvider
/// @notice Supplies raffles with verifiable randomness from Chainlink VRF v2.5.
/// @dev One provider serves every raffle from one factory. Before deploying, confirm the
///      coordinator address and key hash against Chainlink's docs and fund the subscription.
contract ChainlinkVRFProvider is IRandomnessProvider, Ownable2Step {
    /// @dev Chainlink's tag for v1 extra arguments: bytes4(keccak256("VRF ExtraArgsV1")).
    bytes4 private constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    /// @dev Chainlink deletes the request commitment before invoking the callback, so a
    ///      fulfilment that runs out of gas loses that seed for good and the raffle waits out
    ///      its timeout. Fulfilment measures ~27k gas; this floor leaves generous headroom and
    ///      stays well under Chainlink's 2.5M ceiling on every supported network.
    uint32 public constant MIN_CALLBACK_GAS = 100_000;

    /// @dev Confirmations are what stop a validator re-rolling an unfavourable request by
    ///      reorganising the block it landed in. Some networks, Base among them, let a consumer
    ///      ask for zero. A raffle should never do that, so three is the floor here.
    uint16 public constant MIN_REQUEST_CONFIRMATIONS = 3;

    struct ExtraArgsV1 {
        bool nativePayment;
    }

    IVRFCoordinatorV2Plus public immutable COORDINATOR;

    /// @notice Only raffles created by this factory may spend the subscription.
    IRaffleFactory public factory;

    bytes32 public keyHash;
    uint256 public subscriptionId;
    uint16 public requestConfirmations;
    uint32 public callbackGasLimit;
    bool public nativePayment;

    /// @dev Chainlink's request id, widened to bytes32, is used directly as our request id.
    mapping(bytes32 => uint256) private _randomness;
    mapping(bytes32 => address) public requestedBy;

    event FactoryUpdated(address oldFactory, address newFactory);
    event RequestConfigUpdated(
        bytes32 keyHash,
        uint256 subscriptionId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        bool nativePayment
    );
    event RandomnessRequested(address indexed raffle, bytes32 indexed requestId);
    event RandomnessFulfilled(bytes32 indexed requestId, uint256 randomness);

    error OnlyCoordinator();
    error OnlyKnownRaffle();
    error FactoryNotSet();
    error InvalidAddress();
    error FactoryAlreadySet();
    error CallbackGasTooLow();
    error TooFewConfirmations();
    error UnknownRequest();
    error EmptyRandomWords();

    constructor(
        address _owner,
        address _coordinator,
        bytes32 _keyHash,
        uint256 _subscriptionId,
        uint16 _requestConfirmations,
        uint32 _callbackGasLimit,
        bool _nativePayment
    ) Ownable(_owner) {
        if (_owner == address(0) || _coordinator == address(0)) {
            revert InvalidAddress();
        }
        if (_callbackGasLimit < MIN_CALLBACK_GAS) revert CallbackGasTooLow();
        if (_requestConfirmations < MIN_REQUEST_CONFIRMATIONS) revert TooFewConfirmations();
        COORDINATOR = IVRFCoordinatorV2Plus(_coordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        requestConfirmations = _requestConfirmations;
        callbackGasLimit = _callbackGasLimit;
        nativePayment = _nativePayment;
    }

    /// @notice Point the provider at the factory whose raffles it will serve.
    /// @dev Set once, after deployment, since the factory needs the provider's address first.
    ///      Repointing it later would make every existing raffle unknown, so its `finalize()`
    ///      would revert and a sold-out raffle could only be released by refunding everyone.
    ///      Serve a second factory with a second provider instead.
    function setFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert InvalidAddress();
        if (address(factory) != address(0)) revert FactoryAlreadySet();
        emit FactoryUpdated(address(0), _factory);
        factory = IRaffleFactory(_factory);
    }

    function setRequestConfig(
        bytes32 _keyHash,
        uint256 _subscriptionId,
        uint16 _requestConfirmations,
        uint32 _callbackGasLimit,
        bool _nativePayment
    ) external onlyOwner {
        if (_callbackGasLimit < MIN_CALLBACK_GAS) revert CallbackGasTooLow();
        if (_requestConfirmations < MIN_REQUEST_CONFIRMATIONS) revert TooFewConfirmations();
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        requestConfirmations = _requestConfirmations;
        callbackGasLimit = _callbackGasLimit;
        nativePayment = _nativePayment;
        emit RequestConfigUpdated(_keyHash, _subscriptionId, _requestConfirmations, _callbackGasLimit, _nativePayment);
    }

    /// @inheritdoc IRandomnessProvider
    function requestRandomness(address raffle, bytes32) external returns (bytes32 requestId) {
        if (address(factory) == address(0)) revert FactoryNotSet();
        // Only a real raffle, asking for itself, may spend the subscription.
        if (msg.sender != raffle || !factory.isRaffle(raffle)) {
            revert OnlyKnownRaffle();
        }

        uint256 id = COORDINATOR.requestRandomWords(
            IVRFCoordinatorV2Plus.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1,
                extraArgs: _argsToBytes(ExtraArgsV1({nativePayment: nativePayment}))
            })
        );

        requestId = bytes32(id);
        requestedBy[requestId] = raffle;
        emit RandomnessRequested(raffle, requestId);
    }

    /// @inheritdoc IRandomnessProvider
    /// @dev Zero means "not ready yet", so a fulfilled word of zero is stored as one.
    function getRandomness(bytes32 requestId) external view returns (uint256) {
        return _randomness[requestId];
    }

    /// @notice Called by the VRF coordinator with the answer.
    /// @dev Chainlink asks that this never revert, because a failed callback is not retried and
    ///      the seed is lost. The two rejections below are safe under that rule: an id this
    ///      provider never issued carries no seed of ours to lose, and `numWords` is fixed at one
    ///      so an empty array cannot come from a real request. Everything that could fail on a
    ///      raffle's behalf happens later, in `drawWinners`.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(COORDINATOR)) revert OnlyCoordinator();
        if (requestedBy[bytes32(requestId)] == address(0)) revert UnknownRequest();
        if (randomWords.length == 0) revert EmptyRandomWords();

        uint256 word = randomWords[0];
        if (word == 0) word = 1; // zero is the "not ready" sentinel

        _randomness[bytes32(requestId)] = word;
        emit RandomnessFulfilled(bytes32(requestId), word);
    }

    function _argsToBytes(ExtraArgsV1 memory args) private pure returns (bytes memory) {
        return abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, args);
    }
}
