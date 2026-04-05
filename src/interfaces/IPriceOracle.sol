// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceOracle
/// @notice Minimal oracle interface to quote collateral value in debt-token units.
interface IPriceOracle {
    /// @notice Returns the debt-token value of the given collateral amount.
    /// @param collateralAmount Amount of collateral token.
    /// @return debtValue Equivalent value in debt-token units.
    function quote(uint256 collateralAmount) external view returns (uint256 debtValue);
}
