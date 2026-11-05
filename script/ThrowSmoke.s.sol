// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {BottleSea} from "../src/BottleSea.sol";

/// @notice Smoke test: a zero-balance user signs a throw, the deployer wallet relays it and pays the gas.
contract ThrowSmoke is Script {
    bytes32 constant TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function run() external {
        uint256 relayerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 userPk = uint256(keccak256("bottle-smoke-user"));
        address user = vm.addr(userPk);

        string memory json = vm.readFile(string.concat("./deployments/", vm.toString(block.chainid), ".json"));
        ERC2771Forwarder fwd = ERC2771Forwarder(vm.parseJsonAddress(json, ".forwarder"));
        BottleSea sea = BottleSea(vm.parseJsonAddress(json, ".bottleSea"));

        string memory uuid = string.concat("smoke-", vm.toString(vm.getBlockTimestamp()));
        bytes32 contentHash = keccak256(abi.encodePacked(uuid, "hello bottle"));

        ERC2771Forwarder.ForwardRequestData memory req = ERC2771Forwarder.ForwardRequestData({
            from: user,
            to: address(sea),
            value: 0,
            gas: 200_000,
            // forge-lint: disable-next-line(unsafe-typecast)
            deadline: uint48(vm.getBlockTimestamp() + 30 minutes),
            data: abi.encodeCall(BottleSea.throwBottle, (contentHash)),
            signature: ""
        });

        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("BottleForwarder"), keccak256("1"), block.chainid, address(fwd))
        );
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH, req.from, req.to, req.value, req.gas, fwd.nonces(user), req.deadline, keccak256(req.data)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        req.signature = abi.encodePacked(r, s, v);

        require(fwd.verify(req), "signature invalid");
        console.log("user (signer, balance 0):", user);
        console.log("user balance:", user.balance);

        vm.startBroadcast(relayerPk);
        fwd.execute(req);
        vm.stopBroadcast();

        uint256 id = sea.idByHash(contentHash);
        console.log("bottle id:", id);
        console.log("author:", sea.getBottle(id).author);
        require(sea.getBottle(id).author == user, "author != signer");
    }
}
