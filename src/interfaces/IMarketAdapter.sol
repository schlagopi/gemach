// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMarketAdapter
/// @notice Common interface for lending-market backend adapters.
///         Each adapter wraps a single market for a collateral/loan pair.
interface IMarketAdapter {
    function supplyCollateral(uint256 shares) external;
    function withdrawCollateral(uint256 shares, address to) external returns (uint256 actual);
    function borrow(uint256 amount, address to) external returns (uint256 actual);
    function repay(uint256 amount) external returns (uint256 actual);

    function totalDebt() external view returns (uint256);
    function totalCollateralShares() external view returns (uint256);
    function availableLiquidity() external view returns (uint256);
    function withdrawableCollateralShares() external view returns (uint256);
    function collateralToken() external view returns (address);
    function loanToken() external view returns (address);
}
