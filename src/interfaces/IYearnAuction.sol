// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IYearnAuction
/// @notice Minimal interface for the Yearn V3 Dutch auction system.
interface IYearnAuction {
    /// @notice Kick (start) an auction for the given auction id.
    /// @param _auctionId The id of the auction to kick.
    /// @return available The amount of sell token available in the auction.
    function kick(bytes32 _auctionId) external returns (uint256 available);

    /// @notice Returns the amount of sell token available for a given auction id.
    function kickable(bytes32 _auctionId) external view returns (uint256);

    /// @notice Enable a new auction for a sell token / want token pair.
    function enable(address _sellToken) external returns (bytes32);
}
