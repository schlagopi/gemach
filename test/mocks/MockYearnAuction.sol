// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockYearnAuction
/// @notice Minimal mock for the Yearn V3 Dutch auction. Tracks received tokens
///         and allows test code to simulate auction completion.
contract MockYearnAuction {
    mapping(bytes32 => uint256) public kickable;
    mapping(bytes32 => bool) public kicked;

    function kick(bytes32 _auctionId) external returns (uint256) {
        uint256 available = kickable[_auctionId];
        kicked[_auctionId] = true;
        kickable[_auctionId] = 0;
        return available;
    }

    function enable(address) external pure returns (bytes32) {
        return keccak256("mock_auction");
    }

    // test helper: set kickable amount
    function setKickable(bytes32 _auctionId, uint256 amount) external {
        kickable[_auctionId] = amount;
    }
}
