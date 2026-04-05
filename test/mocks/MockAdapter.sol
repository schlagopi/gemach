// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMarketAdapter} from "../../src/interfaces/IMarketAdapter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockAdapter
/// @notice Simulates a lending backend for testing.
contract MockAdapter is IMarketAdapter {
    address public immutable override collateralToken;
    address public immutable override loanToken;

    uint256 public override totalDebt;
    uint256 public override totalCollateralShares;

    uint256 public liquidityAmount;
    address public router;

    constructor(address _collateralToken, address _loanToken) {
        collateralToken = _collateralToken;
        loanToken = _loanToken;
        liquidityAmount = type(uint256).max;
    }

    function setRouter(address _router) external {
        router = _router;
    }

    function setLiquidity(uint256 _liq) external {
        liquidityAmount = _liq;
    }

    function accrueInterest(uint256 extraDebt) external {
        totalDebt += extraDebt;
    }

    modifier onlyRouter() {
        require(msg.sender == router, "not router");
        _;
    }

    function supplyCollateral(uint256 shares) external override onlyRouter {
        MockERC20(collateralToken).transferFrom(msg.sender, address(this), shares);
        totalCollateralShares += shares;
    }

    function withdrawCollateral(uint256 shares, address to) external override onlyRouter returns (uint256) {
        require(totalCollateralShares >= shares, "insufficient collateral");
        totalCollateralShares -= shares;
        MockERC20(collateralToken).transfer(to, shares);
        return shares;
    }

    function borrow(uint256 amount, address to) external override onlyRouter returns (uint256) {
        require(amount <= liquidityAmount, "no liquidity");
        totalDebt += amount;
        if (liquidityAmount != type(uint256).max) liquidityAmount -= amount;
        MockERC20(loanToken).mint(to, amount);
        return amount;
    }

    function repay(uint256 amount) external override onlyRouter returns (uint256) {
        uint256 actual = amount > totalDebt ? totalDebt : amount;
        MockERC20(loanToken).transferFrom(msg.sender, address(this), actual);
        totalDebt -= actual;
        return actual;
    }

    function availableLiquidity() external view override returns (uint256) {
        return liquidityAmount;
    }

    function withdrawableCollateralShares() external view override returns (uint256) {
        return totalCollateralShares;
    }
}
