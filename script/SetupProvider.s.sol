// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {RaffleFactory} from "../src/RaffleFactory.sol";
import {ChainlinkVRFProvider} from "../src/randomness/ChainlinkVRFProvider.sol";

/// @title Provider wiring and readiness check
/// @notice Run by the provider owner after `Deploy.s.sol`. Binds the provider to its factory
///         if that has not happened yet, then refuses to pass unless the deployment can
///         actually settle a raffle.
/// @dev A deployment is not production ready until this script exits without reverting. Until
///      then `finalize()` reverts and a sold-out raffle can only be released by refunding
///      every buyer after the abandonment grace period.
///
/// Required environment:
///   PRIVATE_KEY   the provider owner's key (only needed when the binding is still unset)
///   PROVIDER      ChainlinkVRFProvider address
///   FACTORY       RaffleFactory address
contract SetupProvider is Script {
    function run() external {
        ChainlinkVRFProvider provider = ChainlinkVRFProvider(vm.envAddress("PROVIDER"));
        RaffleFactory factory = RaffleFactory(vm.envAddress("FACTORY"));

        if (address(provider.factory()) == address(0)) {
            vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
            provider.setFactory(address(factory));
            vm.stopBroadcast();
            console.log("Bound provider to factory.");
        }

        // 1. The factory must point at this provider, and this provider back at that factory.
        //    Either half alone leaves raffles that can never request randomness.
        require(address(factory.randomnessProvider()) == address(provider), "Setup: factory uses another provider");
        require(address(provider.factory()) == address(factory), "Setup: provider serves another factory");

        // 2. The subscription must list the provider as a consumer and hold funds, or the
        //    coordinator rejects every request. Read defensively: this is the only part that
        //    depends on the coordinator's exact ABI.
        _checkSubscription(provider);

        console.log("READY. Provider:", address(provider));
        console.log("       Factory: ", address(factory));
    }

    function _checkSubscription(ChainlinkVRFProvider provider) internal view {
        uint256 subId = provider.subscriptionId();
        (bool ok, bytes memory data) =
            address(provider.COORDINATOR()).staticcall(abi.encodeWithSignature("getSubscription(uint256)", subId));
        if (!ok || data.length < 160) {
            console.log("WARNING: could not read subscription", subId);
            console.log("         Verify manually that the provider is a funded consumer.");
            return;
        }

        (uint96 balance, uint96 nativeBalance,,, address[] memory consumers) =
            abi.decode(data, (uint96, uint96, uint64, address, address[]));

        bool isConsumer;
        for (uint256 i = 0; i < consumers.length; i++) {
            if (consumers[i] == address(provider)) {
                isConsumer = true;
                break;
            }
        }
        require(isConsumer, "Setup: provider is not a subscription consumer");

        uint256 funds = provider.nativePayment() ? nativeBalance : balance;
        require(funds > 0, "Setup: subscription has no balance");
        console.log("Subscription", subId, "funded with", funds);
    }
}
