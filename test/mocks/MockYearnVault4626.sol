// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @title MockYearnVault4626
/// @notice Mock ERC-4626 vault for testing. 1:1 share ratio by default,
///         with a `setSharePrice` helper to simulate yield accrual.
contract MockYearnVault4626 {
    MockERC20 public immutable underlying; // cbBTC

    string public name = "Mock yvBTC";
    string public symbol = "yvBTC";
    uint8 public decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // share price numerator/denominator: assets = shares * priceNum / priceDen
    uint256 public priceNum = 1;
    uint256 public priceDen = 1;

    constructor(address _underlying) {
        underlying = MockERC20(_underlying);
        decimals = underlying.decimals();
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function totalAssets() external view returns (uint256) {
        return convertToAssets(totalSupply);
    }

    // --- share price helpers ---

    function setSharePrice(uint256 num, uint256 den) external {
        priceNum = num;
        priceDen = den;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * priceNum / priceDen;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets * priceDen / priceNum;
    }

    // --- ERC-4626 core ---

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        underlying.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = convertToShares(assets);
        // round up shares burned
        if (shares * priceNum / priceDen < assets) shares += 1;
        _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        underlying.transfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        underlying.transfer(receiver, assets);
    }

    // --- ERC-20 ---

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // --- internal ---

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        if (spender == owner) return;
        if (allowance[owner][spender] != type(uint256).max) {
            allowance[owner][spender] -= amount;
        }
    }
}
