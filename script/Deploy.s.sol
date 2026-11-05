// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {BottleSea} from "../src/BottleSea.sol";

contract Deploy is Script {
    string constant OZ_VERSION = "v5.7.0";
    // anvil default account #0
    uint256 constant ANVIL_KEY0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        bool local = block.chainid == 31337;
        uint256 pk = local ? vm.envOr("DEPLOYER_PRIVATE_KEY", ANVIL_KEY0) : vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(pk);
        ERC2771Forwarder forwarder = new ERC2771Forwarder("BottleForwarder");
        BottleSea sea = new BottleSea(address(forwarder));
        vm.stopBroadcast();

        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "forwarder", address(forwarder));
        vm.serializeAddress(k, "bottleSea", address(sea));
        vm.serializeUint(k, "deployedAt", vm.getBlockTimestamp());
        string memory json = vm.serializeString(k, "ozVersion", OZ_VERSION);
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".json"));

        console.log("Forwarder:", address(forwarder));
        console.log("BottleSea:", address(sea));
    }
}
