// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IYearnVault4626
/// @notice Minimal ERC-4626-compatible interface for a Yearn V3 vault.
interface IYearnVault4626 {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}
