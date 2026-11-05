// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {BottleSea} from "../src/BottleSea.sol";

contract BottleSeaTest is Test {
    ERC2771Forwarder fwd;
    BottleSea sea;

    address relayer = makeAddr("relayer");

    uint256 aliceKey = 0xA11CE;
    uint256 bobKey = 0xB0B;
    address alice;
    address bob;

    uint256 constant GAS = 200_000;

    bytes32 constant TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        alice = vm.addr(aliceKey);
        bob = vm.addr(bobKey);
        fwd = new ERC2771Forwarder("BottleForwarder");
        sea = new BottleSea(address(fwd));
        vm.warp(1_700_000_000);
    }

    // ───────────── helpers ─────────────

    function _digest(ERC2771Forwarder.ForwardRequestData memory r, uint256 nonce) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("BottleForwarder"), keccak256("1"), block.chainid, address(fwd))
        );
        bytes32 structHash =
            keccak256(abi.encode(TYPEHASH, r.from, r.to, r.value, r.gas, nonce, r.deadline, keccak256(r.data)));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _req(uint256 pk, uint256 nonce, uint48 deadline, bytes memory data)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory r)
    {
        r = ERC2771Forwarder.ForwardRequestData({
            from: vm.addr(pk), to: address(sea), value: 0, gas: GAS, deadline: deadline, data: data, signature: ""
        });
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(pk, _digest(r, nonce));
        r.signature = abi.encodePacked(rr, s, v);
    }

    function _signed(uint256 pk, bytes memory data) internal view returns (ERC2771Forwarder.ForwardRequestData memory) {
        return _req(pk, fwd.nonces(vm.addr(pk)), uint48(vm.getBlockTimestamp() + 30 minutes), data);
    }

    function _throwData(bytes32 h) internal pure returns (bytes memory) {
        return abi.encodeCall(BottleSea.throwBottle, (h));
    }

    function _exec(ERC2771Forwarder.ForwardRequestData memory r) internal {
        vm.prank(relayer);
        fwd.execute(r);
    }

    function _throw(uint256 pk, bytes32 h) internal returns (uint256 id) {
        _exec(_signed(pk, _throwData(h)));
        id = sea.idByHash(h);
    }

    // ───────────── constructor ─────────────

    function test_constructor_zeroForwarder_reverts() public {
        vm.expectRevert(BottleSea.ZeroAddress.selector);
        new BottleSea(address(0));
    }

    // ───────────── throw (via forwarder) ─────────────

    function test_throw_viaForwarder_authorIsSigner() public {
        bytes32 h = keccak256("hello");
        vm.expectEmit(true, true, true, true, address(sea));
        emit BottleSea.BottleThrown(1, alice, h, uint64(vm.getBlockTimestamp()));
        uint256 id = _throw(aliceKey, h);

        assertEq(id, 1);
        BottleSea.Bottle memory b = sea.getBottle(id);
        assertEq(b.author, alice);
        assertTrue(b.author != relayer);
        assertEq(b.contentHash, h);
        assertEq(b.thrownAt, uint64(vm.getBlockTimestamp()));
        assertEq(fwd.nonces(alice), 1);
    }

    function test_throw_forgedSignature_reverts() public {
        // bob signs a request claiming to be alice
        ERC2771Forwarder.ForwardRequestData memory r = _signed(bobKey, _throwData(keccak256("x")));
        r.from = alice;
        vm.expectPartialRevert(ERC2771Forwarder.ERC2771ForwarderInvalidSigner.selector);
        _exec(r);
        assertEq(sea.nextId(), 0);
    }

    function test_throw_replay_reverts() public {
        ERC2771Forwarder.ForwardRequestData memory r = _signed(aliceKey, _throwData(keccak256("x")));
        _exec(r);
        vm.expectPartialRevert(ERC2771Forwarder.ERC2771ForwarderInvalidSigner.selector);
        _exec(r);
        assertEq(sea.nextId(), 1);
    }

    function test_throw_wrongNonce_reverts() public {
        ERC2771Forwarder.ForwardRequestData memory r =
            _req(aliceKey, 5, uint48(vm.getBlockTimestamp() + 1 hours), _throwData(keccak256("x")));
        vm.expectPartialRevert(ERC2771Forwarder.ERC2771ForwarderInvalidSigner.selector);
        _exec(r);
    }

    function test_throw_expiredDeadline_reverts() public {
        ERC2771Forwarder.ForwardRequestData memory r =
            _req(aliceKey, 0, uint48(vm.getBlockTimestamp() - 1), _throwData(keccak256("x")));
        vm.expectRevert(abi.encodeWithSelector(ERC2771Forwarder.ERC2771ForwarderExpiredRequest.selector, r.deadline));
        _exec(r);
    }

    function test_throw_duplicateHash_reverts() public {
        bytes32 h = keccak256("dup");
        _throw(aliceKey, h);
        // inner call reverts DuplicateHash -> forwarder surfaces FailedCall
        ERC2771Forwarder.ForwardRequestData memory fr = _signed(bobKey, _throwData(h));
        vm.expectRevert(Errors.FailedCall.selector);
        _exec(fr);
        assertEq(sea.nextId(), 1);
    }

    function test_throw_zeroHash_reverts() public {
        ERC2771Forwarder.ForwardRequestData memory fr = _signed(aliceKey, _throwData(bytes32(0)));
        vm.expectRevert(Errors.FailedCall.selector);
        _exec(fr);
    }

    function test_throw_directCall_authorIsMsgSender() public {
        // Intended: without the forwarder, _msgSender() falls back to msg.sender.
        vm.prank(alice);
        uint256 id = sea.throwBottle(keccak256("direct"));
        assertEq(sea.getBottle(id).author, alice);
    }

    function test_throw_directCall_errors() public {
        vm.expectRevert(BottleSea.EmptyHash.selector);
        sea.throwBottle(bytes32(0));
        sea.throwBottle(keccak256("a"));
        vm.expectRevert(BottleSea.DuplicateHash.selector);
        sea.throwBottle(keccak256("a"));
    }

    function test_isTrustedForwarder() public view {
        assertTrue(sea.isTrustedForwarder(address(fwd)));
        assertFalse(sea.isTrustedForwarder(relayer));
        assertEq(sea.trustedForwarder(), address(fwd));
    }

    function test_forwarderVerify() public view {
        assertTrue(fwd.verify(_signed(aliceKey, _throwData(keccak256("v")))));
    }

    // ───────────── batch ─────────────

    function test_batch_multiUser() public {
        ERC2771Forwarder.ForwardRequestData[] memory rs = new ERC2771Forwarder.ForwardRequestData[](2);
        rs[0] = _signed(aliceKey, _throwData(keccak256("a")));
        rs[1] = _signed(bobKey, _throwData(keccak256("b")));
        vm.prank(relayer);
        fwd.executeBatch(rs, payable(address(0)));

        assertEq(sea.nextId(), 2);
        assertEq(sea.getBottle(1).author, alice);
        assertEq(sea.getBottle(2).author, bob);
    }

    function _mixedBatch() internal view returns (ERC2771Forwarder.ForwardRequestData[] memory rs) {
        rs = new ERC2771Forwarder.ForwardRequestData[](3);
        rs[0] = _signed(aliceKey, _throwData(keccak256("a")));
        rs[1] = _req(bobKey, 99, uint48(vm.getBlockTimestamp() + 1 hours), _throwData(keccak256("bad"))); // bad nonce
        rs[2] = _signed(bobKey, _throwData(keccak256("c")));
    }

    function test_batch_invalidRequest_refundReceiverZero_revertsAll() public {
        ERC2771Forwarder.ForwardRequestData[] memory rs = _mixedBatch();
        vm.prank(relayer);
        vm.expectPartialRevert(ERC2771Forwarder.ERC2771ForwarderInvalidSigner.selector);
        fwd.executeBatch(rs, payable(address(0)));
        assertEq(sea.nextId(), 0); // nothing executed
        assertEq(fwd.nonces(alice), 0);
    }

    function test_batch_invalidRequest_withRefundReceiver_skipsInvalid() public {
        ERC2771Forwarder.ForwardRequestData[] memory rs = _mixedBatch();
        vm.prank(relayer);
        fwd.executeBatch(rs, payable(relayer));
        assertEq(sea.nextId(), 2); // alice + bob's valid one
        assertEq(fwd.nonces(alice), 1);
        assertEq(fwd.nonces(bob), 1); // invalid one did NOT consume nonce
    }

    function test_batch_innerCallFailure_doesNotRevertBatch_butConsumesNonce() public {
        bytes32 h = keccak256("dup");
        _throw(aliceKey, h);
        ERC2771Forwarder.ForwardRequestData[] memory rs = new ERC2771Forwarder.ForwardRequestData[](2);
        rs[0] = _signed(bobKey, _throwData(h)); // inner call will revert DuplicateHash
        rs[1] = _signed(aliceKey, _throwData(keccak256("ok")));
        vm.expectEmit(true, false, false, true, address(fwd));
        emit ERC2771Forwarder.ExecutedForwardRequest(bob, 0, false);
        vm.prank(relayer);
        fwd.executeBatch(rs, payable(address(0))); // value == 0 -> no revert even with refundReceiver 0
        assertEq(sea.nextId(), 2);
        assertEq(fwd.nonces(bob), 1); // nonce consumed although call failed
    }
}
