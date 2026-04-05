// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceOracle
/// @notice Morpho-style price oracle. Returns the value of collateral in
///         debt-token units, scaled by 1e36.
///         Semantics: debtAmount = collateralAmount * price() / 1e36
interface IPriceOracle {
    /// @notice Returns the price of collateral in debt token, scaled to 1e36.
    function price() external view returns (uint256);
}
