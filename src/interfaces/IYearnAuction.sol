// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IYearnAuction
/// @notice Interface for the Yearn V3 Dutch Auction v1.0.4.
///         Sells `from` tokens in exchange for `want` tokens using a
///         step-based price decay over a 1-day auction window.
interface IYearnAuction {
    // -------- views --------

    /// @notice The token buyers pay with (e.g. USDC).
    function want() external view returns (address);

    /// @notice Address that receives `want` tokens from takers.
    function receiver() external view returns (address);

    /// @notice The starting price (lot-size) for auctions.
    function startingPrice() external view returns (uint256);

    /// @notice Minimum price below which the auction becomes inactive.
    function minimumPrice() external view returns (uint256);

    /// @notice Decay rate per step in basis points.
    function stepDecayRate() external view returns (uint256);

    /// @notice Duration of each price step in seconds.
    function stepDuration() external view returns (uint256);

    /// @notice Whether the auction for `_from` is currently active.
    function isActive(address _from) external view returns (bool);

    /// @notice Available amount in the active auction for `_from`.
    function available(address _from) external view returns (uint256);

    /// @notice Amount that can be kicked into a new auction for `_from`.
    function kickable(address _from) external view returns (uint256);

    /// @notice Timestamp the auction for `_from` was last kicked.
    function kicked(address _from) external view returns (uint256);

    /// @notice Current price for the auction of `_from`.
    function price(address _from) external view returns (uint256);

    /// @notice Price at a specific timestamp.
    function price(address _from, uint256 _timestamp) external view returns (uint256);

    /// @notice Amount of `want` needed to buy all available `_from`.
    function getAmountNeeded(address _from) external view returns (uint256);

    /// @notice Amount of `want` needed to buy `_amountToTake` of `_from`.
    function getAmountNeeded(address _from, uint256 _amountToTake) external view returns (uint256);

    /// @notice Check if there is any active auction across all enabled tokens.
    function isAnActiveAuction() external view returns (bool);

    /// @notice Get all enabled auction tokens.
    function getAllEnabledAuctions() external view returns (address[] memory);

    /// @notice Whether only governance can kick auctions.
    function governanceOnlyKick() external view returns (bool);

    // -------- mutative --------

    /// @notice Kick off an auction for `_from`.
    /// @return available Amount available for bidding.
    function kick(address _from) external returns (uint256 available);

    /// @notice Force-kick an auction (governance only, resets and kicks).
    function forceKick(address _from) external;

    /// @notice Settle a completed auction (balance must be 0).
    function settle(address _from) external;

    /// @notice Sweep all of `_token` back to governance.
    function sweep(address _token) external;

    // -------- governance config --------

    /// @notice Enable a new token for auction.
    function enable(address _from) external;

    /// @notice Disable an auction token.
    function disable(address _from) external;

    /// @notice Set the starting price (lot-size).
    function setStartingPrice(uint256 _startingPrice) external;

    /// @notice Set the minimum price floor.
    function setMinimumPrice(uint256 _minimumPrice) external;

    /// @notice Set the decay rate per step in bps.
    function setStepDecayRate(uint256 _stepDecayRate) external;

    /// @notice Set the step duration in seconds.
    function setStepDuration(uint256 _stepDuration) external;

    /// @notice Set the receiver for `want` tokens.
    function setReceiver(address _receiver) external;

    /// @notice Set whether only governance can kick.
    function setGovernanceOnlyKick(bool _governanceOnlyKick) external;

    /// @notice Initialize the auction (called by factory).
    function initialize(address _want, address _receiver, address _governance, uint256 _startingPrice) external;
}
