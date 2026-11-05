// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";

/// @title BottleSea
/// @notice Anonymous message-in-a-bottle registry. Bodies live off-chain; only the author and content hash live here.
/// @dev Picking and rethrowing are deliberately NOT recorded on-chain: a thrower must not be able to observe that
///      their bottle was picked or passed on. Holder and circulation state live only in the backend.
contract BottleSea is ERC2771Context {
    /// @dev Packed into 2 slots: [author|thrownAt] in slot 0, [contentHash] in slot 1.
    struct Bottle {
        address author;
        uint64 thrownAt;
        bytes32 contentHash;
    }

    error ZeroAddress();
    error EmptyHash();
    error DuplicateHash();

    /// @notice A new bottle was thrown into the sea.
    event BottleThrown(uint256 indexed id, address indexed author, bytes32 indexed contentHash, uint64 thrownAt);

    /// @notice Id of the last issued bottle (ids start at 1).
    uint256 public nextId;
    /// @notice Bottle data by id.
    mapping(uint256 => Bottle) public bottles;
    /// @notice contentHash => bottle id (duplicate guard and backend matching key).
    mapping(bytes32 => uint256) public idByHash;

    constructor(address trustedForwarder) ERC2771Context(trustedForwarder) {
        if (trustedForwarder == address(0)) revert ZeroAddress();
    }

    /// @notice Throw a new bottle; the caller (via forwarder) becomes author.
    function throwBottle(bytes32 contentHash) external returns (uint256 id) {
        if (contentHash == bytes32(0)) revert EmptyHash();
        if (idByHash[contentHash] != 0) revert DuplicateHash();

        address sender = _msgSender();
        id = ++nextId;
        // casting to 'uint64' is safe: block.timestamp fits in uint64 for billions of years
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 ts = uint64(block.timestamp);
        bottles[id] = Bottle({author: sender, thrownAt: ts, contentHash: contentHash});
        idByHash[contentHash] = id;
        emit BottleThrown(id, sender, contentHash, ts);
    }

    /// @notice Read a bottle.
    function getBottle(uint256 id) external view returns (Bottle memory) {
        return bottles[id];
    }
}
