// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {RaffleFactory} from "../src/RaffleFactory.sol";
import {ChainlinkVRFProvider} from "../src/randomness/ChainlinkVRFProvider.sol";

/// @title Deployment script
/// @notice Deploys the randomness provider, then the factory, then links them.
/// @dev The factory owner is passed in explicitly. It is NOT msg.sender, because a CREATE2
///      deployment routes through the deterministic deployer proxy and would make that proxy
///      the owner, leaving the factory permanently un-administrable.
///
/// Required environment:
///   PRIVATE_KEY          deployer key
///   FEE_RECIPIENT        where protocol fees go
///   FACTORY_OWNER        who administers the factory (a Safe or timelock in production)
///   VRF_COORDINATOR      Chainlink VRF v2.5 coordinator for the target network
///   VRF_KEY_HASH         gas lane key hash
///   VRF_SUBSCRIPTION_ID  funded subscription id
/// Optional:
///   FEE_BPS              protocol fee in basis points, default 200 (2%)
///   VRF_CONFIRMATIONS    default 3
///   VRF_CALLBACK_GAS     default 200000
///   VRF_NATIVE_PAYMENT   default false (pay in LINK)
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address factoryOwner = vm.envOr("FACTORY_OWNER", vm.addr(deployerPrivateKey));
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(200)); // 2%

        address coordinator = vm.envAddress("VRF_COORDINATOR");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");
        uint16 confirmations = uint16(vm.envOr("VRF_CONFIRMATIONS", uint256(3)));
        uint32 callbackGas = uint32(vm.envOr("VRF_CALLBACK_GAS", uint256(200000)));
        bool nativePayment = vm.envOr("VRF_NATIVE_PAYMENT", false);

        vm.startBroadcast(deployerPrivateKey);

        ChainlinkVRFProvider provider = new ChainlinkVRFProvider(
            factoryOwner, coordinator, keyHash, subId, confirmations, callbackGas, nativePayment
        );

        RaffleFactory factory = new RaffleFactory(factoryOwner, feeRecipient, feeBps, address(provider));

        // The provider only serves raffles from a factory it knows, and that binding can be
        // set exactly once. Wire it here whenever the deployer is also the owner, so a live
        // deployment never depends on a human remembering a follow-up transaction.
        bool wired = factoryOwner == vm.addr(deployerPrivateKey);
        if (wired) {
            provider.setFactory(address(factory));
        }

        vm.stopBroadcast();

        // Fail loudly rather than shipping an un-administrable factory.
        require(factory.owner() == factoryOwner, "Deploy: unexpected factory owner");
        require(provider.owner() == factoryOwner, "Deploy: unexpected provider owner");
        require(factory.feeBps() == feeBps, "Deploy: unexpected fee");
        if (wired) {
            require(address(provider.factory()) == address(factory), "Deploy: provider not wired");
        }

        console.log("RandomnessProvider:", address(provider));
        console.log("RaffleFactory:     ", address(factory));
        console.log("Implementation:    ", factory.RAFFLE_IMPLEMENTATION());
        console.log("Owner:             ", factoryOwner);
        console.log("Fee bps:           ", feeBps);
        console.log("");
        if (wired) {
            console.log("Provider wired to factory. REMAINING STEP before any raffle can settle:");
            console.log("  add the provider as a consumer of VRF subscription", subId);
            console.log("  and fund it, then run script/SetupProvider.s.sol to verify.");
        } else {
            console.log("NOT PRODUCTION READY. Owner must still run script/SetupProvider.s.sol:");
            console.log("  it calls provider.setFactory(%s) and verifies the wiring.", address(factory));
            console.log("  Also add the provider as a consumer of VRF subscription", subId);
        }
    }
}
