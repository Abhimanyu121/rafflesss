// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {RaffleFactory} from "../src/RaffleFactory.sol";

/// @title Deployment script for RaffleFactory
/// @notice Deploys the factory with configurable fee settings
contract Deploy is Script {
    bytes32 salt =
        bytes32(
            0x0000000000000000000000000000000000000000000000000000000000000006
        );
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(200)); // Default 2%

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying RaffleFactory...");
        console.log("Fee Recipient:", feeRecipient);
        console.log("Fee BPS:", feeBps);

        RaffleFactory factory = new RaffleFactory{salt: salt}(
            feeRecipient,
            feeBps
        );

        console.log("RaffleFactory deployed at:", address(factory));
        console.log("Implementation address:", factory.RAFFLE_IMPLEMENTATION());

        vm.stopBroadcast();
    }
}
