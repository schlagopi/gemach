// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEulerVault
/// @notice Minimal EVC-compatible Euler V2 vault interface.
interface IEulerVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function borrow(uint256 assets, address receiver) external returns (uint256 shares);
    function repay(uint256 assets, address receiver) external returns (uint256 shares);

    function totalBorrows() external view returns (uint256);
    function debtOf(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);

    function interestRate() external view returns (uint256);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
}
