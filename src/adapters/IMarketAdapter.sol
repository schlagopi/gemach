// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMarketAdapter
/// @notice Common interface for lending-market backend adapters.
///         Each adapter wraps a single market using yvBTC as collateral and
///         USDC as the loan token.
interface IMarketAdapter {
    /// @notice Supply yvBTC collateral to the backend market.
    function supplyCollateral(uint256 yvShares) external;

    /// @notice Withdraw yvBTC collateral from the backend market.
    /// @return actual The number of yvBTC shares actually withdrawn.
    function withdrawCollateral(uint256 yvShares, address to) external returns (uint256 actual);

    /// @notice Borrow USDC from the backend market.
    /// @return actual The USDC amount actually borrowed.
    function borrow(uint256 usdcAmount, address to) external returns (uint256 actual);

    /// @notice Repay USDC to the backend market.
    /// @return actual The USDC amount actually repaid.
    function repay(uint256 usdcAmount) external returns (uint256 actual);

    /// @notice Total outstanding USDC debt in this adapter.
    function totalDebt() external view returns (uint256);

    /// @notice Total yvBTC collateral shares held in this adapter.
    function totalCollateralShares() external view returns (uint256);

    /// @notice Current annualized borrow rate normalized to 1e18 (1e18 = 100%).
    function currentBorrowRate() external view returns (uint256);

    /// @notice Available USDC liquidity that can be borrowed from the backend.
    function availableLiquidity() external view returns (uint256);

    /// @notice yvBTC collateral shares that can be withdrawn right now.
    function withdrawableCollateralShares() external view returns (uint256);

    /// @notice Address of the collateral token (yvBTC).
    function collateralToken() external view returns (address);

    /// @notice Address of the loan token (USDC).
    function loanToken() external view returns (address);
}
